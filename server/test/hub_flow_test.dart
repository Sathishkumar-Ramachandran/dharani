import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';
import 'package:dharani_server/auth.dart';
import 'package:dharani_server/hub.dart';
import 'package:test/test.dart';

import 'support.dart';

// Bengaluru-ish coordinates.
const pickupLat = 12.9177, pickupLon = 77.6238;
const dropLat = 12.9716, dropLon = 77.5946;

Future<TestClient> driver(dynamic s, {VehicleType type = VehicleType.cab, double lat = pickupLat + 0.003, double lon = pickupLon, String name = 'Driver', String lang = 'ta'}) async {
  final d = await TestClient.register(s, Role.driver, name: name, lang: lang);
  await d.connect(vehicle: type);
  d.send({'t': T.driverOnline, 'online': true});
  d.send({'t': T.driverLocation, 'lat': lat, 'lon': lon, 'heading': 90, 'speed': 5});
  await Future<void>.delayed(const Duration(milliseconds: 60));
  return d;
}

/// Matches a ride.update for a specific ride and state (earlier updates may still be queued).
bool Function(Json) rs(String id, String state) => (m) => (m['ride'] as Map)['id'] == id && (m['ride'] as Map)['state'] == state;

Json rideRequest({String mode = 'cab', int fare = 180}) => {
      't': T.rideRequest,
      'pickup': place('Silk Board', pickupLat, pickupLon),
      'drop': place('Cubbon Park', dropLat, dropLon),
      'mode': mode,
      'fareRupees': fare,
    };

