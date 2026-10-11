// End-to-end orchestration tests: real native engine + fast simulated vehicle.
// Run: DHARANI_FFI_LIB=../build/ffi-bridge/libdharani_ffi.dylib flutter test
import 'dart:io';

import 'package:dharani_mobile/main.dart';
import 'package:dharani_mobile/models/hazard.dart';
import 'package:dharani_mobile/models/trip_manifest.dart';
import 'package:dharani_mobile/services/engine_host.dart';
import 'package:dharani_mobile/services/sensor_source.dart';
import 'package:dharani_mobile/net/dharani_client.dart';
import 'package:dharani_mobile/state/call_cubit.dart';
import 'package:dharani_mobile/state/conversation_cubit.dart';
import 'package:dharani_mobile/state/driver_cubit.dart';
import 'package:dharani_mobile/state/location_cubit.dart';
import 'package:dharani_mobile/state/session_cubit.dart';
import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:dharani_mobile/state/mesh_monitor_cubit.dart';
import 'package:dharani_mobile/state/region_cubit.dart';
import 'package:dharani_mobile/state/ride_cubit.dart';
import 'package:dharani_mobile/state/translate_cubit.dart';
import 'package:dharani_mobile/state/trip_state_notifier.dart';
import 'package:dharani_mobile/translate/model_manager.dart';
import 'package:dharani_mobile/translate/npu_asr.dart';
import 'package:dharani_mobile/translate/pipeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const silkBoard = Place('Silk Board', 12.9177, 77.6238);
const hosur = Place('Hosur', 12.7409, 77.8253);
const attibele = Place('Attibele', 12.7790, 77.7700);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_map's tile cache asks path_provider for a directory; point it at the temp dir.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/path_provider'),
    (call) async => Directory.systemTemp.path,
  );
  final lib = Platform.environment['DHARANI_FFI_LIB'];
  final skip = (lib == null || !File(lib).existsSync()) ? 'set DHARANI_FFI_LIB to the built dharani_ffi library' : null;

  late Directory dir;
  late EngineHost host;
  late MeshMonitorCubit mesh;
  late LocationCubit location;
  late TripStateNotifier notifier;

  Future<void> boot() async {
    dir = Directory.systemTemp.createTempSync('dharani_flow_');
    host = EngineHost(storageOverride: dir.path);
    await host.init();
    await host.installDemoGraph(); // synthetic corridor: deterministic roads for tests
    mesh = MeshMonitorCubit();
    location = LocationCubit();
    notifier = TripStateNotifier(
      host: host,
      mesh: mesh,
      location: location,
      sensorFactory: (cfg, route) => SimulatedSensorSource(
        polyline: route.polyline,
        timeScale: cfg.timeScale,
        tickInterval: const Duration(milliseconds: 4),
      ),
    );
    await notifier.bootstrap();
    expect(notifier.state.phase, TripPhase.ready, reason: notifier.state.error);
  }

  Future<TripState> until(bool Function(TripState) test) =>
      notifier.stream.firstWhere(test).timeout(const Duration(seconds: 40));

  Future<void> shutdown() async {
    await notifier.close();
    await mesh.close();
    await location.close();
    host.shutdown();
    dir.deleteSync(recursive: true);
  }

  TripConfig config({bool cold = false, VehicleClass v = VehicleClass.truck, double height = 3.2}) => TripConfig(
        origin: silkBoard,
        destination: hosur,
        vehicle: v,
        heightM: height,
        coldChain: cold,
        timeScale: 20,
      );

  test('honest haul: contract settles on signed geofence entry', () async {
    await boot();
    notifier.updateConfig(config());
    await notifier.startTrip();
    expect(notifier.state.phase, TripPhase.running, reason: notifier.state.error);
    expect(notifier.state.escrow.state, 'IN_TRANSIT');
    expect(notifier.state.escrow.funded, isTrue);

    final done = await until((s) => s.phase == TripPhase.completed || s.phase == TripPhase.failed);
    expect(done.phase, TripPhase.completed, reason: done.error);
    expect(done.escrow.state, 'SETTLED', reason: 'tamper=${done.telemetry!.tamperReason} samples=${done.samples}');
    expect(done.escrow.paidToCarrierPaise, 5000000);
    expect(done.escrow.returnedCollateralPaise, 1000000);
    expect(done.telemetry!.tamper, isFalse);
    expect(done.proofChecksPassed, done.samples);
    expect(done.samples, greaterThan(10));
    expect(done.telemetry!.onRoad, isTrue);
    expect(done.auditChainValid, isTrue);
    expect(done.audit.map((a) => a.event), containsAllInOrder(['search', 'on_search', 'select', 'init', 'confirm', 'geofence_verified', 'settle']));
    expect(host.activeOwner, isNull, reason: 'engine must be released after the trip');
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  test('GPS spoofing jump raises the tamper flag and disputes the contract', () async {
    await boot();
    notifier.updateConfig(config());
    await notifier.startTrip();
    await until((s) => s.samples >= 5);
    notifier.injectGpsJump(5000);
    final done = await until((s) => s.phase == TripPhase.completed || s.phase == TripPhase.failed);
    expect(done.escrow.state, 'DISPUTED');
    expect(done.escrow.locked, isTrue);
    expect(done.escrow.arbitrationPending, isTrue);
    expect(done.escrow.paidToCarrierPaise, 0);
    expect(done.telemetry!.tamperReason, 'impossible speed');
    expect(done.audit.last.event, 'dispute');
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  test('frozen wheel sensor (mock-GPS rig) is caught by the odometer cross-check', () async {
    await boot();
    notifier.updateConfig(config());
    await notifier.startTrip();
    await until((s) => s.samples >= 5);
    notifier.setFreezeWheels(true);
    final done = await until((s) => s.phase == TripPhase.completed || s.phase == TripPhase.failed);
    expect(done.escrow.state, 'DISPUTED');
    expect(done.telemetry!.tamperReason, 'odometer mismatch');
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  test('cold chain: more than 15 minutes outside the SLA band disputes', () async {
    await boot();
    notifier.updateConfig(config(cold: true));
    await notifier.startTrip();
    await until((s) => s.samples >= 3);
    notifier.setReeferTemp(14);
    final done = await until((s) => s.phase == TripPhase.completed || s.phase == TripPhase.failed);
    expect(done.escrow.state, 'DISPUTED', reason: done.error);
    expect(done.escrow.excursionSeconds, greaterThan(15 * 60));
    expect(done.telemetry!.tamper, isFalse, reason: 'dispute must come from the SLA, not tamper');
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  test('hazard near the route is stored and triggers a re-plan', () async {
    await boot();
    notifier.updateConfig(config());
    await notifier.startTrip();
    await until((s) => s.samples >= 4);
    notifier.reportHazard(HazardKind.congestion, severity: 1.0);
    expect(notifier.state.hazards.single.fromPeer, isFalse);
    expect(notifier.state.rerouteNotice, isNotNull);
    await notifier.stopTrip();
    expect(notifier.state.phase, TripPhase.ready);
    expect(host.activeOwner, isNull);
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 60)));

  test('validation: missing destination, illegal vehicle, other session active', () async {
    await boot();
    notifier.updateConfig(const TripConfig(origin: silkBoard));
    await notifier.startTrip();
    expect(notifier.state.error, contains('destination'));

    notifier.updateConfig(config(height: 4.2).copyWith(grossWeightKg: 25000));
    await notifier.startTrip();
    expect(notifier.state.phase, TripPhase.ready);
    expect(notifier.state.error, contains('No legal route'));

    expect(host.claim('ride'), isTrue);
    notifier.updateConfig(config());
    await notifier.startTrip();
    expect(notifier.state.error, contains('ride is in progress'));
    host.release('ride');
    await shutdown();
  }, skip: skip);

  test('B2C ride is robust across driver start positions', () async {
    await boot();
    for (var seed = 0; seed < 25; seed++) {
      final ride = RideCubit(host: host, location: location, timeScale: 20, seed: seed, tickInterval: const Duration(milliseconds: 2), matchDelay: Duration.zero);
      await ride.setPickup(silkBoard);
      await ride.setDrop(attibele);
      await ride.requestRide();
      final done = await ride.stream
          .firstWhere((s) => s.stage == RideStage.completed || s.stage == RideStage.disputed || s.stage == RideStage.failed)
          .timeout(const Duration(seconds: 30));
      expect(done.stage, RideStage.completed, reason: 'seed $seed: ${done.error} ${done.message} ${done.driver?.tamperReason}');
      await ride.close();
    }
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 120)));

  test('B2C ride: quote, book, driver arrives, trip settles with zero commission', () async {
    await boot();
    final ride = RideCubit(host: host, location: location, timeScale: 20, tickInterval: const Duration(milliseconds: 4), matchDelay: const Duration(milliseconds: 20));
    await ride.setPickup(silkBoard);
    await ride.setDrop(attibele);
    expect(ride.state.stage, RideStage.quoted, reason: ride.state.error);
    // Bike taxis are barred from the elevated expressway on this lane, so only auto and cab are offered.
    expect(ride.state.quotes.map((q) => q.mode), [RideMode.auto, RideMode.cab]);
    final auto = ride.state.quotes[0].fareRupees, cab = ride.state.quotes[1].fareRupees;
    expect(auto, greaterThan(100));
    expect(cab, greaterThan(auto), reason: 'cab costs more than auto');
    ride.selectMode(RideMode.cab);
    await ride.requestRide();
    expect(ride.state.stage, isIn([RideStage.toPickup, RideStage.onTrip]), reason: ride.state.error);
    expect(ride.state.otp.length, 4);
    final done = await ride.stream.firstWhere((s) => s.stage == RideStage.completed || s.stage == RideStage.disputed || s.stage == RideStage.failed).timeout(const Duration(seconds: 60));
    expect(done.stage, RideStage.completed, reason: '${done.error} ${done.message} drv=${done.driver?.tamperReason}');
    expect(done.escrow.paidToCarrierPaise, cab * 100);
    expect(done.proofs, greaterThan(5));
    expect(host.activeOwner, isNull);
    await ride.close();
    await shutdown();
  }, skip: skip, timeout: const Timeout(Duration(seconds: 90)));

  testWidgets('UI: tabs, planner, and a haul started from the Freight tab', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late AppDependencies deps;
    await tester.runAsync(() async {
      await boot();
      final session = SessionCubit();
      await session.configure(profile: const Profile(role: proto.Role.rider, name: 'Tester', lang: 'en'), serverUrl: '', demo: true);
      final translate = TranslateCubit(pipeline: OnDevicePipeline(), models: ModelManager(rootDir: dir.path), npu: NpuAsr());
      final ride = RideCubit(host: host, location: location, session: session);
      deps = AppDependencies(
        session: session,
        driver: DriverCubit(session: session, location: location, host: host),
        conversation: ConversationCubit(session: session, translate: translate),
        call: CallCubit(session: session, audio: FakeCallAudio(), ensureMic: () async => true),
        host: host,
        mesh: mesh,
        location: location,
        region: RegionCubit(host),
        trip: notifier,
        ride: ride,
        translate: translate,
      );
      notifier.updateConfig(config());
    });
    await tester.pumpWidget(DharaniApp(dependencies: Future.value(deps)));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }

    expect(find.text('Where to?'), findsOneWidget); // B2C is the first tab for a rider
    await tester.tap(find.text('Freight'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('New freight haul'), findsOneWidget);
    expect(find.text('Create contract & start'), findsOneWidget);

    await tester.tap(find.text('Translate'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Talk across languages'), findsOneWidget);
    await tester.tap(find.text('Account'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Offline roads'), findsOneWidget);

    await tester.runAsync(() async {
      await notifier.stopTrip();
    });
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async => shutdown());
  }, skip: skip != null);

  testWidgets('first launch shows onboarding; a driver profile gets the Drive tab and cannot go online while disconnected', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    late AppDependencies deps;
    await tester.runAsync(() async {
      await boot();
      final session = SessionCubit();
      final translate = TranslateCubit(pipeline: OnDevicePipeline(), models: ModelManager(rootDir: dir.path), npu: NpuAsr());
      deps = AppDependencies(
        session: session,
        driver: DriverCubit(session: session, location: location, host: host),
        conversation: ConversationCubit(session: session, translate: translate),
        call: CallCubit(session: session, audio: FakeCallAudio(), ensureMic: () async => true),
        host: host,
        mesh: mesh,
        location: location,
        region: RegionCubit(host),
        trip: notifier,
        ride: RideCubit(host: host, location: location, session: session),
        translate: translate,
      );
      await session.load();
    });
    await tester.pumpWidget(DharaniApp(dependencies: Future.value(deps)));
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Welcome to Dharani'), findsOneWidget);
    expect(find.text('Registration number'), findsNothing);
    await tester.tap(find.text('I drive'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Registration number'), findsOneWidget);
    await tester.runAsync(() async {
      await deps.session.configure(
        profile: const Profile(role: proto.Role.driver, name: 'Murugan', lang: 'ta', vehicle: (type: proto.VehicleType.cab, plate: 'KA01AB1234', model: '')),
        serverUrl: 'http://127.0.0.1:1',
      );
    });
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(find.text('Drive'), findsWidgets);
    expect(find.text('Freight'), findsOneWidget, reason: 'drivers (carriers) keep the B2B Freight tab');
    expect(find.text('You are offline'), findsOneWidget);
    // (the test binding answers every HTTP call with 400, so the connection error shown is the refusal)
    expect(find.textContaining('Server refused registration'), findsWidgets);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Go online')).onPressed, isNull, reason: 'cannot go online without a connection');
    await tester.runAsync(() async => shutdown());
    await tester.pumpWidget(const SizedBox());
  }, skip: skip != null);
}
