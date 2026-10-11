import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dharani_protocol/dharani_protocol.dart';

/// Finds a Dharani server on the local network: broadcasts a probe (limited broadcast plus the /24
/// broadcast of every Wi-Fi/Ethernet interface, because Android may route 255.255.255.255 over mobile
/// data) and takes the first valid reply. Returns e.g. `http://192.168.1.20:8080`, or null on timeout.
Future<String?> discoverServer({Duration timeout = const Duration(seconds: 4), int port = discoveryPort, List<InternetAddress>? targets}) async {
  RawDatagramSocket? socket;
  Timer? ticker;
  final done = Completer<String?>();
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    socket.broadcastEnabled = true;
    final probe = utf8.encode(discoveryProbe);
    final dests = targets ?? await _broadcastTargets();
    void sendProbe() {
      for (final a in dests) {
        try {
          socket!.send(probe, a, port);
        } catch (_) {}
      }
    }

    socket.listen((e) {
      if (e != RawSocketEvent.read || done.isCompleted) return;
      final d = socket!.receive();
      if (d == null || d.data.length > 256) return;
      try {
        final j = jsonDecode(utf8.decode(d.data)) as Map<String, dynamic>;
        if (j['dharani'] != 'server' || j['protocol'] != protocolVersion) return;
        final p = j['port'];
        if (p is! int || p < 1 || p > 65535) return;
        done.complete('${j['tls'] == true ? 'https' : 'http'}://${d.address.address}:$p');
      } catch (_) {}
    });
    sendProbe();
    ticker = Timer.periodic(const Duration(seconds: 1), (_) => sendProbe());
    return await done.future.timeout(timeout, onTimeout: () => null);
  } catch (_) {
    return null;
  } finally {
    ticker?.cancel();
    socket?.close();
  }
}

/// Broadcast addresses plus a unicast sweep of the phone's own subnet. Many Wi-Fi access points drop
/// broadcast between clients but pass unicast, so the sweep (own /24 and its /23 neighbour) is the
/// part that makes this work on such networks. ~512 tiny packets, sent once per probe round.
Future<List<InternetAddress>> _broadcastTargets() async {
  final out = <String>{'255.255.255.255'};
  try {
    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        final o = a.address.split('.').map(int.tryParse).toList();
        if (o.length != 4 || o.contains(null) || a.isLoopback || a.isLinkLocal) continue;
        final b = o[2]!;
        for (final third in {b, b ^ 1}) {
          out.add('${o[0]}.${o[1]}.$third.255');
          for (var h = 1; h < 255; h++) {
            if (third == b && h == o[3]) continue;
            out.add('${o[0]}.${o[1]}.$third.$h');
          }
        }
      }
    }
  } catch (_) {}
  return [for (final s in out) InternetAddress(s)];
}