void main() {
  test('register, token auth and hello handshake', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final rider = await TestClient.register(s, Role.rider, lang: 'hi');
    // no token / forged token are refused before the upgrade
    final c = HttpClient();
    for (final url in ['ws://127.0.0.1:${s.port}/v1/ws', 'ws://127.0.0.1:${s.port}/v1/ws?token=${rider.token}x']) {
      await expectLater(WebSocket.connect(url), throwsA(isA<WebSocketException>()));
    }
    c.close();
    final w = await rider.connect();
    expect(w['userId'], rider.userId);
    expect(w['role'], 'rider');
    expect(w['protocol'], protocolVersion);
    expect(s.hub.metrics.connections, 1);
  });

  test('the first frame must be hello with a matching protocol version', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final r = await TestClient.register(s, Role.rider);
    r.socket = await WebSocket.connect('ws://127.0.0.1:${s.port}/v1/ws?token=${r.token}');
    final got = <Json>[];
    r.socket.listen((d) => got.add(jsonDecode(d as String) as Map<String, dynamic>));
    r.socket.add(jsonEncode({'t': T.ping}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got.single['code'], ErrorCode.protocol);
    r.socket.add(jsonEncode({'t': T.hello, 'protocol': 99, 'name': 'x', 'lang': 'en'}));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(got.last['message'], contains('protocol version'));
  });

  test('registration validates input', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final c = HttpClient();
    Future<int> post(Object body) async {
      final req = await c.postUrl(Uri.parse('http://127.0.0.1:${s.port}/v1/register'));
      req.headers.contentType = ContentType.json;
      req.write(body is String ? body : jsonEncode(body));
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    }
    expect(await post({'name': 'A', 'role': 'admin', 'lang': 'en'}), 400);
    expect(await post({'name': 'A', 'role': 'rider', 'lang': 'xx'}), 400);
    expect(await post('not json'), 400);
    expect(await post([1, 2]), 400);
    expect(await post({'name': 'A', 'role': 'rider', 'lang': 'en'}), 200);
    c.close(force: true);
  });

  test('full ride: request, offer, accept, live location, OTP start, translated chat, complete', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final d = await driver(s);
    final r = await TestClient.register(s, Role.rider, name: 'Asha', lang: 'hi');
    await r.connect();

    r.send(rideRequest());
    final requested = await r.next(T.rideUpdate);
    expect((requested['ride'] as Map)['state'], 'REQUESTED');
    final offer = await d.next(T.offer);
    expect(offer['mode'], 'cab');
    expect(offer['fareRupees'], 180);
    expect(offer['distanceToPickupM'], inInclusiveRange(250, 450));
    final rideId = offer['rideId'] as String;

    d.send({'t': T.offerAccept, 'rideId': rideId});
    final assigned = ((await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ASSIGNED'))['ride']) as Map;
    final otp = assigned['otp'] as String;
    expect(otp, matches(RegExp(r'^\d{4}$')));
    expect((assigned['driver'] as Map)['name'], 'Driver');
    expect((assigned['driver'] as Map)['lang'], 'ta');
    final driverView = ((await d.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ASSIGNED'))['ride']) as Map;
    expect(driverView.containsKey('otp'), isFalse, reason: 'the OTP must never reach the driver');
    expect((driverView['rider'] as Map)['lang'], 'hi');

    // live driver location reaches the rider only
    d.send({'t': T.driverLocation, 'lat': pickupLat + 0.001, 'lon': pickupLon, 'heading': 180, 'speed': 8});
    final loc = await r.next(T.peerLocation);
    expect(loc['lat'], closeTo(pickupLat + 0.001, 1e-9));
    expect(loc['rideId'], rideId);

    d.send({'t': T.rideArrived, 'rideId': rideId});
    expect(((await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ARRIVED'))['ride'] as Map)['state'], 'ARRIVED');

    d.send({'t': T.rideStart, 'rideId': rideId, 'otp': '0000x'.substring(0, 4) == otp ? '1111' : '0000'});
    expect((await d.next(T.error))['code'], ErrorCode.forbidden);
    d.send({'t': T.rideStart, 'rideId': rideId, 'otp': otp});
    expect(((await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ON_TRIP'))['ride'] as Map)['state'], 'ON_TRIP');

    // live translated conversation both ways
    r.send({'t': T.chatUtterance, 'rideId': rideId, 'text': 'कृपया धीरे चलाइए', 'translated': 'தயவுசெய்து மெதுவாக ஓட்டுங்கள்', 'srcLang': 'hi', 'tgtLang': 'ta', 'seq': 1});
    final heard = await d.next(T.chatUtterance);
    expect(heard['translated'], 'தயவுசெய்து மெதுவாக ஓட்டுங்கள்');
    expect(heard['fromRole'], 'rider');
    expect(heard['tgtLang'], 'ta');
    d.send({'t': T.chatUtterance, 'rideId': rideId, 'text': 'சரி', 'translated': 'ठीक है', 'srcLang': 'ta', 'tgtLang': 'hi', 'seq': 1});
    expect((await r.next(T.chatUtterance))['translated'], 'ठीक है');
    expect(await d.none(T.chatUtterance), isTrue, reason: 'no echo to the sender');

    // the driver switches to French mid-ride: the rider's phone is told, nobody else is
    d.send({'t': T.setLang, 'lang': 'fr'});
    final changed = await r.next(T.peerLang);
    expect(changed['lang'], 'fr');
    expect(changed['rideId'], rideId);
    d.send({'t': T.setLang, 'lang': 'xx'});
    expect((await d.next(T.error))['code'], isNotNull);

    d.send({'t': T.rideComplete, 'rideId': rideId});
    expect(((await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'COMPLETED'))['ride'] as Map)['state'], 'COMPLETED');
    expect(s.hub.metrics.ridesCompleted, 1);
    expect(s.hub.metrics.utterances, 2);

    // both are free for new rides, and chat is closed after completion
    r.send({'t': T.chatUtterance, 'rideId': rideId, 'text': 'hi', 'translated': '', 'srcLang': 'hi', 'tgtLang': 'ta'});
    expect((await r.next(T.error))['code'], ErrorCode.conflict);
    r.send(rideRequest());
    expect(((await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'REQUESTED'))['ride'] as Map)['state'], 'REQUESTED');
  });

  test('matching: nearest drivers first, right vehicle type, inside the radius', () async {
    final s = await startServer(hub: const HubConfig(offerBatch: 2, offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final near = await driver(s, lat: pickupLat + 0.002, name: 'near');
    final mid = await driver(s, lat: pickupLat + 0.006, name: 'mid');
    final far = await driver(s, lat: pickupLat + 0.02, name: 'far'); // ~2.2 km
    final wrongType = await driver(s, type: VehicleType.bike, lat: pickupLat + 0.001, name: 'bike');
    final tooFar = await driver(s, lat: pickupLat + 0.2, name: 'tooFar'); // ~22 km
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    expect((await near.next(T.offer))['rideId'], isNotNull);
    expect((await mid.next(T.offer))['rideId'], isNotNull);
    expect(await far.none(T.offer), isTrue, reason: 'batch is 2: the third driver waits');
    expect(await wrongType.none(T.offer), isTrue);
    expect(await tooFar.none(T.offer), isTrue);
    // when the nearest declines, the next closest receives the offer
    final id = (await far.none(T.offer, wait: Duration.zero)) ? null : null;
    expect(id, isNull);
    final offerId = (s.hub.rides.keys.single);
    near.send({'t': T.offerDecline, 'rideId': offerId});
    expect((await far.next(T.offer))['rideId'], offerId);
    expect(await near.none(T.offer), isTrue, reason: 'a driver who declined is not asked again');
  });

  test('two drivers accept at once: exactly one wins, the other is told', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final a = await driver(s, name: 'A');
    final b = await driver(s, name: 'B', lat: pickupLat + 0.004);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    final id = (await a.next(T.offer))['rideId'] as String;
    await b.next(T.offer);
    a.send({'t': T.offerAccept, 'rideId': id});
    b.send({'t': T.offerAccept, 'rideId': id});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final aErr = !(await a.none(T.error, wait: Duration.zero)), bErr = !(await b.none(T.error, wait: Duration.zero));
    expect(aErr != bErr, isTrue, reason: 'one winner, one conflict (a=$aErr b=$bErr)');
    final ride = s.hub.rides[id]!;
    expect(ride.state, RideState.assigned);
    final loser = ride.driverId == a.userId ? b : a;
    expect((await loser.next(T.error))['code'], ErrorCode.conflict);
  });

  test('offers expire and are re-sent; with nobody accepting the search ends in NO_DRIVERS', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(milliseconds: 250), retryInterval: Duration(milliseconds: 100), searchTimeout: Duration(milliseconds: 900)));
    addTearDown(s.stop);
    final d = await driver(s);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    await d.next(T.offer);
    await d.next(T.offer, timeout: const Duration(seconds: 2)); // re-offered after expiry
    final end = await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'NO_DRIVERS', timeout: const Duration(seconds: 3));
    expect((end['ride'] as Map)['reason'], contains('no driver'));
    d.send({'t': T.offerAccept, 'rideId': s.hub.rides.keys.single});
    expect((await d.next(T.error))['code'], ErrorCode.conflict, reason: 'accepting a dead ride is refused');
    expect(s.hub.metrics.noDrivers, 1);
  });

  test('a driver coming online later still picks up a waiting request', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    await r.next(T.rideUpdate);
    final d = await driver(s);
    expect((await d.next(T.offer, timeout: const Duration(seconds: 2)))['mode'], 'cab');
  });

  test('cancellation rules', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final d = await driver(s);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    // rider cancels while offers are out: the driver's offer is withdrawn
    r.send(rideRequest());
    final id = (await d.next(T.offer))['rideId'] as String;
    r.send({'t': T.rideCancel, 'rideId': id});
    expect((await d.next(T.offerCancelled))['reason'], contains('rider cancelled'));
    expect(s.hub.rides[id]!.state, RideState.cancelled);

    // after assignment the rider can still cancel and the driver is released
    r.send(rideRequest());
    final id2 = (await d.next(T.offer))['rideId'] as String;
    d.send({'t': T.offerAccept, 'rideId': id2});
    await d.next(T.rideUpdate, where: rs(id2, 'ASSIGNED'));
    r.send({'t': T.rideCancel, 'rideId': id2});
    expect(((await d.next(T.rideUpdate, where: rs(id2, 'CANCELLED')))['ride'] as Map)['state'], 'CANCELLED');
    expect(s.hub.peers[d.userId]!.rideId, isNull);

    // a trip in progress cannot be cancelled
    r.send(rideRequest());
    final id3 = (await d.next(T.offer))['rideId'] as String;
    d.send({'t': T.offerAccept, 'rideId': id3});
    final otp = (((await r.next(T.rideUpdate, where: rs(id3, 'ASSIGNED')))['ride']) as Map)['otp'] as String;
    d.send({'t': T.rideStart, 'rideId': id3, 'otp': otp});
    await r.next(T.rideUpdate, where: rs(id3, 'ON_TRIP'));
    r.send({'t': T.rideCancel, 'rideId': id3});
    expect((await r.next(T.error))['code'], ErrorCode.conflict);
  });

  test('a driver who cancels sends the ride back to the pool and another driver gets it', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final a = await driver(s, name: 'A');
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    final id = (await a.next(T.offer))['rideId'] as String;
    a.send({'t': T.offerAccept, 'rideId': id});
    await r.next(T.rideUpdate, where: rs(id, 'ASSIGNED'));
    final b = await driver(s, name: 'B', lat: pickupLat + 0.005);
    a.send({'t': T.rideCancel, 'rideId': id});
    final back = await r.next(T.rideUpdate, where: (m) => rs(id, 'REQUESTED')(m) && (m['ride'] as Map)['reason'] != null);
    expect((back['ride'] as Map)['reason'], contains('driver cancelled'));
    expect((await b.next(T.offer))['rideId'], id);
    expect(await a.none(T.offer), isTrue, reason: 'the cancelling driver is excluded');
    final released = await a.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'CANCELLED');
    expect((released['ride'] as Map)['reason'], contains('driver cancelled'), reason: 'the driver is told the assignment ended');
  });

  test('authorization and validation', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final d = await driver(s);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    final stranger = await TestClient.register(s, Role.rider, name: 'Mallory');
    await stranger.connect();

    r.send(rideRequest());
    final id = (await d.next(T.offer))['rideId'] as String;
    d.send({'t': T.offerAccept, 'rideId': id});
    await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ASSIGNED');

    stranger.send({'t': T.rideCancel, 'rideId': id});
    expect((await stranger.next(T.error))['code'], ErrorCode.forbidden);
    stranger.send({'t': T.chatUtterance, 'rideId': id, 'text': 'hi', 'translated': '', 'srcLang': 'en', 'tgtLang': 'ta'});
    expect((await stranger.next(T.error))['code'], ErrorCode.forbidden);
    r.send({'t': T.driverLocation, 'lat': 12.9, 'lon': 77.6});
    expect((await r.next(T.error))['code'], ErrorCode.forbidden, reason: 'riders cannot report driver locations');
    r.send({'t': T.rideComplete, 'rideId': id});
    expect((await r.next(T.error))['code'], ErrorCode.forbidden);
    r.send(rideRequest());
    expect((await r.next(T.error))['code'], ErrorCode.conflict, reason: 'one active ride per rider');

    for (final bad in <Json>[
      {'t': 'nope'},
      {'t': T.rideRequest, 'pickup': place('a', 95, 0), 'drop': place('b', 12.9, 77.6), 'mode': 'cab', 'fareRupees': 100},
      {'t': T.rideRequest, 'pickup': place('a', 12.9, 77.6), 'drop': place('b', 12.9001, 77.6001), 'mode': 'cab', 'fareRupees': 100},
      {'t': T.rideRequest, 'pickup': place('a', 12.9, 77.6), 'drop': place('b', 13.5, 77.6), 'mode': 'spaceship', 'fareRupees': 100},
      {'t': T.offerAccept, 'rideId': 'does-not-exist'},
      {'rideId': 1},
    ]) {
      stranger.send(bad);
      final e = await stranger.next(T.error);
      expect(e['code'], anyOf(ErrorCode.badRequest, ErrorCode.notFound, ErrorCode.forbidden), reason: '$bad');
    }
    d.send({'t': T.driverLocation, 'lat': double.nan.toString(), 'lon': 0});
    expect((await d.next(T.error))['code'], ErrorCode.badRequest);
  });

  test('oversized frames are rejected and the rate limit bites', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    for (var i = 0; i < 200; i++) {
      r.send({'t': T.ping, 'n': i});
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    var limited = false;
    while (!(await r.none(T.error, wait: Duration.zero))) {
      if ((await r.next(T.error))['code'] == ErrorCode.rateLimited) limited = true;
    }
    expect(limited, isTrue);
    final big = await TestClient.register(s, Role.rider);
    await big.connect();
    big.socket.add(jsonEncode({'t': T.chatUtterance, 'pad': 'x' * (maxFrameBytes + 10)}));
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(big.closed, isTrue);
    expect(big.closeCode, 1009);
  });

  test('reconnect: a new socket replaces the old and receives the ride snapshot; a lost driver is replaced', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100), disconnectGrace: Duration(milliseconds: 300)));
    addTearDown(s.stop);
    final a = await driver(s, name: 'A');
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    final id = (await a.next(T.offer))['rideId'] as String;
    a.send({'t': T.offerAccept, 'rideId': id});
    await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ASSIGNED');

    // rider reconnects (phone switched networks)
    final old = r.socket;
    final w = await r.connect();
    expect((w['ride'] as Map)['id'], id);
    expect((w['ride'] as Map)['otp'], isNotNull);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(old.closeCode, 4000);

    // driver A vanishes; after the grace period the ride is re-dispatched to B
    final b = await driver(s, name: 'B', lat: pickupLat + 0.005);
    await a.closeSocket();
    final back = await r.next(T.rideUpdate, where: (m) => rs(id, 'REQUESTED')(m) && (m['ride'] as Map)['reason'] != null, timeout: const Duration(seconds: 2));
    expect((back['ride'] as Map)['reason'], contains('lost connection'));
    expect((await b.next(T.offer))['rideId'], id);
    expect(s.hub.peers[a.userId]!.online, isFalse);
  });

  test('a driver who reconnects within the grace period keeps the ride', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100), disconnectGrace: Duration(milliseconds: 400)));
    addTearDown(s.stop);
    final a = await driver(s);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    final id = (await a.next(T.offer))['rideId'] as String;
    a.send({'t': T.offerAccept, 'rideId': id});
    await a.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ASSIGNED');
    await a.closeSocket();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final w = await a.connect(vehicle: VehicleType.cab);
    expect((w['ride'] as Map)['id'], id);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(s.hub.rides[id]!.state, RideState.assigned);
    expect(s.hub.rides[id]!.driverId, a.userId);
  });

  test('journal records ride events', () async {
    final dir = Directory.systemTemp.createTempSync('journal_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final s = await startServer(hub: HubConfig(journalPath: '${dir.path}/rides.jsonl', offerTtl: const Duration(seconds: 5), retryInterval: const Duration(milliseconds: 100)));
    final d = await driver(s);
    final r = await TestClient.register(s, Role.rider);
    await r.connect();
    r.send(rideRequest());
    final id = (await d.next(T.offer))['rideId'] as String;
    d.send({'t': T.offerAccept, 'rideId': id});
    await r.next(T.rideUpdate, where: (m) => (m['ride'] as Map)['state'] == 'ASSIGNED');
    await s.stop();
    final lines = File('${dir.path}/rides.jsonl').readAsLinesSync().map((l) => jsonDecode(l) as Map<String, dynamic>).toList();
    expect(lines.map((l) => l['ev']), containsAllInOrder(['driver_online', 'ride_requested', 'offer', 'assigned']));
    expect(lines.every((l) => l.containsKey('ts')), isTrue);
  });

  test('a plain GET on the socket path explains token problems (clients use it to re-register)', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final r = await TestClient.register(s, Role.rider);
    final c = HttpClient();
    Future<int> status(String q) async {
      final res = await (await c.getUrl(Uri.parse('http://127.0.0.1:${s.port}/v1/ws$q'))).close();
      await res.drain<void>();
      return res.statusCode;
    }
    expect(await status('?token=${r.token}'), 426);
    expect(await status('?token=bad'), 401);
    expect(await status(''), 401);
    c.close();
  });

  Future<(TestClient, TestClient, String)> assignedRide(dynamic s) async {
    final d = await driver(s);
    final r = await TestClient.register(s, Role.rider, name: 'Asha', lang: 'hi');
    await r.connect();
    r.send(rideRequest());
    final id = (await d.next(T.offer))['rideId'] as String;
    d.send({'t': T.offerAccept, 'rideId': id});
    await r.next(T.rideUpdate, where: rs(id, 'ASSIGNED'));
    await d.next(T.rideUpdate, where: rs(id, 'ASSIGNED'));
    return (r, d, id);
  }

  test('voice call: signalling, answer, bidirectional audio relay, hang up', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final (r, d, id) = await assignedRide(s);

    r.send({'t': T.callStart, 'rideId': id});
    expect((await r.next(T.callState))['state'], 'ringing');
    final incoming = await d.next(T.callIncoming);
    expect(incoming['fromName'], 'Asha');
    expect(incoming['fromRole'], 'rider');

    // audio before the call is answered goes nowhere
    r.sendBytes(Uint8List(640));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(d.binary, isEmpty);

    d.send({'t': T.callAccept, 'rideId': id});
    expect((await r.next(T.callState, where: (m) => m['state'] == 'active'))['rideId'], id);
    expect((await d.next(T.callState, where: (m) => m['state'] == 'active'))['rideId'], id);

    final up = Uint8List.fromList(List.generate(640, (i) => i % 251));
    final down = Uint8List.fromList(List.generate(640, (i) => (i * 7) % 253));
    for (var i = 0; i < 5; i++) {
      r.sendBytes(up);
      d.sendBytes(down);
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(d.binary, hasLength(5));
    expect(r.binary, hasLength(5));
    expect(d.binary.first, up, reason: 'rider -> driver, byte for byte');
    expect(r.binary.first, down, reason: 'driver -> rider, byte for byte');
    expect(s.hub.metrics.audioFrames, 10);

    r.send({'t': T.callEnd, 'rideId': id});
    expect((await d.next(T.callState, where: (m) => m['state'] == 'ended'))['reason'], 'hung up');
    r.sendBytes(up);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(d.binary, hasLength(5), reason: 'nothing flows after hang up');
    expect(s.hub.metrics.callsAnswered, 1);
  });

  test('voice call: decline, no-answer, ride end, and who may call', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100), callRingTimeout: Duration(milliseconds: 400)));
    addTearDown(s.stop);
    final (r, d, id) = await assignedRide(s);
    final stranger = await TestClient.register(s, Role.rider, name: 'Mallory');
    await stranger.connect();

    stranger.send({'t': T.callStart, 'rideId': id});
    expect((await stranger.next(T.error))['code'], ErrorCode.forbidden);
    stranger.sendBytes(Uint8List(640)); // injecting audio into someone else's call: ignored
    d.send({'t': T.callAccept, 'rideId': id});
    expect((await d.next(T.error))['code'], ErrorCode.notFound);

    // decline
    r.send({'t': T.callStart, 'rideId': id});
    await d.next(T.callIncoming);
    r.send({'t': T.callAccept, 'rideId': id}); // the caller cannot answer their own call
    expect((await r.next(T.error))['code'], ErrorCode.forbidden);
    d.send({'t': T.callDecline, 'rideId': id});
    expect((await r.next(T.callState, where: (m) => m['state'] == 'ended'))['reason'], 'declined');

    // unanswered calls time out
    d.send({'t': T.callStart, 'rideId': id});
    await r.next(T.callIncoming);
    r.send({'t': T.callStart, 'rideId': id});
    expect((await r.next(T.error))['code'], ErrorCode.conflict, reason: 'one call at a time');
    expect((await d.next(T.callState, where: (m) => m['state'] == 'ended' && m['reason'] == 'no answer', timeout: const Duration(seconds: 2)))['reason'], 'no answer');

    // oversized audio is refused, and a finished ride ends the call
    r.send({'t': T.callStart, 'rideId': id});
    await d.next(T.callIncoming);
    d.send({'t': T.callAccept, 'rideId': id});
    await r.next(T.callState, where: (m) => m['state'] == 'active');
    r.sendBytes(Uint8List(maxAudioFrameBytes + 1));
    expect((await r.next(T.error))['code'], ErrorCode.tooLarge);
    r.send({'t': T.rideCancel, 'rideId': id});
    expect((await d.next(T.callState, where: (m) => m['state'] == 'ended' && m['reason'] == 'ride ended'))['reason'], 'ride ended');
    expect(stranger.binary, isEmpty);
    expect(d.binary, isEmpty);
  });

  test('French is a supported language end to end (register, hello, translated chat)', () async {
    final s = await startServer(hub: const HubConfig(offerTtl: Duration(seconds: 5), retryInterval: Duration(milliseconds: 100)));
    addTearDown(s.stop);
    final d = await driver(s, lang: 'fr', name: 'Luc');
    final r = await TestClient.register(s, Role.rider, name: 'Asha', lang: 'hi');
    await r.connect();
    r.send(rideRequest());
    final id = (await d.next(T.offer))['rideId'] as String;
    d.send({'t': T.offerAccept, 'rideId': id});
    final view = (await r.next(T.rideUpdate, where: rs(id, 'ASSIGNED')))['ride'] as Map;
    expect((view['driver'] as Map)['lang'], 'fr');
    r.send({'t': T.chatUtterance, 'rideId': id, 'text': 'कृपया यहाँ रुकिए', 'translated': "Arrêtez-vous ici, s'il vous plaît", 'srcLang': 'hi', 'tgtLang': 'fr', 'seq': 1});
    expect((await d.next(T.chatUtterance))['tgtLang'], 'fr');
    // unsupported languages are still refused
    final bad = await TestClient.register(s, Role.rider, name: 'X', lang: 'en');
    await bad.connect();
    bad.send({'t': T.chatUtterance, 'rideId': id, 'text': 'x', 'translated': '', 'srcLang': 'xx', 'tgtLang': 'fr'});
    expect((await bad.next(T.error))['code'], anyOf(ErrorCode.badRequest, ErrorCode.forbidden));
  });

  test('health and metrics endpoints', () async {
    final s = await startServer();
    addTearDown(s.stop);
    final c = HttpClient();
    final res = await (await c.getUrl(Uri.parse('http://127.0.0.1:${s.port}/healthz'))).close();
    expect(jsonDecode(await utf8.decoder.bind(res).join())['ok'], isTrue);
    final m = await (await c.getUrl(Uri.parse('http://127.0.0.1:${s.port}/metrics'))).close();
    expect(jsonDecode(await utf8.decoder.bind(m).join()), containsPair('connections', 0));
    final nf = await (await c.getUrl(Uri.parse('http://127.0.0.1:${s.port}/nope'))).close();
    expect(nf.statusCode, 404);
    c.close();
  });

  test('token service: tamper, expiry, bad secret', () {
    var now = DateTime(2026, 1, 1);
    final t = TokenService(secret, clock: () => now);
    final tok = t.issue('r-abc', Role.rider, ttl: const Duration(hours: 1));
    expect(t.verify(tok)!.uid, 'r-abc');
    expect(t.verify(tok)!.role, Role.rider);
    expect(t.verify('$tok.x'), isNull);
    expect(t.verify(null), isNull);
    expect(t.verify('garbage'), isNull);
    final parts = tok.split('.');
    final forged = '${parts[0].replaceFirst(parts[0][3], parts[0][3] == 'A' ? 'B' : 'A')}.${parts[1]}';
    expect(t.verify(forged), isNull);
    expect(TokenService('another-secret-0123456789ab', clock: () => now).verify(tok), isNull);
    now = now.add(const Duration(hours: 2));
    expect(t.verify(tok), isNull);
    expect(() => TokenService('short'), throwsArgumentError);
    var tnow = DateTime(2026);
    final rl = RateLimiter(perSecond: 10, burst: 5, clock: () => tnow);
    expect(List.generate(6, (_) => rl.allow()), [true, true, true, true, true, false]);
    tnow = tnow.add(const Duration(milliseconds: 250));
    expect(rl.allow(), isTrue);
    expect(rl.allow(), isTrue);
    expect(rl.allow(), isFalse);
  });
}
