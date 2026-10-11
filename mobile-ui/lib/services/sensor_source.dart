import 'dart:async';
import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../core/native_bridge.dart';
import '../core/geo.dart';

/// A ~1 Hz stream of synchronised GNSS + IMU + wheel-odometer samples.
abstract class SensorSource {
  Stream<TelemetrySample> get samples;

  /// Reefer / cargo temperature; the phone has no probe, so this is operator supplied.
  double reeferTempC = double.nan;

  Future<void> start();
  Future<void> stop();

  /// Milliseconds of "trip time" per sample (1000 for live GPS).
  int get sampleIntervalMs;
}

const double kMetersPerTick = 0.25;

/// Real device sensors: GPS (with the OS mock-location indicator), accelerometer and gyroscope.
/// There is no CAN bus on a phone, so wheel ticks are derived from GNSS Doppler speed.
class DeviceSensorSource extends SensorSource {
  final _controller = StreamController<TelemetrySample>.broadcast();
  StreamSubscription<Position>? _gps;
  StreamSubscription<AccelerometerEvent>? _accel;
  StreamSubscription<GyroscopeEvent>? _gyro;
  AccelerometerEvent? _lastAccel;
  GyroscopeEvent? _lastGyro;
  double _ticks = 0;
  int _lastNs = 0;

  @override
  Stream<TelemetrySample> get samples => _controller.stream;

  @override
  int get sampleIntervalMs => 1000;

  @override
  Future<void> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw StateError('Location services are switched off. Enable GPS and try again.');
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      throw StateError('Location permission was denied. Grant it in system settings.');
    }
    _accel = accelerometerEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) => _lastAccel = e);
    _gyro = gyroscopeEventStream(samplingPeriod: SensorInterval.gameInterval).listen((e) => _lastGyro = e);
    _gps = Geolocator.getPositionStream(
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        intervalDuration: const Duration(seconds: 1),
        distanceFilter: 0,
      ),
    ).listen(_onPosition, onError: _controller.addError);
  }

  void _onPosition(Position p) {
    final nowNs = DateTime.now().microsecondsSinceEpoch * 1000;
    if (_lastNs != 0) {
      final dt = (nowNs - _lastNs) / 1e9;
      _ticks += math.max(0.0, p.speed) * dt / kMetersPerTick;
    }
    _lastNs = nowNs;
    final a = _lastAccel, g = _lastGyro;
    _controller.add(TelemetrySample(
      timestampNs: nowNs,
      lat: p.latitude,
      lon: p.longitude,
      altM: p.altitude,
      dop: (p.accuracy / 4.0).clamp(0.75, 25.0),
      speedMps: math.max(0.0, p.speed),
      headingDeg: p.heading,
      accuracyM: p.accuracy,
      ax: a?.x ?? 0,
      ay: a?.y ?? 0,
      az: a?.z ?? 9.80665,
      gx: g?.x ?? 0,
      gy: g?.y ?? 0,
      gz: g?.z ?? 0,
      odometerTicks: _ticks.round(),
      metersPerTick: kMetersPerTick,
      temperatureC: reeferTempC,
      mockLocation: p.isMocked,
    ));
  }

  @override
  Future<void> stop() async {
    await _gps?.cancel();
    await _accel?.cancel();
    await _gyro?.cancel();
    _gps = _accel = _gyro = null;
  }
}

/// Drives a vehicle along a route polyline with realistic sensor noise. Samples are always one
/// trip-second apart (like a real 1 Hz receiver); `timeScale` of them are emitted per real
/// second, so an 80 km haul finishes in minutes while every physical quantity (speed,
/// acceleration, odometer, temperature excursion time) stays consistent.
class SimulatedSensorSource extends SensorSource {
  SimulatedSensorSource({
    required List<({double lat, double lon})> polyline,
    this.timeScale = 10,
    this.cruiseMps = 22.0,
    this.tickInterval = const Duration(seconds: 1),
    this.stops = const [],
    int? seed,
    int? startEpochNs,
  })  : _poly = roundCorners(polyline),
        _rng = math.Random(seed ?? 42),
        _clockNs = startEpochNs ?? DateTime.now().microsecondsSinceEpoch * 1000 {
    _cum = [0];
    for (var i = 1; i < _poly.length; i++) {
      _cum.add(_cum.last + haversineMeters(_poly[i - 1].lat, _poly[i - 1].lon, _poly[i].lat, _poly[i].lon));
    }
  }

