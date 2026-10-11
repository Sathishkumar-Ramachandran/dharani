import 'dart:async';
import 'dart:math' as math;

import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/geo.dart';
import '../core/native_bridge.dart';
import '../models/telemetry_node.dart';
import '../models/trip_manifest.dart';
import '../services/engine_host.dart';
import '../services/sensor_source.dart';
import '../net/remote_models.dart';
import 'location_cubit.dart';
import 'session_cubit.dart';
import 'trip_state_notifier.dart' show EscrowView;

enum RideMode { auto, cab, bike }

extension RideModeInfo on RideMode {
  String get label => switch (this) { RideMode.auto => 'Auto', RideMode.cab => 'Cab', RideMode.bike => 'Bike taxi' };
  String get blurb => switch (this) {
        RideMode.auto => 'Auto-rickshaw · up to 3',
        RideMode.cab => 'Hatchback · AC · up to 4',
        RideMode.bike => 'Fastest in traffic · 1 rider',
      };
  int get costing => this == RideMode.bike ? 2 : 0;
  double get base => switch (this) { RideMode.auto => 30, RideMode.cab => 50, RideMode.bike => 20 };
  double get perKm => switch (this) { RideMode.auto => 14, RideMode.cab => 17, RideMode.bike => 8 };
  double get perMin => switch (this) { RideMode.auto => 1.0, RideMode.cab => 1.5, RideMode.bike => 0.6 };
}

class RideQuote {
  const RideQuote(this.mode, this.fareRupees, this.route);
  final RideMode mode;
  final int fareRupees;
  final RouteResult route;
}

enum RideStage { idle, quoted, searching, toPickup, onTrip, completed, disputed, failed }

class RideState {
  const RideState({
    this.stage = RideStage.idle,
    this.pickup,
    this.drop,
    this.quotes = const [],
    this.selected = RideMode.auto,
    this.driverName = '',
    this.vehicleNo = '',
    this.otp = '',
    this.driver,
    this.activeRoute = const [],
    this.etaS = 0,
    this.remainingM = 0,
    this.escrow = const EscrowView(),
    this.proofs = 0,
    this.message,
    this.error,
    this.busy = false,
    this.remoteId,
    this.driverLang,
  });

  final String? remoteId, driverLang; // set when the ride is served by a real driver over the server
  bool get remote => remoteId != null;
  final RideStage stage;
  final Place? pickup, drop;
  final List<RideQuote> quotes;
  final RideMode selected;
  final String driverName, vehicleNo, otp;
  final TelemetryNode? driver;
  final List<({double lat, double lon})> activeRoute;
  final double etaS, remainingM;
  final EscrowView escrow;
  final int proofs;
  final String? message, error;
  final bool busy;

  RideQuote? get selectedQuote {
    for (final q in quotes) {
      if (q.mode == selected) return q;
    }
    return null;
  }

  bool get active => stage == RideStage.searching || stage == RideStage.toPickup || stage == RideStage.onTrip;

  RideState copyWith({
    RideStage? stage,
    Place? pickup,
    Place? drop,
    List<RideQuote>? quotes,
    RideMode? selected,
    String? driverName,
    String? vehicleNo,
    String? otp,
    TelemetryNode? driver,
    List<({double lat, double lon})>? activeRoute,
    double? etaS,
    double? remainingM,
    EscrowView? escrow,
    int? proofs,
    String? message,
    String? error,
    bool? busy,
    String? remoteId,
    String? driverLang,
    bool clearRemote = false,
    bool clearPickup = false,
    bool clearDrop = false,
    bool clearError = false,
    bool clearMessage = false,
    bool clearDriver = false,
  }) =>
      RideState(
        stage: stage ?? this.stage,
        pickup: clearPickup ? null : (pickup ?? this.pickup),
        drop: clearDrop ? null : (drop ?? this.drop),
        quotes: quotes ?? this.quotes,
        selected: selected ?? this.selected,
        driverName: driverName ?? this.driverName,
        vehicleNo: vehicleNo ?? this.vehicleNo,
        otp: otp ?? this.otp,
        driver: clearDriver ? null : (driver ?? this.driver),
        activeRoute: activeRoute ?? this.activeRoute,
        etaS: etaS ?? this.etaS,
        remainingM: remainingM ?? this.remainingM,
        escrow: escrow ?? this.escrow,
        proofs: proofs ?? this.proofs,
        message: clearMessage ? null : (message ?? this.message),
        error: clearError ? null : (error ?? this.error),
        busy: busy ?? this.busy,
        remoteId: clearRemote ? null : (remoteId ?? this.remoteId),
        driverLang: clearRemote ? null : (driverLang ?? this.driverLang),
      );
}

