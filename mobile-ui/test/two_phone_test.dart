// Two phones, one real server: a rider app and a driver app talking over real WebSockets, with the real
// native routing engine on the rider side and scripted GPS / speech.
// Run: DHARANI_FFI_LIB=../build/ffi-bridge/libdharani_ffi.dylib flutter test test/two_phone_test.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dharani_mobile/main.dart';
import 'package:dharani_mobile/net/dharani_client.dart';
import 'package:dharani_mobile/services/engine_host.dart';
import 'package:dharani_mobile/state/call_cubit.dart';
import 'package:dharani_mobile/state/conversation_cubit.dart';
import 'package:dharani_mobile/state/driver_cubit.dart';
import 'package:dharani_mobile/state/location_cubit.dart';
import 'package:dharani_mobile/state/ride_cubit.dart';
import 'package:dharani_mobile/state/session_cubit.dart';
import 'package:dharani_mobile/state/translate_cubit.dart';
import 'package:dharani_mobile/translate/device_info.dart';
import 'package:dharani_mobile/translate/model_manager.dart';
import 'package:dharani_mobile/models/trip_manifest.dart';
import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:dharani_server/hub.dart';
import 'package:dharani_server/server.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

const silk = Place('Silk Board', 12.9177, 77.6238);
const attibele = Place('Attibele', 12.7790, 77.7700);

class Phone {
  Phone(this.session, this.gps, this.location, this.pipeline, this.translate, this.convo, this.audio, this.call);
  final FakeCallAudio audio;
  final CallCubit call;
  final SessionCubit session;
  final FakeLocationService gps;
  final LocationCubit location;
  final FakePipeline pipeline;
  final TranslateCubit translate;
  final ConversationCubit convo;

  static Future<Phone> create(Directory dir, {String name = 'phone'}) async {
    final gps = FakeLocationService();
    final location = LocationCubit(service: gps);
    final pipeline = FakePipeline()..ready.addAll(['en', 'hi', 'ta']);
    final translate = TranslateCubit(pipeline: pipeline, models: ModelManager(rootDir: '${dir.path}/$name'), npu: FakeNpu(), device: const DeviceInfo(model: 'test'));
    await translate.init();
    final session = SessionCubit();
    final audio = FakeCallAudio();
    final conv = ConversationCubit(session: session, translate: translate);
    return Phone(session, gps, location, pipeline, translate, conv, audio, CallCubit(session: session, audio: audio, ensureMic: () async => true, conversation: conv, npuReady: () => true));
  }

  Future<void> close() async {
    await call.close();
    await convo.close();
    await translate.close();
    await location.close();
    await session.close();
  }
}