  final List<({double lat, double lon})> _poly;

  /// Replaces sharp polyline vertices by short arcs (<= `radiusM` each side). A real vehicle
  /// cannot change heading instantly, and the attestation filter (rightly) expects continuous
  /// motion, so the simulated truck follows a drivable path.
  static List<({double lat, double lon})> roundCorners(List<({double lat, double lon})> p, {double radiusM = 22}) {
    if (p.length < 3) return p;
    ({double lat, double lon}) lerp(({double lat, double lon}) a, ({double lat, double lon}) b, double t) =>
        (lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t);
    final out = <({double lat, double lon})>[p.first];
    for (var i = 1; i < p.length - 1; i++) {
      final a = p[i - 1], b = p[i], c = p[i + 1];
      final l1 = haversineMeters(a.lat, a.lon, b.lat, b.lon), l2 = haversineMeters(b.lat, b.lon, c.lat, c.lon);
      if (l1 < 1 || l2 < 1) continue;
      final h1 = _bearing(a, b), h2 = _bearing(b, c);
      if (_angleDiff(h2, h1).abs() < 12) {
        out.add(b);
        continue;
      }
      final d1 = math.min(radiusM, l1 * 0.45), d2 = math.min(radiusM, l2 * 0.45);
      final p1 = lerp(b, a, d1 / l1), p2 = lerp(b, c, d2 / l2);
      for (var k = 0; k <= 6; k++) {
        final t = k / 6;
        // quadratic Bezier p1 -> b -> p2
        final q1 = lerp(p1, b, t), q2 = lerp(b, p2, t);
        out.add(lerp(q1, q2, t));
      }
    }
    out.add(p.last);
    return out;
  }

  static double _bearing(({double lat, double lon}) a, ({double lat, double lon}) b) {
    final y = math.sin((b.lon - a.lon) * math.pi / 180) * math.cos(b.lat * math.pi / 180);
    final x = math.cos(a.lat * math.pi / 180) * math.sin(b.lat * math.pi / 180) -
        math.sin(a.lat * math.pi / 180) * math.cos(b.lat * math.pi / 180) * math.cos((b.lon - a.lon) * math.pi / 180);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }
  late final List<double> _cum;
  final math.Random _rng;
  final int timeScale;
  final double cruiseMps;
  final Duration tickInterval;

  /// Places where the vehicle brakes to a halt and waits (e.g. picking up a rider).
  final List<({double atMeters, int dwellSamples})> stops;
  int _stopIdx = 0;
  int _dwell = 0;
  double? _lastHeading;

  static double _angleDiff(double a, double b) => ((a - b + 540) % 360) - 180;
  final _controller = StreamController<TelemetrySample>.broadcast();
  Timer? _timer;

  int _clockNs;
  double _along = 0;
  double _speed = 0;
  double _ticks = 0;
  double _teleportM = 0;

  /// Position the simulated vehicle currently occupies on the route.
  double get progressFraction => _cum.last == 0 ? 1 : (_along / _cum.last).clamp(0.0, 1.0);

  /// Spoof: GNSS reports a position `meters` further along than the vehicle really is.
  void injectTeleport(double meters) => _teleportM += meters;

  /// Spoof: wheels stop reporting movement while GNSS keeps moving (mock GPS rig).
  bool freezeWheels = false;

  @override
  Stream<TelemetrySample> get samples => _controller.stream;

  @override
  int get sampleIntervalMs => 1000;

