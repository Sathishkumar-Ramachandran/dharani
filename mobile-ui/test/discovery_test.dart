// Server discovery over UDP, against the real responder from the server package (loopback).
import 'dart:io';

import 'package:dharani_mobile/net/discovery.dart';
import 'package:dharani_mobile/state/session_cubit.dart';
import 'package:dharani_mobile/net/dharani_client.dart';
import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:dharani_server/discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a phone finds the server by broadcast probe and gets its HTTP port', () async {
    final r = DiscoveryResponder(serverPort: 8123, port: 0);
    await r.start();
    final url = await discoverServer(port: r.boundPort, targets: [InternetAddress.loopbackIPv4], timeout: const Duration(seconds: 3));
    expect(url, 'http://127.0.0.1:8123');
    expect(r.answered, greaterThanOrEqualTo(1));
    await r.stop();
  });

  test('no server on the network: returns null at the timeout', () async {
    final url = await discoverServer(port: 47999, targets: [InternetAddress.loopbackIPv4], timeout: const Duration(milliseconds: 800));
    expect(url, isNull);
  });

  test('auto mode: session keeps searching, then connects to what it finds', () async {
    var tries = 0;
    String? usedUrl;
    final s = SessionCubit(
      discover: () async => ++tries < 3 ? null : 'http://10.0.0.7:8080',
      clientFactory: (url, p) {
        usedUrl = url;
        return DharaniClient(baseUrl: 'http://127.0.0.1:1', profile: p, minBackoff: const Duration(hours: 1));
      },
    );
    await s.configure(profile: const Profile(role: proto.Role.rider, name: 'A', lang: 'hi'), serverUrl: '');
    expect(s.state.serverUrl, kAutoServer);
    expect(s.state.searching, isTrue, reason: 'configure returns while still searching');
    for (var i = 0; i < 100 && usedUrl == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(tries, 3);
    expect(usedUrl, 'http://10.0.0.7:8080');
    expect(s.state.resolvedUrl, 'http://10.0.0.7:8080');
    await s.close();
  });
}
