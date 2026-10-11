import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dharani_protocol/dharani_protocol.dart';

/// Answers LAN discovery probes so phones on the same Wi-Fi find the server without typing an address.
/// The reply goes only to the asker; it carries the HTTP(S) port, the phone takes the IP from the packet.
class DiscoveryResponder {
  DiscoveryResponder({required this.serverPort, this.tls = false, this.port = discoveryPort});
  final int serverPort;
  final bool tls;
  final int port;
  RawDatagramSocket? _socket;
  int answered = 0;

  /// The bound UDP port (differs from [port] when 0 was requested, as tests do).
  int get boundPort => _socket!.port;

  Future<void> start() async {
    final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, port, reuseAddress: true);
    _socket = s;
    final reply = utf8.encode(jsonEncode({'dharani': 'server', 'protocol': protocolVersion, 'port': serverPort, 'tls': tls}));
    s.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = s.receive();
      if (d == null || d.data.length > 64) return;
      if (utf8.decode(d.data, allowMalformed: true).trim() != discoveryProbe) return;
      answered++;
      s.send(reply, d.address, d.port);
    });
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
  }
}