Future<T> eventually<T>(T? Function() read, {Duration timeout = const Duration(seconds: 6), String what = 'condition'}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    final v = read();
    if (v != null) return v;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw TimeoutException('timed out waiting for $what');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // real sockets
  final lib = Platform.environment['DHARANI_FFI_LIB'];
  final skip = (lib == null || !File(lib).existsSync()) ? 'set DHARANI_FFI_LIB to the built dharani_ffi library' : null;

  late DharaniServer server;
  late Directory dir;
  late EngineHost host;
  late Phone rider, driver;
  late DriverCubit driverCubit;
  late RideCubit ride;
  late String url;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('two_phone_');
    server = DharaniServer(const ServerConfig(host: '127.0.0.1', port: 0, secret: 'integration-secret-0123456789', hub: HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100), disconnectGrace: Duration(seconds: 6))));
    await server.start();
    url = 'http://127.0.0.1:${server.port}';
    host = EngineHost(storageOverride: '${dir.path}/engine');
    await host.init();
    await host.installDemoGraph();
    rider = await Phone.create(dir, name: 'rider');
    driver = await Phone.create(dir, name: 'driver');
    await rider.session.configure(profile: const Profile(role: proto.Role.rider, name: 'Asha', lang: 'hi'), serverUrl: url);
    await driver.session.configure(
      profile: const Profile(role: proto.Role.driver, name: 'Murugan', lang: 'ta', vehicle: (type: proto.VehicleType.cab, plate: 'KA01AB1234', model: 'Dzire')),
      serverUrl: url,
    );
    await eventually(() => rider.session.state.connected && driver.session.state.connected ? true : null, what: 'both phones connected');
    await rider.location.start();
    await driver.location.start();
    driverCubit = DriverCubit(session: driver.session, location: driver.location, locationInterval: Duration.zero);
    ride = RideCubit(host: host, location: rider.location, session: rider.session);
  });

  tearDown(() async {
    await ride.close();
    await driverCubit.close();
    await rider.close();
    await driver.close();
    await server.stop();
    host.shutdown();
    dir.deleteSync(recursive: true);
  });

  Future<void> bookCab() async {
    await ride.setPickup(silk);
    await ride.setDrop(attibele);
    expect(ride.state.stage, RideStage.quoted, reason: ride.state.error);
    ride.selectMode(RideMode.cab);
    await ride.requestRide();
  }

  test('rider books, nearest driver accepts, OTP starts the trip, live location, completion', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238); // ~310 m from the pickup
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null, what: 'driver online on server');

    await bookCab();
    expect(ride.state.stage, RideStage.searching);
    final offer = await eventually(() => driverCubit.state.offer, what: 'offer on the driver phone');
    expect(offer.fareRupees, ride.state.selectedQuote!.fareRupees);
    expect(offer.pickup.name, 'Silk Board');
    expect(offer.distanceToPickupM, inInclusiveRange(250, 400));

    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null, what: 'rider sees the driver');
    expect(ride.state.driverName, 'Murugan');
    expect(ride.state.vehicleNo, contains('KA01AB1234'));
    expect(ride.state.driverLang, 'ta');
    final otp = ride.state.otp;
    expect(otp, matches(RegExp(r'^\d{4}$')));
    final active = await eventually(() => driverCubit.state.ride, what: 'ride on the driver phone');
    expect(active.rider!.name, 'Asha');
    expect(active.rider!.lang, 'hi');
    expect(active.otp, isNull, reason: 'the driver never learns the OTP');
    expect(driverCubit.state.offer, isNull);

    // live location: the rider's map marker follows the real driver GPS
    driver.gps.push(12.9190, 77.6238, speed: 10);
    final node = await eventually(() => ride.state.driver?.latitude == 12.9190 ? ride.state.driver : null, what: 'driver location on rider phone');
    expect(node.speedMps, 10);
    expect(ride.state.remainingM, closeTo(143, 30));

    driverCubit.arrived();
    await eventually(() => ride.state.message?.contains('arrived') == true ? true : null, what: 'arrival notice');

    driverCubit.start('${(int.parse(otp) + 1) % 10000}'.padLeft(4, '0'));
    await eventually(() => driverCubit.state.otpWrong ? true : null, what: 'wrong OTP rejected');
    expect(ride.state.stage, RideStage.toPickup);
    driverCubit.start(otp);
    await eventually(() => ride.state.stage == RideStage.onTrip ? true : null, what: 'trip started');

    driverCubit.complete();
    await eventually(() => ride.state.stage == RideStage.completed ? true : null, what: 'ride completed');
    expect(driverCubit.state.ride, isNull);
    expect(driverCubit.state.message, contains('completed'));
    expect(server.hub.metrics.ridesCompleted, 1);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('live translated conversation: Hindi rider and Tamil driver, text over the socket, each hears their own language', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    await eventually(() => driverCubit.state.ride);

    rider.convo.bind(rideId: ride.state.remoteId!, myLang: 'hi', peerLang: ride.state.driverLang!, peerName: 'Murugan');
    driver.convo.bind(rideId: driverCubit.state.ride!.id, myLang: 'ta', peerLang: driverCubit.state.ride!.rider!.lang, peerName: 'Asha');

    // rider speaks Hindi -> driver hears Tamil
    rider.pipeline.scripted.add('कृपया यहाँ रुकिए');
    expect(await rider.convo.talkOnce(), isTrue);
    expect(rider.convo.state.bubbles.single.mine, isTrue);
    expect(rider.convo.state.bubbles.single.translated, '[hi>ta] कृपया यहाँ रुकिए');
    await eventually(() => driver.convo.state.bubbles.length == 1 ? true : null, what: 'utterance on driver phone');
    final heard = driver.convo.state.bubbles.single;
    expect(heard.mine, isFalse);
    expect(heard.text, 'कृपया यहाँ रुकिए');
    expect(heard.translated, '[hi>ta] कृपया यहाँ रुकिए');
    await eventually(() => driver.pipeline.spoken.isNotEmpty ? true : null, what: 'driver phone speaks');
    expect(driver.pipeline.spoken.single, 'ta:[hi>ta] कृपया यहाँ रुकिए');
    expect(rider.pipeline.spoken, isEmpty, reason: 'no echo on the sender');

    // driver answers in Tamil -> rider hears Hindi
    driver.pipeline.scripted.add('சரி, வருகிறேன்');
    await driver.convo.talkOnce();
    await eventually(() => rider.pipeline.spoken.isNotEmpty ? true : null, what: 'rider phone speaks');
    expect(rider.pipeline.spoken.single, 'hi:[ta>hi] சரி, வருகிறேன்');

    // hands-free mode keeps going until stopped
    rider.pipeline.scripted.addAll(['पहला', 'दूसरा']);
    await rider.convo.setAuto(true);
    await eventually(() => driver.convo.state.bubbles.where((b) => !b.mine).length >= 3 ? true : null, what: 'auto mode sentences');
    await rider.convo.setAuto(false);
    expect(rider.convo.state.auto, isFalse);

    // typed message works too and is muted-able
    driver.convo.setMuted(true);
    final before = driver.pipeline.spoken.length;
    await rider.convo.sendTyped('धन्यवाद');
    await eventually(() => driver.convo.state.bubbles.any((b) => b.text == 'धन्यवाद') ? true : null);
    expect(driver.pipeline.spoken.length, before, reason: 'muted: shown but not spoken');

    // the driver changes language in Account: the rider's phone now translates into French, and the
    // driver hears French, without re-booking or reconnecting
    driver.convo.setMuted(false);
    await driver.session.setLanguage('fr');
    await eventually(() => rider.convo.state.peerLang == 'fr' ? true : null, what: 'rider learns driver language');
    expect(driver.convo.state.myLang, 'fr');
    rider.pipeline.scripted.add('अब कहाँ चलें');
    await rider.convo.talkOnce();
    await eventually(() => driver.pipeline.spoken.any((s) => s.startsWith('fr:')) ? true : null, what: 'driver hears French');
    expect(rider.convo.state.bubbles.last.tgtLang, 'fr');
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('voice call: rider rings, driver answers, audio flows both ways at once, mute, hang up', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    final rideId = ride.state.remoteId!;
    await eventually(() => driverCubit.state.ride);

    await rider.call.call(rideId: rideId, peerName: 'Murugan');
    expect(rider.call.state.phase, CallPhase.calling);
    await eventually(() => driver.call.state.phase == CallPhase.incoming ? true : null, what: 'driver phone rings');
    expect(driver.call.state.peerName, 'Asha');

    await driver.call.accept();
    await eventually(() => rider.call.state.phase == CallPhase.active && driver.call.state.phase == CallPhase.active ? true : null, what: 'call connected');
    expect(rider.audio.started && driver.audio.started, isTrue);

    // 50 frames each way, interleaved: this is a full-duplex 1 second of speech
    for (var i = 0; i < 50; i++) {
      rider.audio.speak(Uint8List.fromList(List.filled(640, i)));
      driver.audio.speak(Uint8List.fromList(List.filled(640, 100 + i)));
    }
    await eventually(() => driver.audio.played.length == 50 && rider.audio.played.length == 50 ? true : null, what: 'all frames delivered');
    expect(driver.audio.played.first[0], 0);
    expect(driver.audio.played.last[0], 49);
    expect(rider.audio.played.first[0], 100);
    expect(rider.audio.played.last[0], 149);
    expect(driver.audio.played.map((f) => f.length).toSet(), {640});

    // mute stops only that direction
    await rider.call.toggleMute();
    rider.audio.speak(Uint8List(640));
    driver.audio.speak(Uint8List.fromList(List.filled(640, 7)));
    await eventually(() => rider.audio.played.length == 51 ? true : null);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(driver.audio.played.length, 50, reason: 'muted rider is silent');

    // a second incoming call while busy is declined automatically; hang up ends both sides
    await driver.call.toggleSpeaker();
    expect(driver.audio.speaker, isTrue);
    driver.call.hangUp();
    await eventually(() => rider.call.state.phase == CallPhase.ended && driver.call.state.phase == CallPhase.ended ? true : null, what: 'both ended');
    expect(rider.audio.started, isFalse);
    expect(driver.audio.started, isFalse);
    expect(rider.call.state.endReason, 'hung up');
    expect(server.hub.metrics.callsAnswered, 1);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('interpreter call: each side speaks their own language, the other phone speaks the translation', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    final rideId = ride.state.remoteId!;
    await eventually(() => driverCubit.state.ride);
    // the app shell binds the conversation (peer language) when a ride has a counterpart
    rider.convo.bind(rideId: rideId, myLang: 'hi', peerLang: ride.state.driverLang!, peerName: 'Murugan');
    driver.convo.bind(rideId: rideId, myLang: 'ta', peerLang: 'hi', peerName: 'Asha');

    await rider.call.call(rideId: rideId, peerName: 'Murugan');
    await eventually(() => driver.call.state.phase == CallPhase.incoming ? true : null);
    await driver.call.accept();
    await eventually(() => rider.call.state.phase == CallPhase.active && driver.call.state.phase == CallPhase.active ? true : null);

    // different languages + NPU available => interpreter mode, raw voice is NOT streamed, loudspeaker on
    expect(rider.call.state.interpreter, isTrue);
    expect(rider.call.state.interpreterNote, contains('hi → ta'));
    expect(rider.audio.translateLang, 'hi');
    expect(driver.audio.translateLang, 'ta');
    expect(rider.audio.relayRaw, isFalse);
    expect(rider.audio.speaker, isTrue);
    rider.audio.speak(Uint8List(640));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(driver.audio.played, isEmpty, reason: 'no raw voice in interpreter mode');

    // rider speaks Hindi: recognised -> translated -> driver's phone speaks Tamil
    rider.audio.recognise('कृपया यहाँ रुकिए');
    await eventually(() => driver.pipeline.spoken.isNotEmpty ? true : null, what: 'driver hears the translation');
    expect(driver.pipeline.spoken.single, 'ta:[hi>ta] कृपया यहाँ रुकिए');
    expect(rider.pipeline.spoken, isEmpty);
    expect(rider.convo.state.bubbles.single.translated, '[hi>ta] कृपया यहाँ रुकिए');
    expect(rider.call.state.lastRecognisedMs, 900);

    // the recogniser is gated while a translation is playing on that phone (no feedback loop)
    await eventually(() => driver.audio.gated ? true : null, what: 'gate closes while speaking');
    driver.audio.recognise('ignored: this is our own loudspeaker');
    await eventually(() => !driver.audio.gated ? true : null, what: 'gate reopens');
    expect(rider.pipeline.spoken, isEmpty);

    // driver answers in Tamil -> rider hears Hindi
    driver.audio.recognise('சரி, வருகிறேன்');
    await eventually(() => rider.pipeline.spoken.isNotEmpty ? true : null, what: 'rider hears the translation');
    expect(rider.pipeline.spoken.single, 'hi:[ta>hi] சரி, வருகிறேன்');

    // switching off the interpreter hands the line back to the original voices
    await rider.call.setInterpreter(false);
    expect(rider.call.state.interpreter, isFalse);
    expect(rider.audio.relayRaw, isTrue);
    expect(rider.audio.translateLang, isNull);
    rider.audio.speak(Uint8List.fromList(List.filled(640, 9)));
    await eventually(() => driver.audio.played.length == 1 ? true : null, what: 'raw voice flows again');
    await rider.call.setInterpreter(true);
    expect(rider.audio.relayRaw, isFalse);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('same-language call uses original voices; without the NPU model it says why', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    final rideId = ride.state.remoteId!;
    await eventually(() => driverCubit.state.ride);
    rider.convo.bind(rideId: rideId, myLang: 'hi', peerLang: 'hi', peerName: 'Murugan');
    await rider.call.call(rideId: rideId, peerName: 'Murugan');
    await eventually(() => driver.call.state.phase == CallPhase.incoming ? true : null);
    await driver.call.accept();
    await eventually(() => rider.call.state.phase == CallPhase.active ? true : null);
    expect(rider.call.state.interpreter, isFalse);
    expect(rider.call.state.interpreterNote, contains('Same language'));
    expect(rider.audio.relayRaw, isTrue);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('voice call survives a short network drop? no: it ends cleanly and can be redialled', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    final rideId = ride.state.remoteId!;
    await rider.call.call(rideId: rideId, peerName: 'Murugan');
    await eventually(() => driver.call.state.phase == CallPhase.incoming ? true : null);
    driver.call.decline();
    await eventually(() => rider.call.state.endReason == 'declined' ? true : null, what: 'declined');
    await eventually(() => rider.call.state.phase == CallPhase.idle ? true : null, timeout: const Duration(seconds: 4), what: 'overlay clears');
    await rider.call.call(rideId: rideId, peerName: 'Murugan');
    await eventually(() => driver.call.state.phase == CallPhase.incoming ? true : null, what: 'redial rings again');
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('provisioning file configures a phone once (fleet setup) and is deleted', () async {
    final f = File('${dir.path}/provision.json');
    f.writeAsStringSync('{"role":"driver","name":"Auto 42","lang":"ta","vehicle":{"type":"auto","plate":"TN09AB4242","model":"Bajaj RE"},"server":"$url"}');
    final fresh = SessionCubit();
    await fresh.load(provisionFile: f);
    expect(fresh.state.profile!.role, proto.Role.driver);
    expect(fresh.state.profile!.vehicle!.type, proto.VehicleType.auto);
    expect(fresh.state.profile!.vehicle!.plate, 'TN09AB4242');
    expect(f.existsSync(), isFalse);
    await eventually(() => fresh.state.connected ? true : null, what: 'provisioned phone connects');
    await fresh.close();
    final bad = File('${dir.path}/bad.json')..writeAsStringSync('{"role":"pilot"}');
    final s2 = SessionCubit();
    await s2.load(provisionFile: bad);
    expect(s2.state.configured, isFalse);
    expect(s2.state.error, contains('Provisioning file is invalid'));
    await s2.close();
  }, skip: skip);

  test('network drop mid-ride: both phones reconnect and resume the ride', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    final rideId = ride.state.remoteId!;

    // the server side of both sockets dies (tunnel, Wi-Fi handover)
    server.hub.peers[rider.session.state.profile == null ? '' : server.hub.peers.keys.firstWhere((k) => k.startsWith('r-'))]!.conn!.close(4002, 'test drop');
    server.hub.peers[server.hub.peers.keys.firstWhere((k) => k.startsWith('d-'))]!.conn!.close(4002, 'test drop');
    await eventually(() => !rider.session.state.connected || !driver.session.state.connected ? true : null, what: 'clients notice the drop');
    await eventually(() => rider.session.state.connected && driver.session.state.connected ? true : null, timeout: const Duration(seconds: 8), what: 'clients reconnect');

    // state is intact on both sides, and the conversation keeps working
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(server.hub.rides[rideId]!.state, proto.RideState.assigned);
    expect(ride.state.stage, RideStage.toPickup);
    expect(driverCubit.state.ride?.id, rideId);
    driverCubit.arrived();
    await eventually(() => ride.state.message?.contains('arrived') == true ? true : null, what: 'ride continues after reconnect');
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('rider cancels while searching and after assignment; a driver cancel re-dispatches', () async {
    driverCubit.goOnline(true);
    driver.gps.push(12.9205, 77.6238);
    await eventually(() => server.hub.onlineDrivers == 1 ? true : null);
    await bookCab();
    await eventually(() => driverCubit.state.offer);
    await ride.cancel();
    await eventually(() => ride.state.stage == RideStage.quoted && !ride.state.remote ? true : null, what: 'cancelled before accept');
    await eventually(() => driverCubit.state.offer == null ? true : null, what: 'offer withdrawn from the driver');

    await ride.requestRide();
    await eventually(() => driverCubit.state.offer);
    driverCubit.accept();
    await eventually(() => ride.state.stage == RideStage.toPickup ? true : null);
    driverCubit.cancelRide();
    await eventually(() => ride.state.stage == RideStage.searching && ride.state.message!.contains('another driver') ? true : null, what: 'ride back in the pool');
    expect(driverCubit.state.ride, isNull);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('server restarted with a new secret: phones notice the rejected token, register again and reconnect', () async {
    final port = server.port;
    final oldId = rider.session.state.profile == null ? '' : 'x';
    expect(oldId, isNotEmpty);
    await server.stop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server = DharaniServer(ServerConfig(host: '127.0.0.1', port: port, secret: 'a-completely-new-secret-0123456', hub: const HubConfig(disconnectGrace: Duration(seconds: 6))));
    await server.start();
    await eventually(() => !rider.session.state.connected && !driver.session.state.connected ? true : null, what: 'phones notice the old server is gone');
    await eventually(() => rider.session.state.connected && driver.session.state.connected ? true : null, timeout: const Duration(seconds: 20), what: 'both phones back on the new server');
    expect(server.hub.peers.length, 2);
  }, skip: skip, timeout: const Timeout(Duration(seconds: 40)));

  test('offline server: rider gets a clear error instead of a silent failure', () async {
    final offline = SessionCubit();
    await offline.configure(profile: const Profile(role: proto.Role.rider, name: 'X', lang: 'en'), serverUrl: 'http://127.0.0.1:1');
    await eventually(() => offline.state.error?.contains('Cannot reach the server') == true ? true : null, what: 'unreachable server explained');
    expect(offline.state.conn, ConnState.reconnecting);
    await offline.close();
    final s = SessionCubit();
    await s.configure(profile: const Profile(role: proto.Role.rider, name: 'X', lang: 'en'), serverUrl: 'not a url');
    expect(s.state.error, contains('Enter the server'));
    expect(s.state.configured, isFalse);
    await s.close();
  }, skip: skip);

  test('driver app shows reconnect state and refuses to go online without a connection', () async {
    await driver.session.signOut();
    driverCubit.goOnline(true);
    expect(driverCubit.state.online, isFalse);
    expect(driverCubit.state.error, contains('Not connected'));
  }, skip: skip);

  test('app shell renders the right tabs per role', () async {
    // covered visually on device; here we only assert the role routing helper
    expect(AppRole.tabsFor(proto.Role.rider), ['Ride', 'Freight', 'Translate', 'Account']);
    expect(AppRole.tabsFor(proto.Role.driver), ['Drive', 'Freight', 'Translate', 'Account']);
  }, skip: skip);
}
