// dart:ffi bindings for ffi-bridge/dharani_c_api.h.
//
// Struct layouts mirror the C structs field for field; test/native_bridge_test.dart exercises
// them against the real library so a layout drift fails loudly.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ---- C status codes ----
class DharaniCode {
  static const ok = 0;
  static const invalidArgument = 1;
  static const notInitialized = 2;
  static const internalError = 3;
  static const notFound = 4;
  static const bufferTooSmall = 5;
  static const routingFailed = 6;
  static const protocolError = 7;
  static const ioError = 8;
}

class DharaniException implements Exception {
  DharaniException(this.code, this.message);
  final int code;
  final String message;
  @override
  String toString() => 'DharaniException($code): $message';
}

// ---- native struct mirrors ----
final class _Status extends Struct {
  @Int32()
  external int code;
  @Array(256)
  external Array<Uint8> diagnostic;
}

final class NativeTelemetrySample extends Struct {
  @Int64()
  external int timestampNs;
  @Double()
  external double lat;
  @Double()
  external double lon;
  @Double()
  external double altM;
  @Double()
  external double dop;
  @Double()
  external double speedMps;
  @Double()
  external double headingDeg;
  @Double()
  external double accuracyM;
  @Double()
  external double ax;
  @Double()
  external double ay;
  @Double()
  external double az;
  @Double()
  external double gx;
  @Double()
  external double gy;
  @Double()
  external double gz;
  @Uint64()
  external int odometerTicks;
  @Double()
  external double metersPerTick;
  @Double()
  external double temperatureC;
  @Uint32()
  external int engineRpm;
  @Uint32()
  external int obd2FaultCodes;
  @Float()
  external double fuelPct;
  @Float()
  external double batterySocPct;
  @Int32()
  external int mockLocation;
  @Int32()
  external int reserved;
}

final class NativeProof extends Struct {
  @Array(32)
  external Array<Uint8> digest;
  @Array(64)
  external Array<Uint8> signature;
  @Array(32)
  external Array<Uint8> publicKey;
  @Int32()
  external int tamperFlag;
  @Int32()
  external int tamperReason;
  @Int32()
  external int accepted;
  @Int32()
  external int reserved;
  @Double()
  external double filteredSpeedMps;
  @Double()
  external double lat;
  @Double()
  external double lon;
  @Int64()
  external int timestampNs;
}

final class NativeMatch extends Struct {
  @Int32()
  external int edgeIndex;
  @Int32()
  external int reserved;
  @Double()
  external double lat;
  @Double()
  external double lon;
  @Double()
  external double confidence;
}

// ---- value types returned to Dart ----
class TelemetrySample {
  const TelemetrySample({
    required this.timestampNs,
    required this.lat,
    required this.lon,
    this.altM = 0,
    this.dop = 1,
    this.speedMps = 0,
    this.headingDeg = 0,
    this.accuracyM = 5,
    this.ax = 0,
    this.ay = 0,
    this.az = 9.80665,
    this.gx = 0,
    this.gy = 0,
    this.gz = 0,
    this.odometerTicks = 0,
    this.metersPerTick = 0.25,
    this.temperatureC = double.nan,
    this.engineRpm = 0,
    this.obd2FaultCodes = 0,
    this.fuelPct = 0,
    this.batterySocPct = 0,
    this.mockLocation = false,
  });

  final int timestampNs;
  final double lat, lon, altM, dop, speedMps, headingDeg, accuracyM;
  final double ax, ay, az, gx, gy, gz;
  final int odometerTicks;
  final double metersPerTick;
  final double temperatureC;
  final int engineRpm, obd2FaultCodes;
  final double fuelPct, batterySocPct;
  final bool mockLocation;

  void writeTo(NativeTelemetrySample n) {
    n.timestampNs = timestampNs;
    n.lat = lat;
    n.lon = lon;
    n.altM = altM;
    n.dop = dop;
    n.speedMps = speedMps;
    n.headingDeg = headingDeg;
    n.accuracyM = accuracyM;
    n.ax = ax;
    n.ay = ay;
    n.az = az;
    n.gx = gx;
    n.gy = gy;
    n.gz = gz;
    n.odometerTicks = odometerTicks;
    n.metersPerTick = metersPerTick;
    n.temperatureC = temperatureC;
    n.engineRpm = engineRpm;
    n.obd2FaultCodes = obd2FaultCodes;
    n.fuelPct = fuelPct;
    n.batterySocPct = batterySocPct;
    n.mockLocation = mockLocation ? 1 : 0;
    n.reserved = 0;
  }
}

