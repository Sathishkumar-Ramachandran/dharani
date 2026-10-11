import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dharani_protocol/dharani_protocol.dart';

class TokenClaims {
  const TokenClaims(this.uid, this.role, this.expires);
  final String uid;
  final Role role;
  final DateTime expires;
}

/// HMAC-SHA256 signed bearer tokens: base64url(payload) + "." + base64url(mac).
class TokenService {
  TokenService(String secret, {DateTime Function()? clock})
      : _key = utf8.encode(secret),
        _clock = clock ?? DateTime.now {
    if (secret.length < 16) throw ArgumentError('token secret must be at least 16 characters');
  }

  final List<int> _key;
  final DateTime Function() _clock;

  String issue(String uid, Role role, {Duration ttl = const Duration(days: 30)}) {
    final payload = base64Url.encode(utf8.encode(jsonEncode({'u': uid, 'r': role.name, 'e': _clock().add(ttl).millisecondsSinceEpoch ~/ 1000})));
    return '$payload.${_mac(payload)}';
  }

  /// Returns null for a malformed, tampered or expired token.
  TokenClaims? verify(String? token) {
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 2 || !_constantTimeEquals(parts[1], _mac(parts[0]))) return null;
    try {
      final j = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0])))) as Map<String, dynamic>;
      final role = Role.values.firstWhere((r) => r.name == j['r']);
      final exp = DateTime.fromMillisecondsSinceEpoch((j['e'] as int) * 1000);
      if (!exp.isAfter(_clock())) return null;
      return TokenClaims(j['u'] as String, role, exp);
    } catch (_) {
      return null;
    }
  }

  String _mac(String payload) => base64Url.encode(Hmac(sha256, _key).convert(utf8.encode(payload)).bytes);

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var r = 0;
    for (var i = 0; i < a.length; i++) {
      r |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return r == 0;
  }
}

/// Token bucket: `burst` messages, refilled at `perSecond`.
class RateLimiter {
  RateLimiter({this.perSecond = 30, this.burst = 60, DateTime Function()? clock}) : _clock = clock ?? DateTime.now, _tokens = burst.toDouble() {
    _last = _clock();
  }

  final double perSecond;
  final int burst;
  final DateTime Function() _clock;
  double _tokens;
  late DateTime _last;

  bool allow() {
    final now = _clock();
    _tokens = (_tokens + now.difference(_last).inMicroseconds / 1e6 * perSecond).clamp(0, burst.toDouble());
    _last = now;
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}
