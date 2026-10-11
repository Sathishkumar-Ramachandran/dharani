import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:dharani_server/discovery.dart';
import 'package:dharani_server/hub.dart';
import 'package:dharani_protocol/dharani_protocol.dart' show discoveryPort;
import 'package:dharani_server/server.dart';

/// dart run bin/server.dart [--port 8080] [--host 0.0.0.0] [--journal rides.jsonl] [--tls-cert c.pem --tls-key k.pem]
/// Environment: DHARANI_SECRET (>= 16 chars; random per run if unset, which logs everyone out on restart).
Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf('--$name');
    return (i >= 0 && i + 1 < args.length) ? args[i + 1] : null;
  }

  var secret = Platform.environment['DHARANI_SECRET'];
  if (secret == null || secret.length < 16) {
    final r = math.Random.secure();
    secret = List.generate(32, (_) => r.nextInt(36).toRadixString(36)).join();
    stderr.writeln('DHARANI_SECRET not set: using a random one (tokens are invalidated on restart).');
  }
  final server = DharaniServer(ServerConfig(
    host: opt('host') ?? '0.0.0.0',
    port: int.tryParse(opt('port') ?? '') ?? 8080,
    secret: secret,
    tlsCert: opt('tls-cert'),
    tlsKey: opt('tls-key'),
    hub: HubConfig(journalPath: opt('journal')),
  ));
  await server.start();
  DiscoveryResponder? discovery;
  if (!args.contains('--no-discovery')) {
    try {
      discovery = DiscoveryResponder(serverPort: server.port, tls: opt('tls-cert') != null);
      await discovery.start();
    } catch (e) {
      stderr.writeln('LAN discovery unavailable ($e); phones will need the server address.');
      discovery = null;
    }
  }
  final scheme = opt('tls-cert') != null ? 'wss' : 'ws';
  stdout.writeln('Dharani server listening on $scheme://${opt('host') ?? '0.0.0.0'}:${server.port}');
  stdout.writeln(discovery != null
      ? 'Phones on the same Wi-Fi find this server automatically (UDP $discoveryPort); no address needed.'
      : 'Phones on the same Wi-Fi: use http://<this-computer-LAN-IP>:${server.port} as the server URL.');

  final done = Completer<void>();
  for (final sig in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    sig.watch().listen((_) {
      if (!done.isCompleted) done.complete();
    });
  }
  await done.future;
  stdout.writeln('Shutting down…');
  await discovery?.stop();
  await server.stop();
}
