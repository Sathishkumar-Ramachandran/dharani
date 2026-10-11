import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/native_bridge.dart';
import '../core/secure_storage.dart';
import '../models/hazard.dart';
import '../core/geo.dart';
import '../services/engine_host.dart';
import 'location_cubit.dart';
import '../models/telemetry_node.dart';
import '../models/trip_manifest.dart';
import '../services/sensor_source.dart';
import 'mesh_monitor_cubit.dart';

enum TripPhase { booting, ready, starting, running, completed, failed }

class EscrowView {
  const EscrowView({
    this.state = 'DRAFT',
    this.funded = false,
    this.locked = false,
    this.freightHeldPaise = 0,
    this.collateralHeldPaise = 0,
    this.paidToCarrierPaise = 0,
    this.refundedPaise = 0,
    this.returnedCollateralPaise = 0,
    this.arbitrationPending = false,
    this.excursionSeconds = 0,
    this.decision = '',
  });

  final String state;
  final bool funded, locked, arbitrationPending;
  final int freightHeldPaise, collateralHeldPaise, paidToCarrierPaise, refundedPaise, returnedCollateralPaise;
  final double excursionSeconds;
  final String decision;

  factory EscrowView.fromContract(Map<String, dynamic> message) {
    final e = (message['escrow'] as Map<String, dynamic>?) ?? const {};
    int i(String k) => (e[k] as num?)?.toInt() ?? 0;
    return EscrowView(
      state: message['state'] as String? ?? 'DRAFT',
      funded: e['funded'] as bool? ?? false,
      locked: e['locked'] as bool? ?? false,
      freightHeldPaise: i('freight_held_paise'),
      collateralHeldPaise: i('collateral_held_paise'),
      paidToCarrierPaise: i('paid_to_carrier_paise'),
      refundedPaise: i('refunded_to_consignor_paise'),
      returnedCollateralPaise: i('returned_collateral_paise'),
      arbitrationPending: message['arbitration_pending'] as bool? ?? false,
      excursionSeconds: (message['temperature_excursion_s'] as num?)?.toDouble() ?? 0,
      decision: ((message['decision'] as Map<String, dynamic>?)?['reason'] as String?) ?? '',
    );
  }
}

class AuditLine {
  const AuditLine(this.event, this.detail, this.hash, this.prevHash, this.timestampNs);
  final String event, detail, hash, prevHash;
  final int timestampNs;
}

class TollEvent {
  const TollEvent({required this.plaza, required this.at, required this.amountRupees, required this.receiptHash});
  final String plaza;
  final DateTime at;
  final int amountRupees;
  final String receiptHash;
}

class TripState {
  const TripState({
    this.phase = TripPhase.booting,
    this.config,
    this.manifest,
    this.route,
    this.telemetry,
    this.attestation,
    this.escrow = const EscrowView(),
    this.audit = const [],
    this.auditChainValid = true,
    this.hazards = const [],
    this.tolls = const [],
    this.vehicleId = '',
    this.publicKeyHex = '',
    this.nativeVersion = '',
    this.message,
    this.error,
    this.samples = 0,
    this.remainingM = 0,
    this.reeferTempC = 5,
    this.rerouteNotice,
    this.freezeWheels = false,
    this.proofChecksPassed = 0,
  });

  final TripPhase phase;
  final TripConfig? config;
  final TripManifest? manifest;
  final RouteResult? route;
  final TelemetryNode? telemetry;
  final Attestation? attestation;
  final EscrowView escrow;
  final List<AuditLine> audit;
  final bool auditChainValid;
  final List<RoadHazard> hazards;
  final List<TollEvent> tolls;
  final String vehicleId, publicKeyHex, nativeVersion;
  final String? message, error, rerouteNotice;
  final int samples;
  final double remainingM;
  final double reeferTempC;
  final bool freezeWheels;
  final int proofChecksPassed;

  bool get sensorHealthy => telemetry == null || !telemetry!.tamper;
  bool get running => phase == TripPhase.running;
  int get expectedTolls => route?.tollPlazas ?? 0;