  @override
  Future<void> start() async {
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) => _tick());
  }

  double _gauss(double sigma) {
    // Box-Muller
    final u1 = 1 - _rng.nextDouble(), u2 = _rng.nextDouble();
    return sigma * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2);
  }

  ({double lat, double lon, double heading}) _positionAt(double meters) {
    final m = meters.clamp(0.0, _cum.last);
    var i = 1;
    while (i < _cum.length - 1 && _cum[i] < m) {
      i++;
    }
    final seg = _cum[i] - _cum[i - 1];
    final t = seg <= 0 ? 0.0 : (m - _cum[i - 1]) / seg;
    final a = _poly[i - 1], b = _poly[i];
    final lat = a.lat + (b.lat - a.lat) * t;
    final lon = a.lon + (b.lon - a.lon) * t;
    final y = math.sin((b.lon - a.lon) * math.pi / 180) * math.cos(b.lat * math.pi / 180);
    final x = math.cos(a.lat * math.pi / 180) * math.sin(b.lat * math.pi / 180) -
        math.sin(a.lat * math.pi / 180) * math.cos(b.lat * math.pi / 180) * math.cos((b.lon - a.lon) * math.pi / 180);
    final heading = (math.atan2(y, x) * 180 / math.pi + 360) % 360;
    return (lat: lat, lon: lon, heading: heading);
  }

  void _tick() {
    for (var i = 0; i < timeScale; i++) {
      _step();
    }
  }

  void _step() {
    if (_poly.length < 2) return;
    const dt = 1.0;
    final remaining = _cum.last - _along;
    // Accelerate to cruise (1.2 m/s^2), brake for the last 150 m.
    var target = remaining < 150 ? math.max(3.0, remaining / 8) : cruiseMps;
    // Slow down for corners, as a driver would: look up to 100 m ahead for a heading change.
    final h0 = _positionAt(_along).heading;
    var maxTurn = 0.0;
    for (final ahead in const [15.0, 30.0, 50.0, 75.0, 100.0]) {
      maxTurn = math.max(maxTurn, _angleDiff(_positionAt(_along + ahead).heading, h0).abs());
    }
    if (maxTurn > 60) {
      target = math.min(target, 2.0);
    } else if (maxTurn > 30) {
      target = math.min(target, 5.0);
    }
    double? stopRemaining;
    if (_stopIdx < stops.length) {
      final st = stops[_stopIdx];
      if (_dwell > 0) {
        target = 0;
        _speed = 0;
        _dwell--;
        if (_dwell == 0) _stopIdx++;
      } else {
        final rem = st.atMeters - _along;
        stopRemaining = rem;
        if (rem < 150) target = math.min(target, math.max(1.5, rem / 8));
        if (rem <= 2) {
          _along = st.atMeters;
          _speed = 0;
          _dwell = st.dwellSamples;
          target = 0;
          stopRemaining = null;
        }
      }
    }
    final accelLimit = 1.2 * dt;
    final dv = (target - _speed).clamp(-accelLimit * 2.5, accelLimit);
    final accel = dv / dt;
    _speed = math.max(0.0, _speed + dv);
    var step = _speed * dt;
    if (stopRemaining != null && step > stopRemaining) step = math.max(0.0, stopRemaining);
    _along = math.min(_cum.last, _along + step);
    _clockNs += (dt * 1e9).round();
    if (!freezeWheels) _ticks += step / kMetersPerTick;

    final truth = _positionAt(_along);
    final yawRate = _lastHeading == null ? 0.0 : _angleDiff(truth.heading, _lastHeading!) * math.pi / 180 / dt;
    _lastHeading = truth.heading;
    final lateral = _speed * yawRate; // centripetal acceleration, m/s^2
    final reported = _positionAt(_along + _teleportM);
    final lat = reported.lat + _gauss(1.5) / 110574.0;
    final lon = reported.lon + _gauss(1.5) / (111320.0 * math.cos(reported.lat * math.pi / 180));
    final headingRad = truth.heading * math.pi / 180;

    _controller.add(TelemetrySample(
      timestampNs: _clockNs,
      lat: lat,
      lon: lon,
      altM: 900 + _gauss(0.5),
      dop: 1.0,
      speedMps: _speed,
      headingDeg: reported.heading,
      accuracyM: 4,
      // Specific force: forward acceleration split into device axes plus gravity on z.
      ax: accel * math.sin(headingRad) + lateral * math.cos(headingRad) + _gauss(0.15),
      ay: accel * math.cos(headingRad) - lateral * math.sin(headingRad) + _gauss(0.15),
      az: 9.80665 + _gauss(0.15),
      gx: _gauss(0.01),
      gy: _gauss(0.01),
      gz: yawRate + _gauss(0.01),
      odometerTicks: _ticks.round(),
      metersPerTick: kMetersPerTick,
      temperatureC: reeferTempC,
      engineRpm: (900 + _speed * 60).round(),
      fuelPct: math.max(5.0, 80 - progressFraction * 20),
      batterySocPct: 96,
    ));
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
  }
}
