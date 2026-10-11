import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';
import 'package:dharani_server/hub.dart';
import 'package:dharani_server/server.dart';

const secret = 'test-secret-0123456789abcdef';

Future<DharaniServer> startServer({HubConfig hub = const HubConfig(offerTtl: Duration(milliseconds: 400), retryInterval: Duration(milliseconds: 100), searchTimeout: Duration(seconds: 3), disconnectGrace: Duration(milliseconds: 300))}) async {
  final s = DharaniServer(ServerConfig(host: '127.0.0.1', port: 0, secret: secret, hub: hub));
  await s.start();
  return s;
}

class TestClient {
  TestClient._(this.server, this.role, this.name, this.lang, this.userId, this.token);

  final DharaniServer server;
  final Role role;
  final String name, lang, userId, token;
  late WebSocket socket;
  final _queue = <Json>[];
  final binary = <Uint8List>[];
  final _waiters = <Completer<void>>[];
  bool closed = false;
  int? closeCode;

  static Future<TestClient> register(DharaniServer s, Role role, {String name = 'Test', String lang = 'en'}) async {
    final c = HttpClient();
    final req = await c.postUrl(Uri.parse('http://127.0.0.1:${s.port}/v1/register'));
    req.headers.contentType = ContentType.json;
    req.write(jsonEncode({'name': name, 'role': role.name, 'lang': lang}));
    final res = await req.close();
    final body = jsonDecode(await utf8.decoder.bind(res).join()) as Map<String, dynamic>;
    c.close();
    return TestClient._(s, role, name, lang, body['userId'] as String, body['token'] as String);
  }

  Future<Json> connect({VehicleType? vehicle, String plate = 'KA01AB1234'}) async {
    socket = await WebSocket.connect('ws://127.0.0.1:${server.port}/v1/ws?token=$token');
    socket.listen((d) {
      if (d is List<int>) {
        binary.add(Uint8List.fromList(d));
        return;
      }
      _queue.add(jsonDecode(d as String) as Map<String, dynamic>);
      for (final w in _waiters.toList()) {
        if (!w.isCompleted) w.complete();
      }
    }, onDone: () {
      closed = true;
      closeCode = socket.closeCode;
      for (final w in _waiters.toList()) {
        if (!w.isCompleted) w.complete();
      }
    });
    send({'t': T.hello, 'protocol': protocolVersion, 'name': name, 'lang': lang, if (vehicle != null) 'vehicle': {'type': vehicle.name, 'plate': plate, 'model': 'Test'}});
    return next(T.welcome);
  }

  void send(Json m) => socket.add(jsonEncode(m));
  void sendBytes(List<int> b) => socket.add(b);

  /// Next message of [type]; other messages stay queued.
  Future<Json> next(String type, {Duration timeout = const Duration(seconds: 3), bool Function(Json)? where}) async {
    final end = DateTime.now().add(timeout);
    while (true) {
      final i = _queue.indexWhere((m) => m['t'] == type && (where?.call(m) ?? true));
      if (i >= 0) return _queue.removeAt(i);
      final left = end.difference(DateTime.now());
      if (left <= Duration.zero) throw TimeoutException('no "$type" message; queued: ${_queue.map((m) => m['t']).toList()}');
      final w = Completer<void>();
      _waiters.add(w);
      await w.future.timeout(left, onTimeout: () {});
      _waiters.remove(w);
    }
  }

  Future<bool> none(String type, {Duration wait = const Duration(milliseconds: 250)}) async {
    await Future<void>.delayed(wait);
    return !_queue.any((m) => m['t'] == type);
  }

  Future<void> closeSocket() async => socket.close();
}

Json place(String name, double lat, double lon) => {'name': name, 'lat': lat, 'lon': lon};