  TripState copyWith({
    TripPhase? phase,
    TripConfig? config,
    TripManifest? manifest,
    RouteResult? route,
    TelemetryNode? telemetry,
    Attestation? attestation,
    EscrowView? escrow,
    List<AuditLine>? audit,
    bool? auditChainValid,
    List<RoadHazard>? hazards,
    List<TollEvent>? tolls,
    String? vehicleId,
    String? publicKeyHex,
    String? nativeVersion,
    String? message,
    String? error,
    int? samples,
    double? remainingM,
    double? reeferTempC,
    String? rerouteNotice,
    bool? freezeWheels,
    int? proofChecksPassed,
    bool clearError = false,
    bool clearMessage = false,
    bool clearTrip = false,
  }) =>
      TripState(
        phase: phase ?? this.phase,
        config: config ?? this.config,
        manifest: clearTrip ? null : (manifest ?? this.manifest),
        route: clearTrip ? null : (route ?? this.route),
        telemetry: clearTrip ? null : (telemetry ?? this.telemetry),
        attestation: clearTrip ? null : (attestation ?? this.attestation),
        escrow: clearTrip ? const EscrowView() : (escrow ?? this.escrow),
        audit: clearTrip ? const [] : (audit ?? this.audit),
        auditChainValid: auditChainValid ?? this.auditChainValid,
        hazards: clearTrip ? const [] : (hazards ?? this.hazards),
        tolls: clearTrip ? const [] : (tolls ?? this.tolls),
        vehicleId: vehicleId ?? this.vehicleId,
        publicKeyHex: publicKeyHex ?? this.publicKeyHex,
        nativeVersion: nativeVersion ?? this.nativeVersion,
        message: clearMessage ? null : (message ?? this.message),
        error: clearError ? null : (error ?? this.error),
        samples: clearTrip ? 0 : (samples ?? this.samples),
        remainingM: remainingM ?? this.remainingM,
        reeferTempC: reeferTempC ?? this.reeferTempC,
        rerouteNotice: clearTrip ? null : (rerouteNotice ?? this.rerouteNotice),
        freezeWheels: freezeWheels ?? this.freezeWheels,
        proofChecksPassed: clearTrip ? 0 : (proofChecksPassed ?? this.proofChecksPassed),
      );
}

/// Orchestrates the whole haul: native engine, sensors, Beckn contract, mesh and connectivity.
class TripStateNotifier extends Cubit<TripState> {
  TripStateNotifier({
    required this.host,
    required this.mesh,
    required this.location,
    SecureStore? store,
    SensorSource Function(TripConfig, RouteResult)? sensorFactory,
  })  : _sensorFactory = sensorFactory,
        _store = store ?? SecureStore(),
        super(const TripState());

  static const owner = 'freight';

  final EngineHost host;
  final MeshMonitorCubit mesh;
  final LocationCubit location;
  final SecureStore _store;
  final SensorSource Function(TripConfig, RouteResult)? _sensorFactory;

