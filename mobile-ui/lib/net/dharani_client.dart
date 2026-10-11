import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';

import '../core/secure_storage.dart';

enum ConnState { disconnected, connecting, connected, reconnecting }

class Profile {
  const Profile({required this.role, required this.name, required this.lang, this.vehicle});
  final Role role;
  final String name, lang;
  final ({VehicleType type, String plate, String model})? vehicle;

  Profile withLang(String l) => Profile(role: role, name: name, lang: l, vehicle: vehicle);

  Json toJson() => {
        'role': role.name,
        'name': name,
        'lang': lang,
        if (vehicle != null) 'vehicle': {'type': vehicle!.type.name, 'plate': vehicle!.plate, 'model': vehicle!.model},
      };

  factory Profile.fromJson(Json j) {
    final v = j['vehicle'] as Map<String, dynamic>?;
    return Profile(
      role: Role.values.firstWhere((r) => r.name == j['role']),
      name: j['name'] as String,
      lang: j['lang'] as String,
      vehicle: v == null ? null : (type: VehicleType.values.firstWhere((t) => t.name == v['type']), plate: v['plate'] as String, model: (v['model'] as String?) ?? ''),
    );
  }
}

class ClientException implements Exception {
  ClientException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// WebSocket client for the Dharani server: registers once, reconnects with backoff, heartbeats, and
/// replays the `hello` handshake so the server can resume the current ride after a network change.
class DharaniClient {
  DharaniClient({
    required this.baseUrl,
    required this.profile,
    SecureStore? store,
    this.pingInterval = const Duration(seconds: 15),
    this.pongTimeout = const Duration(seconds: 25),
    this.minBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 15),
  }) : _store = store ?? SecureStore();

  final String baseUrl; // http://host:port or https://host
  Profile profile;
  final SecureStore _store;
  final Duration pingInterval, pongTimeout, minBackoff, maxBackoff;

  final _messages = StreamController<Json>.broadcast();
  final _audio = StreamController<Uint8List>.broadcast();
  final _states = StreamController<ConnState>.broadcast();
  ConnState _state = ConnState.disconnected;
  WebSocket? _socket;
  Timer? _retry, _pinger, _pongWatch;
  int _attempt = 0;
  bool _wantConnected = false;
  String? _userId;
  Json? _lastWelcome;
  final _rng = math.Random();
  final _outbox = <Json>[];

  Stream<Json> get messages => _messages.stream;

  /// Voice frames from the other party (binary WebSocket frames).
  Stream<Uint8List> get audio => _audio.stream;

  /// Sends one voice frame. Real-time audio is never queued: a frame that cannot go out now is dropped.
  void sendAudio(Uint8List frame) {
    final s = _socket;
    if (s != null && _state == ConnState.connected && s.readyState == WebSocket.open) {
      try {
        s.add(frame);
      } catch (_) {
        // closing underneath us: the frame is dropped, the reconnect logic takes over
      }
    }
  }
  Stream<ConnState> get states => _states.stream;
  ConnState get state => _state;
  String? get userId => _userId;
  Json? get lastWelcome => _lastWelcome;
  bool get connected => _state == ConnState.connected;

  void _setState(ConnState s) {
    if (_state == s) return;
    _state = s;
    if (!_states.isClosed) _states.add(s);
  }

  String get _storeKey => 'session:${Uri.parse(baseUrl).authority}:${profile.role.name}';

  /// Starts connecting and keeps the connection alive until [disconnect].
  Future<void> connect() async {
    _wantConnected = true;
    _attempt = 0;
    await _open();
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    _retry?.cancel();
    _pinger?.cancel();
    _pongWatch?.cancel();
    final s = _socket;
    _socket = null;
    await s?.close(1000, 'bye');
    _setState(ConnState.disconnected);
  }

  Future<void> dispose() async {
    await disconnect();
    await _messages.close();
    await _audio.close();
    await _states.close();
  }

  /// Changes the language this phone speaks; the server tells the other party of the active ride.
  /// A reconnect re-sends `hello` with the new language too.
  void setLanguage(String lang) {
    if (lang == profile.lang) return;
    profile = profile.withLang(lang);
    send({'t': T.setLang, 'lang': lang});
  }

  /// Sends a frame. While reconnecting, frames are queued (at most 50) and flushed after `hello`.
  void send(Json message) {
    final s = _socket;
    if (s != null && _state == ConnState.connected && s.readyState == WebSocket.open) {
      try {
        s.add(jsonEncode(message));
      } catch (_) {
        _outbox.add(message);
      }
    } else {
      if (_outbox.length >= 50) _outbox.removeAt(0);
      _outbox.add(message);
    }
  }