/// B2C: a passenger books a ride. Fares are computed on-device from the offline route; the driver
/// is simulated (there is no driver network behind this build) and its device signs the ride.
class RideCubit extends Cubit<RideState> {
  RideCubit({
    required this.host,
    required this.location,
    this.timeScale = 8,
    this.tickInterval = const Duration(seconds: 1),
    this.matchDelay = const Duration(milliseconds: 2500),
    int? seed,
    this.session,
  })  : _rng = math.Random(seed),
        super(const RideState()) {
    _remoteSub = session?.messages.listen(_onServer);
  }

  /// When set and connected, rides are served by real drivers through the server instead of the simulation.
  final SessionCubit? session;
  StreamSubscription<proto.Json>? _remoteSub;
  bool get _useRemote => session != null && session!.state.configured && !session!.state.demo;

  static const owner = 'ride';
  final EngineHost host;
  final LocationCubit location;
  final int timeScale;
  final Duration tickInterval;
  final Duration matchDelay;

  final math.Random _rng;
  SimulatedSensorSource? _sensor;
  StreamSubscription<TelemetrySample>? _sub;
  bool _processing = false;
  String _txn = '';
  double _leg1M = 0, _totalM = 0;
  bool _boarded = false;
  int _clockNs = 0;

  DharaniNative get _native => host.native;

  // ------------------------------------------------------------ planning
  Future<void> setPickup(Place? p) async {
    emit(state.copyWith(pickup: p, clearPickup: p == null, clearError: true));
    await _quote();
  }

  Future<void> setDrop(Place? p) async {
    emit(state.copyWith(drop: p, clearDrop: p == null, clearError: true));
    await _quote();
  }

  void selectMode(RideMode m) => emit(state.copyWith(selected: m));

  Place? _effectivePickup() {
    final p = state.pickup;
    if (p != null) return p;
    final f = location.state.fix;
    return f == null ? null : Place('My location', f.lat, f.lon);
  }

  Future<void> refreshQuotes() => _quote();

  Future<void> _quote() async {
    if (state.active) return;
    final pickup = _effectivePickup(), drop = state.drop;
    if (pickup == null || drop == null) {
      emit(state.copyWith(stage: RideStage.idle, quotes: const [], activeRoute: const []));
      return;
    }
    if (haversineMeters(pickup.lat, pickup.lon, drop.lat, drop.lon) < 150) {
      emit(state.copyWith(error: 'Pickup and drop are too close together.', quotes: const [], stage: RideStage.idle));
      return;
    }
    emit(state.copyWith(busy: true, clearError: true));
    try {
      final quotes = <RideQuote>[];
      DharaniException? lastError;
      for (final m in RideMode.values) {
        try {
          final r = _native.calculateRoute(
              startLat: pickup.lat, startLon: pickup.lon, destLat: drop.lat, destLon: drop.lon, costing: m.costing);
          final fare = (m.base + m.perKm * r.distanceM / 1000 + m.perMin * r.durationS / 60).round();
          quotes.add(RideQuote(m, fare < m.base ? m.base.round() : fare, r));
        } on DharaniException catch (e) {
          lastError = e; // e.g. bikes are not allowed on this road; offer the other modes
        }
      }
      if (quotes.isEmpty) throw lastError!;
      final sel = quotes.firstWhere((q) => q.mode == state.selected, orElse: () => quotes.first);
      emit(state.copyWith(
        stage: RideStage.quoted,
        quotes: quotes,
        selected: sel.mode,
        busy: false,
        activeRoute: sel.route.polyline,
      ));
    } on DharaniException catch (e) {
      emit(state.copyWith(
          busy: false,
          stage: RideStage.idle,
          quotes: const [],
          activeRoute: const [],
          error: e.code == DharaniCode.notFound
              ? 'No offline roads installed. Open Account → Offline roads and download your area.'
              : e.code == DharaniCode.routingFailed
                  ? 'No route found. This area may be outside your downloaded roads.'
                  : e.message));
    }
  }