  DharaniNative get _native => host.native;
  SensorSource? _sensor;
  StreamSubscription<TelemetrySample>? _sampleSub;
  StreamSubscription<MeshEvent>? _meshSub;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _peerTimer;
  bool _booted = false;
  bool _processing = false;
  final List<({double lat, double lon, double accuracyM})> _trace = [];
  final Set<int> _tollEdges = {};
  int _lastTollEdge = -1;
  String _lastContractState = '';
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);

  // ------------------------------------------------------------------ boot
  Future<void> bootstrap() async {
    if (_booted) return;
    _booted = true;
    try {
      if (!host.ready) await host.init();
      emit(state.copyWith(
        vehicleId: host.vehicleId,
        publicKeyHex: host.publicKeyHex,
        nativeVersion: host.version,
        config: const TripConfig(),
        phase: TripPhase.ready,
        clearError: true,
      ));
      await _startMesh();
      await _watchConnectivity();
    } catch (e) {
      emit(state.copyWith(phase: TripPhase.failed, error: 'Engine failed to start: $e'));
    }
  }

  Future<void> _startMesh() async {
    try {
      final stream = _native.startMesh();
      _meshSub = stream.listen(_onMeshEvent);
      mesh.setMeshRunning(true);
      _peerTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        try {
          mesh.setPeers(_native.peerCount(windowMs: 10000));
        } catch (_) {}
      });
    } catch (e) {
      mesh.setMeshRunning(false, error: '$e');
    }
  }

  Future<void> _watchConnectivity() async {
    void apply(List<ConnectivityResult> r) =>
        mesh.setUplink(r.any((c) => c != ConnectivityResult.none && c != ConnectivityResult.bluetooth));
    try {
      apply(await Connectivity().checkConnectivity());
      _connSub = Connectivity().onConnectivityChanged.listen(apply);
    } catch (_) {
      mesh.setUplink(false);
    }
  }

  // ------------------------------------------------------------------ config
  void updateConfig(TripConfig config) => emit(state.copyWith(config: config));

  void setSimulatedOutage(bool value) => mesh.setOutageSimulated(value);

  // ------------------------------------------------------------------ trip
  Future<void> startTrip() async {
    final cfg = state.config;
    if (cfg == null || state.phase == TripPhase.starting || state.running) return;
    final fix = location.state.fix;
    final origin = cfg.origin ?? (fix == null ? null : Place('My location', fix.lat, fix.lon));
    final dest = cfg.destination;
    if (origin == null) {
      emit(state.copyWith(error: 'Pick a starting point, or enable GPS to start from your location.'));
      return;
    }
    if (dest == null) {
      emit(state.copyWith(error: 'Choose a destination: search, or long-press the map.'));
      return;
    }
    if (haversineMeters(origin.lat, origin.lon, dest.lat, dest.lon) < 300) {
      emit(state.copyWith(error: 'Origin and destination are too close together.'));
      return;
    }
    if (!host.claim(owner)) {
      emit(state.copyWith(error: 'A ride is in progress. Finish it before starting a haul.'));
      return;
    }
    emit(state.copyWith(phase: TripPhase.starting, clearTrip: true, clearError: true, clearMessage: true));
    try {
      final route = _native.calculateRoute(
        startLat: origin.lat,
        startLon: origin.lon,
        destLat: dest.lat,
        destLon: dest.lon,
        costing: cfg.costing,
        grossWeightKg: cfg.vehicle == VehicleClass.truck ? cfg.grossWeightKg : 0,
        axleLoadKg: cfg.vehicle == VehicleClass.truck ? cfg.axleLoadKg : 0,
        heightM: cfg.vehicle == VehicleClass.truck ? cfg.heightM : 0,
      );

      final nowNs = DateTime.now().microsecondsSinceEpoch * 1000;
      final nowS = nowNs ~/ 1000000000;
      final deadline = nowS + (route.durationS * 1.5).round() + 3600;
      final stamp = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final tripId = 'DH-${stamp.year}${two(stamp.month)}${two(stamp.day)}-${two(stamp.hour)}${two(stamp.minute)}${two(stamp.second)}';
      final manifest = TripManifest(
        id: tripId,
        ewayBill: (nowS % 1000000000000).toString().padLeft(12, '0'),
        vehicleId: state.vehicleId,
        origin: origin,
        destination: dest,
        temperatureLimitC: cfg.maxTempC,
        coldChain: cfg.coldChain,
        tonnage: cfg.tonnage,
        volumeM3: cfg.volumeM3,
        deadlineEpochS: deadline,
      );

      _native.beginTrip(tripId);
      final escrow = _openContract(manifest, cfg, nowNs);

      _lastTollEdge = -1;
      _tollEdges
        ..clear()
        ..addAll(route.tolls.map((t) => t.edge));
      _trace.clear();
      _lastContractState = escrow.state;
      emit(state.copyWith(
        manifest: manifest,
        route: route,
        escrow: escrow,
        remainingM: route.distanceM,
        reeferTempC: cfg.coldChain ? (cfg.minTempC + cfg.maxTempC) / 2 : 5,
        message: 'Contract ${manifest.id} confirmed, escrow funded. Dispatching…',
      ));
      await _store.write('last_trip', jsonEncode({'id': tripId, 'from': origin.name, 'to': dest.name}));

      _sensor = _sensorFactory?.call(cfg, route) ??
          (cfg.simulated
              ? SimulatedSensorSource(polyline: route.polyline, timeScale: cfg.timeScale)
              : DeviceSensorSource());
      _sensor!.reeferTempC = state.reeferTempC;
      await _sensor!.start();
      _sampleSub = _sensor!.samples.listen(_onSample, onError: (Object e) {
        _failTrip('Sensor error: $e');
      });
      _processing = false;
      emit(state.copyWith(phase: TripPhase.running));
    } on DharaniException catch (e) {
      await _teardownSensors();
      emit(state.copyWith(phase: TripPhase.ready, error: _friendly(e)));
    } catch (e) {
      await _teardownSensors();
      emit(state.copyWith(phase: TripPhase.ready, error: '$e'));
    }
  }

  String _friendly(DharaniException e) => switch (e.code) {
        DharaniCode.routingFailed => 'No legal route: ${e.message}',
        DharaniCode.notFound => 'No offline roads installed yet. Open Account → Offline roads and download your area.',
        _ => e.message,
      };

  /// Runs the Beckn search -> on_search -> select -> init -> confirm -> on_update sequence.
  EscrowView _openContract(TripManifest m, TripConfig cfg, int nowNs) {
    int clock = nowNs;
    Map<String, dynamic> req(Map<String, dynamic> message) => {
          'context': {
            'transaction_id': m.id,
            'message_id': 'msg-${clock++}',
            'bap_id': 'consignor.dharani.local',
            'bpp_id': 'carrier.${state.vehicleId}',
            'timestamp_ns': clock,
          },
          'message': message,
        };
    Map<String, dynamic> place(Place p, double radius) => {'name': p.name, 'lat': p.lat, 'lon': p.lon, 'radius_m': radius};
    _native.becknCall('search', req({
      'rfq': {
        'transaction_id': m.id,
        'consignor_id': 'consignor-demo-001',
        'origin': place(m.origin, 250),
        'destination': place(m.destination, 300),
        'cargo': {
          'volume_m3': cfg.volumeM3,
          'tonnage': cfg.tonnage,
          'temperature_controlled': cfg.coldChain,
          'min_temp_c': cfg.minTempC,
          'max_temp_c': cfg.maxTempC,
        },
        'delivery_deadline_epoch_s': m.deadlineEpochS,
      }
    }));
    _native.becknCall('on_search', req({
      'quote': {
        'carrier_id': state.vehicleId,
        'lane_commitment': '${m.origin.name} -> ${m.destination.name}',
        'price_paise': cfg.pricePaise,
        'collateral_paise': cfg.collateralPaise,
      }
    }));
    _native.becknCall('select', req({'carrier_id': state.vehicleId}));
    _native.becknCall('init', req({}));
    _native.becknCall('confirm', req({}));
    _native.becknCall('on_update', req({'state': 'DISPATCHED'}));
    final r = _native.becknCall('on_update', req({'state': 'IN_TRANSIT'}));
    return EscrowView.fromContract(r['message'] as Map<String, dynamic>);
  }

  Map<String, dynamic> _telemetryRequest(String txn, TelemetrySample s, Attestation a, bool signatureValid) => {
        'context': {
          'transaction_id': txn,
          'message_id': 'tel-${s.timestampNs}',
          'bap_id': 'consignor.dharani.local',
          'bpp_id': 'carrier.${state.vehicleId}',
          'timestamp_ns': s.timestampNs,
        },
        'message': {
          'lat': s.lat,
          'lon': s.lon,
          'tamper': a.tamper,
          'signature_valid': signatureValid,
          if (!s.temperatureC.isNaN) 'temperature_c': s.temperatureC,
        },
      };

  Future<void> _onSample(TelemetrySample raw) async {
    final m = state.manifest;
    if (m == null || !state.running || _processing) return;
    _processing = true;
    try {
      final sample = raw;
      final att = _native.processTelemetry([sample]);
      // The receiving edge node re-verifies the signed payload independently of the signer.
      final valid = _native.verifyProof(att.publicKey, m.id, att.lat, att.lon, att.timestampNs, att.tamper, att.signature);

      _trace.add((lat: sample.lat, lon: sample.lon, accuracyM: sample.accuracyM));
      if (_trace.length > 8) _trace.removeAt(0);
      final matches = _native.mapMatch(_trace);
      final mt = matches.last;

      final uplinkPath = mesh.state.path;
      mesh.onProof();

      final result = _native.becknCall('telemetry', _telemetryRequest(m.id, sample, att, valid));
      final message = result['message'] as Map<String, dynamic>;
      final escrow = EscrowView.fromContract(message);

      final node = TelemetryNode(
        latitude: sample.lat,
        longitude: sample.lon,
        snappedLatitude: mt.matched ? mt.lat : sample.lat,
        snappedLongitude: mt.matched ? mt.lon : sample.lon,
        edgeIndex: mt.edgeIndex,
        matchConfidence: mt.confidence,
        speedMps: att.filteredSpeedMps,
        headingDeg: sample.headingDeg,
        tamper: att.tamper,
        tamperReason: att.reasonText,
        network: uplinkPath,
        signatureValid: valid,
        timestampNs: att.timestampNs,
        temperatureC: sample.temperatureC.isNaN ? null : sample.temperatureC,
      );

      var tolls = state.tolls;
      if (mt.matched && mt.edgeIndex != _lastTollEdge) {
        if (_tollEdges.contains(mt.edgeIndex)) {
          final plaza = state.route?.tolls.firstWhere((t) => t.edge == mt.edgeIndex);
          // Receipt hash binds the toll event to the signed position digest.
          tolls = [
            ...tolls,
            TollEvent(
              plaza: (plaza == null || plaza.name.isEmpty) ? 'Toll plaza' : '${plaza.name} toll plaza',
              at: DateTime.fromMicrosecondsSinceEpoch(att.timestampNs ~/ 1000),
              amountRupees: state.config?.vehicle == VehicleClass.truck ? 345 : 95,
              receiptHash: att.digestHex.substring(0, 16),
            )
          ];
        }
        _lastTollEdge = mt.edgeIndex;
      }

      final dest = m.destination;
      emit(state.copyWith(
        telemetry: node,
        attestation: att,
        escrow: escrow,
        tolls: tolls,
        samples: state.samples + 1,
        remainingM: haversineMeters(sample.lat, sample.lon, dest.lat, dest.lon),
        proofChecksPassed: state.proofChecksPassed + (valid ? 1 : 0),
      ));

      if (escrow.state != _lastContractState) {
        _lastContractState = escrow.state;
        _refreshAudit(m.id);
      }
      if (escrow.state == 'SETTLED' || escrow.state == 'DISPUTED') {
        await _finishTrip(escrow.state);
      }
    } on DharaniException catch (e) {
      await _failTrip(e.message);
    } catch (e) {
      await _failTrip('$e');
    } finally {
      _processing = false;
    }
  }

  void _refreshAudit(String txn) {
    try {
      final r = _native.becknCall('audit', {
        'context': {'transaction_id': txn, 'timestamp_ns': DateTime.now().microsecondsSinceEpoch * 1000},
        'message': {}
      });
      final msg = r['message'] as Map<String, dynamic>;
      final lines = <AuditLine>[
        for (final e in msg['log'] as List)
          AuditLine(e['event'] as String, e['detail'] as String, e['hash'] as String, e['prev_hash'] as String,
              (e['timestamp_ns'] as num).toInt())
      ];
      var prev = '0' * 64;
      var ok = true;
      for (final l in lines) {
        if (l.prevHash != prev) ok = false;
        prev = l.hash;
      }
      emit(state.copyWith(audit: lines, auditChainValid: ok && prev == msg['head_hash']));
    } catch (_) {}
  }

  Future<void> _finishTrip(String finalState) async {
    await _teardownSensors();
    final m = state.manifest;
    if (m != null) _refreshAudit(m.id);
    emit(state.copyWith(
      phase: TripPhase.completed,
      message: finalState == 'SETTLED'
          ? 'Delivery verified by a signed geofence entry. Escrow released.'
          : 'Dispute raised. Escrow locked and the audit log routed to the arbitration node.',
    ));
  }

  Future<void> _failTrip(String error) async {
    await _teardownSensors();
    emit(state.copyWith(phase: TripPhase.failed, error: error));
  }

  Future<void> stopTrip() async {
    await _teardownSensors();
    emit(state.copyWith(phase: TripPhase.ready, message: 'Trip stopped.'));
  }

  Future<void> resetAfterTrip() async {
    emit(state.copyWith(phase: TripPhase.ready, clearTrip: true, clearError: true, clearMessage: true));
  }

  Future<void> _teardownSensors() async {
    await _sampleSub?.cancel();
    _sampleSub = null;
    await _sensor?.stop();
    _sensor = null;
    host.release(owner);
  }

  // ------------------------------------------------------------------ operator controls
  void setReeferTemp(double c) {
    _sensor?.reeferTempC = c;
    emit(state.copyWith(reeferTempC: c));
  }

  /// Demo: GNSS suddenly reports a position `meters` ahead (a spoofing device).
  void injectGpsJump([double meters = 5000]) {
    final s = _sensor;
    if (s is SimulatedSensorSource) s.injectTeleport(meters);
  }

  void setFreezeWheels(bool v) {
    final s = _sensor;
    if (s is SimulatedSensorSource) s.freezeWheels = v;
    emit(state.copyWith(freezeWheels: v));
  }

  /// Broadcast a hazard seen by this vehicle to the swarm and feed it into routing.
  void reportHazard(HazardKind kind, {double severity = 0.8}) {
    final t = state.telemetry;
    final m = state.manifest;
    if (t == null || m == null) {
      emit(state.copyWith(error: 'Start a trip before reporting hazards.'));
      return;
    }
    try {
      _native.publishHazard(kind.index, severity, t.snappedLatitude, t.snappedLongitude);
    } on DharaniException catch (e) {
      emit(state.copyWith(error: e.message));
      return;
    }
    _addHazard(RoadHazard(
        kind: kind, lat: t.snappedLatitude, lon: t.snappedLongitude, severity: severity, fromPeer: false, at: DateTime.now()));
    _maybeReroute('${kind.label} reported by this vehicle');
  }

  void _addHazard(RoadHazard h) {
    final list = [...state.hazards, h];
    if (list.length > 64) list.removeAt(0);
    emit(state.copyWith(hazards: list));
  }

  void _onMeshEvent(MeshEvent e) {
    if (e.type != 'hazard') return;
    if (e.hazard < 1 || e.hazard >= HazardKind.values.length) return;
    final kind = HazardKind.values[e.hazard];
    _addHazard(RoadHazard(
      kind: kind,
      lat: e.lat,
      lon: e.lon,
      severity: e.severity,
      fromPeer: true,
      at: DateTime.now(),
      reporter: e.vehicleId,
    ));
    _maybeReroute('${kind.label} reported by ${e.vehicleId}');
  }

  /// Re-plans from the current position when a hazard sits close to the active route.
  void _maybeReroute(String reason) {
    final route = state.route, t = state.telemetry, cfg = state.config, m = state.manifest;
    if (route == null || t == null || cfg == null || m == null || !state.running) return;
    if (DateTime.now().difference(_lastReroute) < const Duration(seconds: 5)) return;
    final h = state.hazards.last;
    final near = route.polyline.any((p) => haversineMeters(p.lat, p.lon, h.lat, h.lon) < 1200);
    if (!near) return;
    _lastReroute = DateTime.now();
    try {
      final fresh = _native.calculateRoute(
        startLat: t.snappedLatitude,
        startLon: t.snappedLongitude,
        destLat: m.destination.lat,
        destLon: m.destination.lon,
        costing: cfg.costing,
        grossWeightKg: cfg.vehicle == VehicleClass.truck ? cfg.grossWeightKg : 0,
        axleLoadKg: cfg.vehicle == VehicleClass.truck ? cfg.axleLoadKg : 0,
        heightM: cfg.vehicle == VehicleClass.truck ? cfg.heightM : 0,
      );
      final delta = fresh.durationS - route.durationS;
      emit(state.copyWith(
        route: fresh,
        rerouteNotice: '$reason. Re-planned: ${(fresh.distanceM / 1000).toStringAsFixed(1)} km, '
            '${delta >= 0 ? '+' : ''}${(delta / 60).toStringAsFixed(0)} min vs. previous plan.',
      ));
    } catch (_) {
      // Keep the current plan if no alternative exists.
    }
  }

  @override
  Future<void> close() async {
    await _teardownSensors();
    await _meshSub?.cancel();
    await _connSub?.cancel();
    _peerTimer?.cancel();
    if (_booted && host.ready) {
      try {
        _native.stopMesh();
      } catch (_) {}
    }
    return super.close();
  }
}