  Future<({String userId, String token})> _register({bool force = false}) async {
    if (!force) {
      final cached = await _store.read(_storeKey);
      if (cached != null) {
        final j = jsonDecode(cached) as Map<String, dynamic>;
        return (userId: j['userId'] as String, token: j['token'] as String);
      }
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await client.postUrl(Uri.parse('$baseUrl/v1/register')).timeout(const Duration(seconds: 10));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'name': profile.name, 'role': profile.role.name, 'lang': profile.lang}));
      final res = await req.close().timeout(const Duration(seconds: 10));
      final body = await utf8.decoder.bind(res).join();
      if (res.statusCode != 200) {
        String msg = 'Server refused registration (${res.statusCode})';
        try {
          msg = (jsonDecode(body) as Map)['error']?.toString() ?? msg;
        } catch (_) {}
        throw ClientException(msg);
      }
      final j = jsonDecode(body) as Map<String, dynamic>;
      await _store.write(_storeKey, jsonEncode({'userId': j['userId'], 'token': j['token']}));
      return (userId: j['userId'] as String, token: j['token'] as String);
    } on SocketException catch (e) {
      throw ClientException('Cannot reach the server at $baseUrl (${e.message}). Same Wi-Fi? Server running?');
    } on TimeoutException {
      throw ClientException('The server at $baseUrl did not answer in time.');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _open({bool reRegister = false}) async {
    if (!_wantConnected) return;
    _setState(_attempt == 0 ? ConnState.connecting : ConnState.reconnecting);
    try {
      final reg = await _register(force: reRegister);
      _userId = reg.userId;
      final wsUrl = Uri.parse(baseUrl).replace(scheme: baseUrl.startsWith('https') ? 'wss' : 'ws', path: '/v1/ws', queryParameters: {'token': reg.token});
      final socket = await WebSocket.connect(wsUrl.toString()).timeout(const Duration(seconds: 10));
      if (!_wantConnected) {
        await socket.close();
        return;
      }
      _socket = socket;
      socket.add(jsonEncode({'t': T.hello, 'protocol': protocolVersion, 'name': profile.name, 'lang': profile.lang, if (profile.vehicle != null) 'vehicle': {'type': profile.vehicle!.type.name, 'plate': profile.vehicle!.plate, 'model': profile.vehicle!.model}}));
      socket.listen(
        (data) => _onFrame(socket, data),
        onDone: () => _onClosed(socket),
        onError: (Object _) => _onClosed(socket),
        cancelOnError: true,
      );
    } on WebSocketException {
      // The upgrade was refused. Ask the server why: 401 means the saved token is no longer valid (the server
      // was restarted with a new secret), so register again; anything else is a transient failure.
      _scheduleRetry(reRegister: await _tokenRejected());
    } on ClientException catch (e) {
      if (!_messages.isClosed) _messages.add({'t': 'client.error', 'message': e.message});
      _scheduleRetry();
    } catch (_) {
      _scheduleRetry();
    }
  }

  Future<bool> _tokenRejected() async {
    final token = (await _store.read(_storeKey));
    if (token == null) return false;
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final t = (jsonDecode(token) as Map<String, dynamic>)['token'];
      final req = await client.getUrl(Uri.parse('$baseUrl/v1/ws?token=$t')).timeout(const Duration(seconds: 5));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
      return res.statusCode == 401;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  void _onFrame(WebSocket socket, Object? data) {
    if (!identical(socket, _socket)) return;
    _pongWatch?.cancel(); // any traffic proves the link is alive
    if (data is List<int>) {
      if (!_audio.isClosed) _audio.add(data is Uint8List ? data : Uint8List.fromList(data));
      return;
    }
    if (data is! String) return;
    final Json m;
    try {
      m = jsonDecode(data) as Json;
    } catch (_) {
      return;
    }
    final t = m['t'];
    if (t == T.welcome) {
      _lastWelcome = m;
      _attempt = 0;
      _setState(ConnState.connected);
      _startHeartbeat(socket);
      for (final queued in List.of(_outbox)) {
        socket.add(jsonEncode(queued));
      }
      _outbox.clear();
    } else if (t == T.pong) {
      _pongWatch?.cancel();
      return;
    } else if (t == T.error && (m['code'] == ErrorCode.protocol)) {
      _messages.add({'t': 'client.error', 'message': m['message']});
    }
    if (!_messages.isClosed) _messages.add(m);
  }

  void _startHeartbeat(WebSocket socket) {
    _pinger?.cancel();
    _pinger = Timer.periodic(pingInterval, (_) {
      if (!identical(socket, _socket) || socket.readyState != WebSocket.open) return;
      try {
        socket.add(jsonEncode({'t': T.ping}));
      } catch (_) {
        return;
      }
      _pongWatch?.cancel();
      _pongWatch = Timer(pongTimeout, () {
        // No pong: the link is dead even though the OS has not noticed. Drop it and reconnect.
        if (identical(socket, _socket)) socket.close(4001, 'pong timeout');
      });
    });
  }

  void _onClosed(WebSocket socket) {
    if (!identical(socket, _socket)) return;
    final code = socket.closeCode;
    _socket = null;
    _pinger?.cancel();
    _pongWatch?.cancel();
    if (code == 4000) {
      // The server accepted a newer connection for this user: that one is live, so do not fight it.
      _setState(ConnState.disconnected);
      if (!_messages.isClosed) _messages.add({'t': 'client.error', 'message': 'Another session took over this account.'});
      return;
    }
    if (_wantConnected) _scheduleRetry();
  }

  void _scheduleRetry({bool reRegister = false}) {
    if (!_wantConnected) return;
    _setState(ConnState.reconnecting);
    final base = minBackoff.inMilliseconds * math.pow(2, math.min(_attempt, 8)).toInt();
    final ms = math.min(base, maxBackoff.inMilliseconds);
    _attempt++;
    _retry?.cancel();
    _retry = Timer(Duration(milliseconds: ms + _rng.nextInt(ms ~/ 4 + 1)), () => _open(reRegister: reRegister));
  }
}
