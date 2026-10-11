import 'package:flutter/services.dart';

/// Android: keeps the phone reachable on battery with the screen off while something needs the socket
/// (driver online, ride in progress, call). Several owners can hold it; it stops when the last lets go.
/// No-op on other platforms and in tests (no native side).
class StayReachable {
  StayReachable._();
  static const _ch = MethodChannel('dharani/keepalive');
  static final _owners = <String>{};
  static bool _running = false;

  static Future<void> hold(String owner, {String text = 'Ready for requests'}) async {
    _owners.add(owner);
    if (_running) return;
    _running = true;
    try {
      await _ch.invokeMethod('start', {'text': text});
    } catch (_) {
      _running = false; // not on Android / not available
    }
  }

  static Future<void> release(String owner) async {
    _owners.remove(owner);
    if (_owners.isNotEmpty || !_running) return;
    _running = false;
    try {
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  /// Wakes the screen and shows a heads-up alert (ride offer, incoming call) when the app is not in front.
  static Future<void> alert(String title, String text) async {
    try {
      await _ch.invokeMethod('alert', {'title': title, 'text': text});
    } catch (_) {}
  }

  static Future<void> clearAlert() async {
    try {
      await _ch.invokeMethod('clearAlert');
    } catch (_) {}
  }

  /// Asks Android to exempt the app from battery optimisation (one system dialog, once).
  static Future<void> ensureBatteryExempt() async {
    try {
      if (await _ch.invokeMethod<bool>('batteryExempt') == true) return;
      await _ch.invokeMethod('requestBatteryExempt');
    } catch (_) {}
  }
}
