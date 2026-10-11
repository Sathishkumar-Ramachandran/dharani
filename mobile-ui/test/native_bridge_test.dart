// Integration test of the dart:ffi bindings against the real native library.
// Run: DHARANI_FFI_LIB=../build/ffi-bridge/libdharani_ffi.dylib flutter test
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dharani_mobile/core/native_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _req(String txn, int tsNs, Map<String, dynamic> msg) => {
      'context': {'transaction_id': txn, 'timestamp_ns': tsNs},
      'message': msg,
    };

void main() {
  final lib = Platform.environment['DHARANI_FFI_LIB'];
  final skip = (lib == null || !File(lib).existsSync()) ? 'set DHARANI_FFI_LIB to the built dharani_ffi library' : null;

  late DharaniNative native;
  late Directory dir;

  setUpAll(() {
    if (skip != null) return;
    dir = Directory.systemTemp.createTempSync('dharani_dart_');
    File('${dir.path}/road_graph.json').writeAsStringSync(File('assets/road_graph.json').readAsStringSync());
    native = DharaniNative.open(libraryPath: lib);
    native.initialize(dir.path, config: {'vehicle_id': 'dart-test-vehicle', 'mesh_port': 47997});
  });

  tearDownAll(() {
    if (skip != null) return;
    native.shutdown();
    dir.deleteSync(recursive: true);
  });

  test('identity and version', () {
    final id = native.identity();
    expect(id.vehicleId, 'dart-test-vehicle');
    expect(id.publicKey.length, 32);
    expect(native.version, startsWith('dharani-core'));
  }, skip: skip);

  test('route: truck height forces the bypass, impossible vehicle reports routing failure', () {
    final normal = native.calculateRoute(
        startLat: 12.9177, startLon: 77.6238, destLat: 12.5186, destLon: 78.2137, costing: 1, grossWeightKg: 18000, heightM: 3.2);
    final tall = native.calculateRoute(
        startLat: 12.9177, startLon: 77.6238, destLat: 12.5186, destLon: 78.2137, costing: 1, grossWeightKg: 18000, heightM: 4.2);
    expect(normal.distanceM, greaterThan(60000));
    expect(tall.distanceM, greaterThan(normal.distanceM));
    expect(normal.polyline.length, greaterThan(10));
    expect(normal.steps.last.instruction, contains('Arrive'));
    expect(normal.tollPlazas, greaterThanOrEqualTo(1));
    expect(
      () => native.calculateRoute(
          startLat: 12.9177, startLon: 77.6238, destLat: 12.5186, destLon: 78.2137, costing: 1, grossWeightKg: 25000, heightM: 4.2),
      throwsA(isA<DharaniException>().having((e) => e.code, 'code', DharaniCode.routingFailed)),
    );
  }, skip: skip);

  test('map matching returns edges and confidence', () {
    final r = native.mapMatch([
      (lat: 12.9177, lon: 77.6238, accuracyM: 8.0),
      (lat: 40.0, lon: 40.0, accuracyM: 8.0),
    ]);
    expect(r[0].matched, isTrue);
    expect(r[0].confidence, inInclusiveRange(0, 1));
    expect(r[1].matched, isFalse);
  }, skip: skip);

  test('telemetry is signed, verifiable, and a spoof is flagged', () {
    native.beginTrip('DART-TRIP');
    var t = 1700000000000000000;
    Attestation? last;
    for (var i = 0; i < 5; i++) {
      t += 1000000000;
      last = native.processTelemetry([
        TelemetrySample(timestampNs: t, lat: 12.9 + i * 0.00013, lon: 77.6, odometerTicks: i * 58, temperatureC: 4.0),
      ]);
    }
    expect(last!.tamper, isFalse);
    expect(last.digest.length, 32);
    expect(last.signature.length, 64);
    expect(native.verifyProof(last.publicKey, 'DART-TRIP', last.lat, last.lon, last.timestampNs, false, last.signature), isTrue);
    expect(native.verifyProof(last.publicKey, 'OTHER', last.lat, last.lon, last.timestampNs, false, last.signature), isFalse);
    final tampered = Uint8List.fromList(last.signature)..[3] ^= 1;
    expect(native.verifyProof(last.publicKey, 'DART-TRIP', last.lat, last.lon, last.timestampNs, false, tampered), isFalse);

    t += 1000000000;
    final spoof = native.processTelemetry([TelemetrySample(timestampNs: t, lat: 13.4, lon: 77.6, odometerTicks: 5 * 58)]);
    expect(spoof.tamper, isTrue);
    expect(spoof.reasonText, 'impossible speed');

    native.beginTrip('MOCK');
    t += 1000000000;
    final mock = native.processTelemetry([TelemetrySample(timestampNs: t, lat: 12.9, lon: 77.6, mockLocation: true)]);
    expect(mock.tamper, isTrue);
    expect(mock.reasonText, 'mock location provider');
    native.beginTrip('DART-TRIP');
  }, skip: skip);

  test('bad inputs surface as DharaniException, not crashes', () {
    expect(() => native.processTelemetry([TelemetrySample(timestampNs: 1, lat: 95, lon: 0)]),
        throwsA(isA<DharaniException>().having((e) => e.code, 'code', DharaniCode.invalidArgument)));
    expect(() => native.becknCall('nonsense', _req('x', 1, {})), throwsA(isA<DharaniException>()));
  }, skip: skip);

  test('beckn contract: large replies negotiate the buffer size', () {
    final big = <String, dynamic>{
      'rfq': {
        'consignor_id': 'c',
        'origin': {'name': 'a' * 30000, 'lat': 12.9, 'lon': 77.6},
        'destination': {'name': 'b', 'lat': 12.5, 'lon': 78.2, 'radius_m': 300},
        'cargo': {'volume_m3': 10, 'tonnage': 5},
        'delivery_deadline_epoch_s': 2000000000,
      }
    };
    final r = native.becknCall('search', _req('big-1', 1, big));
    expect((r['message'] as Map)['state'], 'DRAFT');
    expect(((r['message'] as Map)['rfq'] as Map)['origin']['name'].toString().length, 30000);
    // larger than the initial 64 KiB scratch buffer
    big['rfq']['origin']['name'] = 'a' * 70000;
    final r2 = native.becknCall('search', _req('big-2', 1, big));
    expect(((r2['message'] as Map)['rfq'] as Map)['origin']['name'].toString().length, 70000);
  }, skip: skip);

  test('mesh: hazards from another vehicle arrive on the Dart stream', () async {
    final sim = File('${File(lib!).parent.parent.path}/tools/dharani_peer_sim');
    if (!sim.existsSync()) {
      markTestSkipped('build target dharani_peer_sim first');
      return;
    }
    final events = native.startMesh();
    final got = Completer<MeshEvent>();
    final sub = events.listen((e) {
      if (e.type == 'hazard' && !got.isCompleted) got.complete(e);
    });
    final proc = await Process.start(sim.path, ['47997', 'blackice', '0.9', '12.8', '77.7', '5']);
    final ev = await got.future.timeout(const Duration(seconds: 8));
    expect(ev.hazard, 3);
    expect(ev.severity, closeTo(0.9, 1e-6));
    expect(ev.lat, closeTo(12.8, 1e-9));
    expect(ev.vehicleId, startsWith('peer-sim'));
    expect(native.peerCount(windowMs: 10000), greaterThanOrEqualTo(1));
    proc.kill();
    await sub.cancel();
    native.stopMesh();
  }, skip: skip);
}