  // ------------------------------------------------------------ booking
  Future<void> requestRide() async {
    final q = state.selectedQuote;
    final pickup = _effectivePickup(), drop = state.drop;
    if (q == null || pickup == null || drop == null || state.active) return;
    if (_useRemote) return _requestRemote(q, pickup, drop);
    if (!host.claim(owner)) {
      emit(state.copyWith(error: 'A freight trip is in progress. Finish it before booking a ride.'));
      return;
    }
    emit(state.copyWith(stage: RideStage.searching, clearError: true, clearMessage: true, message: 'Finding a nearby driver…'));
    await Future<void>.delayed(matchDelay);
    if (state.stage != RideStage.searching) return; // cancelled meanwhile

    try {
      // Spawn the driver ~1.2 km away on a real road: try a few bearings until a route exists.
      RouteResult? toPickup;
      for (var i = 0; i < 6 && toPickup == null; i++) {
        final s = offsetPoint(pickup.lat, pickup.lon, _rng.nextDouble() * 360, 900 + _rng.nextDouble() * 600);
        try {
          final r = _native.calculateRoute(
              startLat: s.lat, startLon: s.lon, destLat: pickup.lat, destLon: pickup.lon, costing: q.mode.costing);
          if (r.distanceM > 200) toPickup = r;
        } on DharaniException {
          // try another bearing
        }
      }
      if (toPickup == null) throw StateError('No driver could reach you on the downloaded roads.');

      final driverId = 'driver-${1000 + _rng.nextInt(9000)}';
      final names = ['Ravi K', 'Murugan S', 'Imran A', 'Lakshmi P', 'Suresh B', 'Anita D'];
      final name = names[_rng.nextInt(names.length)];
      final plate = 'KA-0${1 + _rng.nextInt(9)}-${String.fromCharCode(65 + _rng.nextInt(26))}${String.fromCharCode(65 + _rng.nextInt(26))}-${1000 + _rng.nextInt(9000)}';
      final otp = (1000 + _rng.nextInt(9000)).toString();

      _clockNs = DateTime.now().microsecondsSinceEpoch * 1000;
      _txn = 'RIDE-${DateTime.now().millisecondsSinceEpoch}';
      _openContract(pickup, drop, q, driverId, toPickup);

      final poly = [...toPickup.polyline, ...q.route.polyline.skip(1)];
      _leg1M = toPickup.distanceM;
      _totalM = toPickup.distanceM + q.route.distanceM;
      _boarded = false;
      _native.beginTrip(_txn);
      _sensor = SimulatedSensorSource(polyline: poly, timeScale: timeScale, cruiseMps: 13, tickInterval: tickInterval, startEpochNs: _clockNs,
          stops: [(atMeters: _leg1M, dwellSamples: 6)]);
      _processing = false;
      emit(state.copyWith(
        stage: RideStage.toPickup,
        driverName: name,
        vehicleNo: plate,
        otp: otp,
        activeRoute: toPickup.polyline,
        etaS: toPickup.durationS,
        remainingM: toPickup.distanceM,
        escrow: const EscrowView(state: 'DISPATCHED', funded: true),
        clearMessage: true,
      ));
      _sub = _sensor!.samples.listen(_onSample);
      await _sensor!.start();
    } catch (e) {
      await _teardown();
      emit(state.copyWith(stage: RideStage.failed, error: '$e'));
    }
  }

  Map<String, dynamic> _req(String action, Map<String, dynamic> message, {int? ts}) => {
        'context': {
          'domain': 'dharani:b2c-mobility',
          'transaction_id': _txn,
          'message_id': '$action-${_clockNs++}',
          'bap_id': 'rider.${host.vehicleId}',
          'bpp_id': 'driver',
          'timestamp_ns': ts ?? _clockNs,
        },
        'message': message,
      };

  void _openContract(Place pickup, Place drop, RideQuote q, String driverId, RouteResult toPickup) {
    Map<String, dynamic> place(Place p, double r) => {'name': p.name, 'lat': p.lat, 'lon': p.lon, 'radius_m': r};
    final deadline = _clockNs ~/ 1000000000 + ((toPickup.durationS + q.route.durationS) * 3).round() + 1800;
    _native.becknCall('search', _req('search', {
      'rfq': {
        'transaction_id': _txn,
        'consignor_id': 'rider-${host.vehicleId.substring(0, math.min(8, host.vehicleId.length))}',
        'origin': place(pickup, 60),
        'destination': place(drop, 80),
        'cargo': {'volume_m3': 0.5, 'tonnage': 0.075, 'temperature_controlled': false}, // one passenger
        'delivery_deadline_epoch_s': deadline,
      }
    }));
    _native.becknCall('on_search', _req('on_search', {
      'quote': {
        'carrier_id': driverId,
        'lane_commitment': '${pickup.name} -> ${drop.name}',
        'price_paise': q.fareRupees * 100,
        'collateral_paise': 0,
      }
    }));
    _native.becknCall('select', _req('select', {'carrier_id': driverId}));
    _native.becknCall('init', _req('init', {}));
    _native.becknCall('confirm', _req('confirm', {}));
    _native.becknCall('on_update', _req('on_update', {'state': 'DISPATCHED'}));
  }