String _hex(Iterable<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class Attestation {
  const Attestation({
    required this.digest,
    required this.signature,
    required this.publicKey,
    required this.tamper,
    required this.tamperReason,
    required this.accepted,
    required this.filteredSpeedMps,
    required this.lat,
    required this.lon,
    required this.timestampNs,
  });

  final Uint8List digest, signature, publicKey;
  final bool tamper;
  final int tamperReason;
  final bool accepted;
  final double filteredSpeedMps, lat, lon;
  final int timestampNs;

  String get digestHex => _hex(digest);
  String get signatureHex => _hex(signature);
  String get publicKeyHex => _hex(publicKey);

  static const _reasons = [
    'none',
    'impossible speed',
    'dead-reckoning mismatch',
    'odometer mismatch',
    'IMU inconsistent',
    'clock regression',
    'mock location provider',
  ];
  String get reasonText => tamperReason >= 0 && tamperReason < _reasons.length ? _reasons[tamperReason] : 'unknown';
}

class RouteStep {
  const RouteStep(this.instruction, this.distanceM, this.lat, this.lon);
  final String instruction;
  final double distanceM, lat, lon;
}

class TollPlaza {
  const TollPlaza(this.edge, this.name, this.lat, this.lon);
  final int edge;
  final String name;
  final double lat, lon;
}

class RouteResult {
  const RouteResult({
    required this.distanceM,
    required this.durationS,
    required this.carbonGrams,
    required this.tollPlazas,
    required this.polyline,
    required this.edges,
    required this.steps,
    this.tolls = const [],
  });

  final List<TollPlaza> tolls;
  final double distanceM, durationS, carbonGrams;
  final int tollPlazas;
  final List<({double lat, double lon})> polyline;
  final List<int> edges;
  final List<RouteStep> steps;

  factory RouteResult.fromJson(Map<String, dynamic> j) => RouteResult(
        distanceM: (j['distance_m'] as num).toDouble(),
        durationS: (j['duration_s'] as num).toDouble(),
        carbonGrams: (j['carbon_grams'] as num).toDouble(),
        tollPlazas: (j['toll_plazas'] as num).toInt(),
        polyline: [
          for (final p in j['polyline'] as List) (lat: (p[0] as num).toDouble(), lon: (p[1] as num).toDouble())
        ],
        edges: [for (final e in j['edges'] as List) (e as num).toInt()],
        tolls: [
          for (final t in (j['tolls'] as List? ?? const []))
            TollPlaza((t['edge'] as num).toInt(), t['name'] as String, (t['lat'] as num).toDouble(), (t['lon'] as num).toDouble())
        ],
        steps: [
          for (final s in j['steps'] as List)
            RouteStep(s['instruction'] as String, (s['distance_m'] as num).toDouble(), (s['lat'] as num).toDouble(),
                (s['lon'] as num).toDouble())
        ],
      );
}

class MatchResult {
  const MatchResult(this.edgeIndex, this.lat, this.lon, this.confidence);
  final int edgeIndex;
  final double lat, lon, confidence;
  bool get matched => edgeIndex >= 0;
}

class MeshEvent {
  const MeshEvent({
    required this.type,
    required this.vehicleId,
    required this.lat,
    required this.lon,
    required this.hazard,
    required this.severity,
    required this.tamper,
    required this.speed,
  });

  final String type, vehicleId;
  final double lat, lon, severity, speed;
  final int hazard;
  final bool tamper;

  factory MeshEvent.fromJson(Map<String, dynamic> j) => MeshEvent(
        type: j['type'] as String,
        vehicleId: j['vehicle_id'] as String,
        lat: (j['lat'] as num).toDouble(),
        lon: (j['lon'] as num).toDouble(),
        hazard: (j['hazard'] as num).toInt(),
        severity: (j['severity'] as num).toDouble(),
        tamper: j['tamper'] as bool? ?? false,
        speed: (j['speed'] as num?)?.toDouble() ?? 0,
      );
}

// ---- native memory helper ----
// A native buffer freed by a NativeFinalizer when the Dart object is collected.
final _bufferFinalizer = NativeFinalizer(malloc.nativeFree);

class _ScratchBuffer implements Finalizable {
  _ScratchBuffer(int capacity) : _capacity = capacity, _ptr = malloc<Uint8>(capacity) {
    _bufferFinalizer.attach(this, _ptr.cast(), detach: this);
  }
  int _capacity;
  Pointer<Uint8> _ptr;

  Pointer<Utf8> get chars => _ptr.cast();
  int get capacity => _capacity;

  void grow(int capacity) {
    _bufferFinalizer.detach(this);
    malloc.free(_ptr);
    _capacity = capacity;
    _ptr = malloc<Uint8>(capacity);
    _bufferFinalizer.attach(this, _ptr.cast(), detach: this);
  }

  String read(int length) => utf8.decode(_ptr.asTypedList(length));
}

// ---- function signatures ----
typedef _StatusFn0 = _Status Function();
typedef _EventCallbackNative = Void Function(Pointer<Utf8>, Pointer<Void>);

class DharaniNative implements Finalizable {
  DharaniNative._(this._lib) {
    _guardFinalizer = NativeFinalizer(_lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('dharani_engine_guard_release'));
    _freeString = _lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('dharani_string_free');
  }

  static DharaniNative? _instance;

  /// Opens the library for the current platform. `libraryPath` overrides it (host tests).
  static DharaniNative open({String? libraryPath}) {
    return _instance ??= DharaniNative._(DynamicLibrary.open(libraryPath ?? _defaultLibrary()));
  }

  static String _defaultLibrary() {
    final override = Platform.environment['DHARANI_FFI_LIB'];
    if (override != null && override.isNotEmpty) return override;
    if (Platform.isAndroid) return 'libdharani_ffi.so';
    if (Platform.isIOS) return 'dharani_ffi.framework/dharani_ffi';
    if (Platform.isMacOS) return 'libdharani_ffi.dylib';
    if (Platform.isLinux) return 'libdharani_ffi.so';
    throw UnsupportedError('Unsupported platform ${Platform.operatingSystem}');
  }

  final DynamicLibrary _lib;
  late final NativeFinalizer _guardFinalizer;
  late final void Function(Pointer<Utf8>) _freeString;
  Pointer<Void>? _guard;
  final _scratch = _ScratchBuffer(64 * 1024);
  NativeCallable<_EventCallbackNative>? _meshCallback;
  StreamController<MeshEvent>? _meshEvents;

  late final _version = _lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('dharani_version');
  late final _init = _lib.lookupFunction<_Status Function(Pointer<Utf8>, Pointer<Utf8>),
      _Status Function(Pointer<Utf8>, Pointer<Utf8>)>('dharani_engine_init');
  late final _shutdown = _lib.lookupFunction<_StatusFn0, _StatusFn0>('dharani_engine_shutdown');
  late final _guardCreate =
      _lib.lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>('dharani_engine_guard_create');
  late final _identity = _lib.lookupFunction<_Status Function(Pointer<Utf8>, Uint32, Pointer<Uint8>),
      _Status Function(Pointer<Utf8>, int, Pointer<Uint8>)>('dharani_get_identity');
  late final _verify = _lib.lookupFunction<
      _Status Function(Pointer<Uint8>, Pointer<Utf8>, Double, Double, Int64, Int32, Pointer<Uint8>, Pointer<Int32>),
      _Status Function(Pointer<Uint8>, Pointer<Utf8>, double, double, int, int, Pointer<Uint8>,
          Pointer<Int32>)>('dharani_verify_proof');
  late final _loadGraph = _lib
      .lookupFunction<_Status Function(Pointer<Utf8>), _Status Function(Pointer<Utf8>)>('dharani_load_graph');
  late final _route = _lib.lookupFunction<
      _Status Function(Double, Double, Double, Double, Int32, Double, Double, Double, Int32, Pointer<Utf8>, Uint32,
          Pointer<Uint32>),
      _Status Function(double, double, double, double, int, double, double, double, int, Pointer<Utf8>, int,
          Pointer<Uint32>)>('dharani_calculate_route');
  late final _mapMatch = _lib.lookupFunction<_Status Function(Pointer<Double>, Uint32, Pointer<NativeMatch>),
      _Status Function(Pointer<Double>, int, Pointer<NativeMatch>)>('dharani_map_match');
  late final _beginTrip = _lib
      .lookupFunction<_Status Function(Pointer<Utf8>), _Status Function(Pointer<Utf8>)>('dharani_begin_trip');
  late final _batch = _lib.lookupFunction<
      _Status Function(Pointer<NativeTelemetrySample>, Uint32, Pointer<NativeProof>),
      _Status Function(Pointer<NativeTelemetrySample>, int, Pointer<NativeProof>)>('dharani_process_telemetry_batch');
  late final _registerCallback = _lib.lookupFunction<
      _Status Function(Pointer<NativeFunction<_EventCallbackNative>>, Pointer<Void>),
      _Status Function(Pointer<NativeFunction<_EventCallbackNative>>, Pointer<Void>)>(
      'dharani_register_mesh_event_callback');
  late final _meshStart = _lib.lookupFunction<_StatusFn0, _StatusFn0>('dharani_mesh_start');
  late final _meshStop = _lib.lookupFunction<_StatusFn0, _StatusFn0>('dharani_mesh_stop');
  late final _publishHazard = _lib.lookupFunction<_Status Function(Int32, Float, Double, Double),
      _Status Function(int, double, double, double)>('dharani_mesh_publish_hazard');
  late final _peerCount = _lib.lookupFunction<_Status Function(Uint32, Pointer<Uint32>),
      _Status Function(int, Pointer<Uint32>)>('dharani_mesh_peer_count');
  late final _beckn = _lib.lookupFunction<
      _Status Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Uint32, Pointer<Uint32>),
      _Status Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, Pointer<Uint32>)>('dharani_beckn_call');

  late final _takePending = _lib.lookupFunction<_Status Function(Pointer<Utf8>, Uint32, Pointer<Uint32>),
      _Status Function(Pointer<Utf8>, int, Pointer<Uint32>)>('dharani_beckn_take_pending_reply');

  static String _message(_Status s) {
    final bytes = <int>[];
    for (var i = 0; i < 256; i++) {
      final b = s.diagnostic[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static void _check(_Status s) {
    if (s.code != DharaniCode.ok) throw DharaniException(s.code, _message(s));
  }

  String get version => _version().toDartString();

  /// Initialises the engine. `storagePath` must be app-private; it holds the device key and the
  /// road graph (`road_graph.json`).
  void initialize(String storagePath, {Map<String, Object?> config = const {}}) {
    final p = storagePath.toNativeUtf8();
    final c = jsonEncode(config).toNativeUtf8();
    try {
      _check(_init(p, c));
    } finally {
      malloc.free(p);
      malloc.free(c);
    }
    // The guard shuts the engine down if this object is garbage collected without shutdown().
    if (_guard == null) {
      _guard = _guardCreate();
      _guardFinalizer.attach(this, _guard!, detach: this);
    }
  }

  void shutdown() {
    stopMeshListening();
    _check(_shutdown());
    final g = _guard;
    if (g != null) {
      _guardFinalizer.detach(this);
      // Release the token only (the engine is already stopped, a second shutdown is a no-op).
      _lib.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
          'dharani_engine_guard_release')(g);
      _guard = null;
    }
  }

  ({String vehicleId, Uint8List publicKey}) identity() {
    final id = malloc<Uint8>(64);
    final pk = malloc<Uint8>(32);
    try {
      _check(_identity(id.cast(), 64, pk));
      return (vehicleId: id.cast<Utf8>().toDartString(), publicKey: Uint8List.fromList(pk.asTypedList(32)));
    } finally {
      malloc.free(id);
      malloc.free(pk);
    }
  }

  bool verifyProof(Uint8List publicKey, String tripId, double lat, double lon, int timestampNs, bool tamper,
      Uint8List signature) {
    final pk = malloc<Uint8>(32)..asTypedList(32).setAll(0, publicKey);
    final sig = malloc<Uint8>(64)..asTypedList(64).setAll(0, signature);
    final trip = tripId.toNativeUtf8();
    final out = malloc<Int32>();
    try {
      _check(_verify(pk, trip, lat, lon, timestampNs, tamper ? 1 : 0, sig, out));
      return out.value == 1;
    } finally {
      malloc.free(pk);
      malloc.free(sig);
      malloc.free(trip);
      malloc.free(out);
    }
  }

  /// Swaps the road network for the graph file at `path`; the old graph stays on failure.
  void loadGraph(String path) {
    final p = path.toNativeUtf8();
    try {
      _check(_loadGraph(p));
    } finally {
      malloc.free(p);
    }
  }

  RouteResult calculateRoute({
    required double startLat,
    required double startLon,
    required double destLat,
    required double destLon,
    int costing = 0,
    double grossWeightKg = 0,
    double axleLoadKg = 0,
    double heightM = 0,
    int hourOfDay = -1,
  }) {
    final len = malloc<Uint32>();
    try {
      for (var attempt = 0; attempt < 2; attempt++) {
        final st = _route(startLat, startLon, destLat, destLon, costing, grossWeightKg, axleLoadKg, heightM, hourOfDay,
            _scratch.chars, _scratch.capacity, len);
        if (st.code == DharaniCode.bufferTooSmall && attempt == 0) {
          _scratch.grow(len.value + 1);
          continue;
        }
        _check(st);
        return RouteResult.fromJson(jsonDecode(_scratch.read(len.value)) as Map<String, dynamic>);
      }
      throw DharaniException(DharaniCode.internalError, 'route buffer negotiation failed');
    } finally {
      malloc.free(len);
    }
  }

  List<MatchResult> mapMatch(List<({double lat, double lon, double accuracyM})> trace) {
    if (trace.isEmpty) return const [];
    final triples = malloc<Double>(trace.length * 3);
    final out = calloc<NativeMatch>(trace.length);
    try {
      for (var i = 0; i < trace.length; i++) {
        triples[3 * i] = trace[i].lat;
        triples[3 * i + 1] = trace[i].lon;
        triples[3 * i + 2] = trace[i].accuracyM;
      }
      _check(_mapMatch(triples, trace.length, out));
      return [for (var i = 0; i < trace.length; i++) MatchResult(out[i].edgeIndex, out[i].lat, out[i].lon, out[i].confidence)];
    } finally {
      malloc.free(triples);
      calloc.free(out);
    }
  }

  void beginTrip(String tripId) {
    final t = tripId.toNativeUtf8();
    try {
      _check(_beginTrip(t));
    } finally {
      malloc.free(t);
    }
  }

  /// Feeds samples (oldest first) and returns the signed proof for the last one.
  Attestation processTelemetry(List<TelemetrySample> samples) {
    if (samples.isEmpty) throw ArgumentError('samples must not be empty');
    final native = calloc<NativeTelemetrySample>(samples.length);
    final proof = calloc<NativeProof>();
    try {
      for (var i = 0; i < samples.length; i++) {
        samples[i].writeTo(native[i]);
      }
      _check(_batch(native, samples.length, proof));
      final p = proof.ref;
      return Attestation(
        digest: Uint8List.fromList([for (var i = 0; i < 32; i++) p.digest[i]]),
        signature: Uint8List.fromList([for (var i = 0; i < 64; i++) p.signature[i]]),
        publicKey: Uint8List.fromList([for (var i = 0; i < 32; i++) p.publicKey[i]]),
        tamper: p.tamperFlag != 0,
        tamperReason: p.tamperReason,
        accepted: p.accepted != 0,
        filteredSpeedMps: p.filteredSpeedMps,
        lat: p.lat,
        lon: p.lon,
        timestampNs: p.timestampNs,
      );
    } finally {
      calloc.free(native);
      calloc.free(proof);
    }
  }

  // ---- mesh ----
  /// Starts the sidelink and returns the stream of peer / hazard events. The native callback may
  /// fire on any thread; NativeCallable.listener marshals it to this isolate without blocking.
  Stream<MeshEvent> startMesh() {
    stopMeshListening();
    final controller = StreamController<MeshEvent>.broadcast();
    _meshEvents = controller;
    final callable = NativeCallable<_EventCallbackNative>.listener((Pointer<Utf8> json, Pointer<Void> _) {
      try {
        if (!controller.isClosed) {
          controller.add(MeshEvent.fromJson(jsonDecode(json.toDartString()) as Map<String, dynamic>));
        }
      } finally {
        _freeString(json);
      }
    });
    _meshCallback = callable;
    _check(_registerCallback(callable.nativeFunction, nullptr));
    try {
      _check(_meshStart());
    } catch (_) {
      stopMeshListening();
      rethrow;
    }
    return controller.stream;
  }

  void stopMesh() {
    _check(_meshStop());
    stopMeshListening();
  }

  void stopMeshListening() {
    final cb = _meshCallback;
    if (cb != null) {
      // Unregister first so no new events are posted, then close the callable.
      _registerCallback(nullptr.cast(), nullptr);
      cb.close();
      _meshCallback = null;
    }
    _meshEvents?.close();
    _meshEvents = null;
  }

  void publishHazard(int hazard, double severity, double lat, double lon) =>
      _check(_publishHazard(hazard, severity, lat, lon));

  int peerCount({int windowMs = 10000}) {
    final out = malloc<Uint32>();
    try {
      _check(_peerCount(windowMs, out));
      return out.value;
    } finally {
      malloc.free(out);
    }
  }

  // ---- Beckn ----
  Map<String, dynamic> becknCall(String action, Map<String, dynamic> request) {
    final a = action.toNativeUtf8();
    final r = jsonEncode(request).toNativeUtf8();
    final len = malloc<Uint32>();
    try {
      var st = _beckn(a, r, _scratch.chars, _scratch.capacity, len);
      if (st.code == DharaniCode.bufferTooSmall) {
        // The action already took effect natively; fetch the parked reply instead of replaying it.
        _scratch.grow(len.value + 1);
        st = _takePending(_scratch.chars, _scratch.capacity, len);
      }
      _check(st);
      return jsonDecode(_scratch.read(len.value)) as Map<String, dynamic>;
    } finally {
      malloc.free(a);
      malloc.free(r);
      malloc.free(len);
    }
  }
}
