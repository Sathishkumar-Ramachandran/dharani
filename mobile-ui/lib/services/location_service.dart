import 'dart:async';

import 'package:geolocator/geolocator.dart';

enum LocationStatus { unknown, denied, deniedForever, serviceOff, ready }

class UserFix {
  const UserFix(this.lat, this.lon, this.accuracyM, this.headingDeg, this.speedMps, this.mocked);
  final double lat, lon, accuracyM, headingDeg, speedMps;
  final bool mocked;
}

/// Wraps Geolocator so UI code only deals with a status and a stream of fixes.
class LocationService {
  Future<LocationStatus> ensurePermission({bool request = true}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return LocationStatus.serviceOff;
    var p = await Geolocator.checkPermission();
    if (p == LocationPermission.denied && request) p = await Geolocator.requestPermission();
    return switch (p) {
      LocationPermission.denied => LocationStatus.denied,
      LocationPermission.deniedForever => LocationStatus.deniedForever,
      _ => LocationStatus.ready,
    };
  }

  static UserFix _fix(Position p) => UserFix(p.latitude, p.longitude, p.accuracy, p.heading, p.speed, p.isMocked);

  Future<UserFix?> current() async {
    try {
      return _fix(await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 15))));
    } catch (_) {
      final last = await Geolocator.getLastKnownPosition();
      return last == null ? null : _fix(last);
    }
  }

  /// `background: true` runs Android's foreground location service (with a visible notification) so a
  /// driver keeps reporting position while the screen is off or another app is in front.
  Stream<UserFix> stream({bool background = false}) => Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.best,
          intervalDuration: const Duration(seconds: 1),
          distanceFilter: 0,
          foregroundNotificationConfig: background
              ? const ForegroundNotificationConfig(
                  notificationTitle: 'Dharani Driver',
                  notificationText: 'Sharing your location with riders while you are online',
                  enableWakeLock: true,
                  setOngoing: true,
                )
              : null,
        ),
      ).map(_fix);

  Future<void> openSettings() => Geolocator.openAppSettings();
  Future<void> openLocationSettings() => Geolocator.openLocationSettings();
}