  Future<void> _onSample(TelemetrySample s) async {
    if (_processing || !state.active) return;
    _processing = true;
    try {
      final att = _native.processTelemetry([s]);
      final along = (_sensor?.progressFraction ?? 0) * _totalM;
      final remaining = math.max(0.0, _totalM - along);
      final node = TelemetryNode(
        latitude: s.lat,
        longitude: s.lon,
        snappedLatitude: s.lat,
        snappedLongitude: s.lon,
        edgeIndex: 0,
        matchConfidence: 1,
        speedMps: att.filteredSpeedMps,
        headingDeg: s.headingDeg,
        tamper: att.tamper,
        tamperReason: att.reasonText,
        network: NetworkPath.fiveG,
        signatureValid: true,
        timestampNs: att.timestampNs,
      );

      if (!_boarded && along >= _leg1M - 25) {
        _boarded = true;
        _native.becknCall('on_update', _req('on_update', {'state': 'IN_TRANSIT'}, ts: s.timestampNs));
        final q = state.selectedQuote!;
        emit(state.copyWith(stage: RideStage.onTrip, activeRoute: q.route.polyline, message: 'Rider on board · OTP verified'));
      }

      var escrow = state.escrow;
      if (_boarded) {
        final valid = _native.verifyProof(att.publicKey, _txn, att.lat, att.lon, att.timestampNs, att.tamper, att.signature);
        final r = _native.becknCall('telemetry', {
          'context': {'transaction_id': _txn, 'timestamp_ns': s.timestampNs},
          'message': {'lat': s.lat, 'lon': s.lon, 'tamper': att.tamper, 'signature_valid': valid},
        });
        escrow = EscrowView.fromContract(r['message'] as Map<String, dynamic>);
      }
      final speed = math.max(att.filteredSpeedMps, 3.0);
      emit(state.copyWith(
        driver: node,
        proofs: state.proofs + 1,
        remainingM: _boarded ? remaining : math.max(0.0, _leg1M - along),
        etaS: (_boarded ? remaining : math.max(0.0, _leg1M - along)) / speed,
        escrow: escrow,
      ));
      if (escrow.state == 'SETTLED') {
        await _teardown();
        emit(state.copyWith(stage: RideStage.completed, message: 'Ride complete. Paid directly to the driver — no commission.'));
      } else if (escrow.state == 'DISPUTED') {
        await _teardown();
        emit(state.copyWith(stage: RideStage.disputed, message: 'The ride was flagged: ${node.tamperReason}. Fare is held in escrow.'));
      }
    } on DharaniException catch (e) {
      await _teardown();
      emit(state.copyWith(stage: RideStage.failed, error: e.message));
    } finally {
      _processing = false;
    }
  }

  // ------------------------------------------------------------ real drivers (server)
  void _requestRemote(RideQuote q, Place pickup, Place drop) {
    if (!session!.state.connected) {
      emit(state.copyWith(error: 'Not connected to the server. Check Wi-Fi and the server address in Account.'));
      return;
    }
    emit(state.copyWith(stage: RideStage.searching, clearError: true, message: 'Finding a nearby driver…', remoteId: 'pending'));
    session!.send({
      't': proto.T.rideRequest,
      'pickup': {'name': pickup.name, 'lat': pickup.lat, 'lon': pickup.lon},
      'drop': {'name': drop.name, 'lat': drop.lat, 'lon': drop.lon},
      'mode': q.mode.name == 'bike' ? 'bike' : q.mode.name,
      'fareRupees': q.fareRupees,
    });
  }

