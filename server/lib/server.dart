import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';

import 'auth.dart';
import 'hub.dart';

class ServerConfig {
  const ServerConfig({
    this.host = '0.0.0.0',
    this.port = 8080,
    required this.secret,
    this.hub = const HubConfig(),
    this.tlsCert,
    this.tlsKey,
    this.registerPerMinute = 30,
  });
  final String host;
  final int port;
  final String secret;
  final HubConfig hub;
  final String? tlsCert, tlsKey;
  final int registerPerMinute;
}

class _SocketConnection implements Connection {
  _SocketConnection(this.socket);
  final WebSocket socket;
  @override
  void send(Json message) {
    if (socket.readyState == WebSocket.open) socket.add(jsonEncode(message));
  }

  @override
  void sendBytes(Uint8List bytes) {
    if (socket.readyState == WebSocket.open) socket.add(bytes);
  }

  @override
  void close(int code, String reason) => socket.close(code, reason);
}

/// HTTP + WebSocket front end around [Hub].
///   GET  /healthz      liveness
///   GET  /metrics      counters (JSON)
///   POST /v1/register  {name, role, lang} -> {userId, token}
///   GET  /v1/ws?token= WebSocket (first frame must be `hello`)
class DharaniServer {
  DharaniServer(this.config, {DateTime Function()? clock})
      : hub = Hub(config.hub, clock: clock),
        tokens = TokenService(config.secret, clock: clock);

  final ServerConfig config;
  final Hub hub;
  final TokenService tokens;
  HttpServer? _http;
  final _registerTimes = <DateTime>[];
  final _rng = math.Random.secure();

  int get port => _http!.port;

  Future<void> start() async {
    hub.openJournal();
    if (config.tlsCert != null && config.tlsKey != null) {
      final ctx = SecurityContext()
        ..useCertificateChain(config.tlsCert!)
        ..usePrivateKey(config.tlsKey!);
      _http = await HttpServer.bindSecure(config.host, config.port, ctx);
    } else {
      _http = await HttpServer.bind(config.host, config.port);
    }
    _http!.listen(_onRequest, onError: (Object e) => stderr.writeln('http error: $e'));
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    await hub.close();
  }

  Future<void> _onRequest(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (path == '/healthz') return _json(req, 200, {'ok': true, 'onlineDrivers': hub.onlineDrivers});
      if (path == '/metrics') return _json(req, 200, hub.metrics.toJson());
      if (path == '/v1/register' && req.method == 'POST') return await _register(req);
      if (path == '/v1/ws') {
        if (WebSocketTransformer.isUpgradeRequest(req)) return await _upgrade(req);
        // Plain GET: lets a client learn why an upgrade failed (401 = token no longer valid).
        return _json(req, tokens.verify(req.uri.queryParameters['token']) == null ? 401 : 426, {'error': 'websocket upgrade required'});
      }
      _json(req, 404, {'error': 'not found'});
    } catch (e) {
      try {
        _json(req, 500, {'error': 'internal error'});
      } catch (_) {}
      stderr.writeln('request failed: $e');
    }
  }

  void _json(HttpRequest req, int status, Json body) {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    req.response.close();
  }

  Future<void> _register(HttpRequest req) async {
    final now = DateTime.now();
    _registerTimes.removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_registerTimes.length >= config.registerPerMinute) return _json(req, 429, {'error': 'too many registrations, retry shortly'});
    _registerTimes.add(now);
    final body = await utf8.decoder.bind(req).join().timeout(const Duration(seconds: 5));
    if (body.length > 4096) return _json(req, 413, {'error': 'body too large'});
    try {
      final m = jsonDecode(body) as Map<String, dynamic>;
      final role = reqEnum(m, 'role', Role.values);
      reqString(m, 'name', max: 60);
      reqLang(m, 'lang');
      final uid = '${role.name[0]}-${List.generate(12, (_) => _rng.nextInt(36).toRadixString(36)).join()}';
      _json(req, 200, {'userId': uid, 'token': tokens.issue(uid, role)});
    } on ProtocolException catch (e) {
      _json(req, 400, {'error': e.message});
    } on FormatException {
      _json(req, 400, {'error': 'body must be JSON'});
    } on TypeError {
      _json(req, 400, {'error': 'body must be a JSON object'});
    }
  }

  Future<void> _upgrade(HttpRequest req) async {
    final claims = tokens.verify(req.uri.queryParameters['token']);
    if (claims == null) {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }
    final socket = await WebSocketTransformer.upgrade(req);
    socket.pingInterval = const Duration(seconds: 20);
    final conn = _SocketConnection(socket);
    final peer = hub.attach(claims.uid, claims.role, conn);
    stdout.writeln('${DateTime.now().toIso8601String()} ws open ${claims.role.name} ${claims.uid.substring(0, 6)} from ${req.connectionInfo?.remoteAddress.address}');
    final limiter = RateLimiter();
    final audioLimiter = RateLimiter(perSecond: 120, burst: 240); // 50 frames/s nominal
    var greeted = false;

    socket.listen(
      (data) {
        try {
          if (data is List<int>) {
            if (!greeted) throw ProtocolException(ErrorCode.protocol, 'first message must be hello');
            if (audioLimiter.allow()) hub.handleBinary(peer, data is Uint8List ? data : Uint8List.fromList(data));
            return;
          }
          if (data is! String) throw ProtocolException(ErrorCode.badRequest, 'unsupported frame');
          if (data.length > maxFrameBytes) {
            hub.sendError(peer, ProtocolException(ErrorCode.tooLarge, 'frame too large'));
            socket.close(1009, 'frame too large');
            return;
          }
          if (!limiter.allow()) throw ProtocolException(ErrorCode.rateLimited, 'slow down');
          final decoded = jsonDecode(data);
          if (decoded is! Map<String, dynamic>) throw ProtocolException(ErrorCode.badRequest, 'frames must be JSON objects');
          if (!greeted) {
            if (decoded['t'] != T.hello) throw ProtocolException(ErrorCode.protocol, 'first message must be hello');
            if (decoded['protocol'] != protocolVersion) throw ProtocolException(ErrorCode.protocol, 'unsupported protocol version (server speaks $protocolVersion)');
            conn.send(hub.hello(peer, decoded));
            greeted = true;
            return;
          }
          hub.handle(peer, decoded);
        } on ProtocolException catch (e) {
          hub.sendError(peer, e);
        } on FormatException {
          hub.sendError(peer, ProtocolException(ErrorCode.badRequest, 'invalid JSON'));
        } catch (e) {
          stderr.writeln('handler error: $e');
          hub.sendError(peer, ProtocolException(ErrorCode.badRequest, 'could not process message'));
        }
      },
      onDone: () {
        stdout.writeln('${DateTime.now().toIso8601String()} ws closed ${peer.role.name} ${peer.uid.substring(0, 6)} code=${socket.closeCode} reason=${socket.closeReason}');
        hub.detach(peer, conn);
      },
      onError: (Object e) {
        stdout.writeln('${DateTime.now().toIso8601String()} ws error ${peer.role.name} ${peer.uid.substring(0, 6)} $e');
        hub.detach(peer, conn);
      },
      cancelOnError: true,
    );
  }
}