  void _onServer(proto.Json m) {
    switch (m['t']) {
      case proto.T.welcome:
        final r = m['ride'];
        if (r is Map<String, dynamic> && session?.state.role == proto.Role.rider) _applyRemote(RemoteRide.fromJson(r));
      case proto.T.rideUpdate:
        if (session?.state.role == proto.Role.rider) _applyRemote(RemoteRide.fromJson(m['ride'] as proto.Json));
      case proto.T.peerLocation:
        _onDriverLocation(m);
      case proto.T.error:
        if (state.remote) {
          final back = state.stage == RideStage.searching && state.remoteId == 'pending';
          emit(state.copyWith(error: friendlyError(m), stage: back ? RideStage.quoted : state.stage, clearRemote: back, clearMessage: back));
        }
    }
  }

  void _applyRemote(RemoteRide r) {
    final drv = r.driver;
    final lang = drv?.lang;
    switch (r.state) {
      case proto.RideState.requested:
        emit(state.copyWith(stage: RideStage.searching, remoteId: r.id, message: r.reason == null ? 'Finding a nearby driver…' : 'Finding another driver (${r.reason})…', clearDriver: true));
      case proto.RideState.assigned:
      case proto.RideState.arrived:
        emit(state.copyWith(
          stage: RideStage.toPickup,
          remoteId: r.id,
          driverLang: lang,
          driverName: drv?.name ?? '',
          vehicleNo: [drv?.plate, drv?.model].whereType<String>().where((e) => e.isNotEmpty).join(' · '),
          otp: r.otp ?? state.otp,
          message: r.state == proto.RideState.arrived ? 'Your driver has arrived. Share the OTP to start.' : null,
          clearMessage: r.state != proto.RideState.arrived,
        ));
      case proto.RideState.onTrip:
        final q = state.selectedQuote;
        emit(state.copyWith(stage: RideStage.onTrip, remoteId: r.id, driverLang: lang, activeRoute: q?.route.polyline, message: 'Trip started', otp: r.otp ?? state.otp));
      case proto.RideState.completed:
        emit(state.copyWith(stage: RideStage.completed, remoteId: r.id, message: 'Ride complete. Pay the driver directly — no commission.', clearDriver: true));
      case proto.RideState.cancelled:
        if (state.remote) emit(state.copyWith(stage: RideStage.quoted, clearRemote: true, clearDriver: true, error: 'Ride cancelled${r.reason == null ? '' : ': ${r.reason}'}', clearMessage: true));
      case proto.RideState.noDrivers:
        if (state.remote) emit(state.copyWith(stage: RideStage.quoted, clearRemote: true, clearDriver: true, error: 'No driver accepted. Try again, or pick another ride type.', clearMessage: true));
    }
  }

  void _onDriverLocation(proto.Json m) {
    if (!state.remote) return;
    final lat = (m['lat'] as num).toDouble(), lon = (m['lon'] as num).toDouble();
    final speed = (m['speed'] as num?)?.toDouble() ?? 0;
    final tamper = m['tamper'] == true;
    final target = state.stage == RideStage.onTrip ? state.drop : _effectivePickup();
    final remaining = target == null ? 0.0 : haversineMeters(lat, lon, target.lat, target.lon);
    emit(state.copyWith(
      driver: TelemetryNode(
        latitude: lat,
        longitude: lon,
        snappedLatitude: lat,
        snappedLongitude: lon,
        edgeIndex: 0,
        matchConfidence: 1,
        speedMps: speed,
        headingDeg: (m['heading'] as num?)?.toDouble() ?? 0,
        tamper: tamper,
        tamperReason: tamper ? 'mock location' : 'none',
        network: NetworkPath.fiveG,
        signatureValid: true,
        timestampNs: ((m['ts'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch) * 1000000,
      ),
      remainingM: remaining,
      etaS: remaining / (speed > 2 ? speed : 8),
    ));
  }

  Future<void> cancel() async {
    if (state.remote) {
      final id = state.remoteId;
      if (id != null && id != 'pending') session?.send({'t': proto.T.rideCancel, 'rideId': id});
      if (id == 'pending' || id == null) {
        emit(state.copyWith(stage: RideStage.quoted, clearRemote: true, clearDriver: true, clearMessage: true));
      }
      return;
    }
    await _teardown();
    emit(state.copyWith(stage: state.quotes.isEmpty ? RideStage.idle : RideStage.quoted, clearDriver: true, message: 'Ride cancelled.'));
    await _quote();
  }

  Future<void> reset() async {
    await _teardown();
    emit(const RideState());
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    await _sensor?.stop();
    _sensor = null;
    host.release(owner);
  }

  @override
  Future<void> close() async {
    await _remoteSub?.cancel();
    await _teardown();
    return super.close();
  }
}
