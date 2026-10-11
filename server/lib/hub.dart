import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';

/// A live client connection, abstracted so the hub can be tested without sockets.
abstract class Connection {
  void send(Json message);
  void sendBytes(Uint8List bytes);
  void close(int code, String reason);
}

class HubConfig {
  const HubConfig({
    this.offerTtl = const Duration(seconds: 20),
    this.offerBatch = 3,
    this.searchRadiusM = 6000,
    this.searchTimeout = const Duration(seconds: 90),
    this.retryInterval = const Duration(seconds: 5),
    this.disconnectGrace = const Duration(seconds: 30),
    this.maxLocationAge = const Duration(minutes: 2),
    this.callRingTimeout = const Duration(seconds: 30),
    this.journalPath,
  });

  final Duration offerTtl;
  final int offerBatch;
  final double searchRadiusM;
  final Duration searchTimeout;
  final Duration retryInterval;
  final Duration disconnectGrace;
  final Duration maxLocationAge;
  final Duration callRingTimeout;
  final String? journalPath;
}

class Vehicle {
  const Vehicle(this.type, this.plate, this.model);
  final VehicleType type;
  final String plate, model;
  Json toJson() => {'type': type.name, 'plate': plate, 'model': model};
}

class Peer {
  Peer(this.uid, this.role, this.name, this.lang);
  final String uid;
  final Role role;
  String name, lang;
  Vehicle? vehicle;
  Connection? conn;
  bool online = false; // drivers only: accepting offers
  double? lat, lon, heading, speed;
  DateTime? locationAt;
  String? rideId;
  Timer? graceTimer;
}

class Ride {
  Ride(this.id, this.riderId, this.pickup, this.drop, this.mode, this.fareRupees, this.otp, this.createdAt);
  final String id, riderId, otp;
  final Place pickup, drop;
  final VehicleType mode;
  final int fareRupees;
  final DateTime createdAt;
  String? driverId;
  RideState state = RideState.requested;
  String? reason;
  final offers = <String, DateTime>{}; // driverId -> expiry
  final declined = <String>{};
  Timer? offerTimer, searchTimer;
  DateTime? assignedAt, startedAt, completedAt;
}

class Call {
  Call(this.rideId, this.callerId, this.calleeId);
  final String rideId, callerId, calleeId;
  bool active = false;
  Timer? ringTimer;
  DateTime? answeredAt;
}

class Metrics {
  int audioFrames = 0, callsStarted = 0, callsAnswered = 0;
  int connections = 0, messages = 0, errors = 0, ridesRequested = 0, ridesCompleted = 0, ridesCancelled = 0, noDrivers = 0, utterances = 0;
  Json toJson() => {'connections': connections, 'messages': messages, 'errors': errors, 'rides_requested': ridesRequested, 'rides_completed': ridesCompleted, 'rides_cancelled': ridesCancelled, 'no_drivers': noDrivers, 'utterances': utterances, 'audio_frames': audioFrames, 'calls_started': callsStarted, 'calls_answered': callsAnswered};
}

/// All business logic. Everything runs on one isolate, so every handler is atomic with respect to
/// the others (the "first driver to accept wins" rule needs no locking).
class Hub {
  Hub(this.config, {DateTime Function()? clock, math.Random? random}) : _clock = clock ?? DateTime.now, _rng = random ?? math.Random.secure();

  final HubConfig config;
  final DateTime Function() _clock;
  final math.Random _rng;
  final metrics = Metrics();
  final peers = <String, Peer>{};
  final rides = <String, Ride>{};
  final calls = <String, Call>{}; // by rideId
  IOSink? _journal;
  int _rideSeq = 0;

  int get onlineDrivers => peers.values.where((p) => p.role == Role.driver && p.online).length;

  void openJournal() {
    final path = config.journalPath;
    if (path != null) _journal = File(path).openWrite(mode: FileMode.append);
  }

  Future<void> close() async {
    for (final r in rides.values) {
      r.offerTimer?.cancel();
      r.searchTimer?.cancel();
    }
    for (final c in calls.values) {
      c.ringTimer?.cancel();
    }
    for (final p in peers.values) {
      p.graceTimer?.cancel();
      // Upgraded sockets are detached from the HTTP server, so close them explicitly (clients then reconnect elsewhere).
      p.conn?.close(1001, 'server shutting down');
    }
    await _journal?.flush();
    await _journal?.close();
  }

  void _log(String event, Json data) {
    final sink = _journal;
    if (sink == null) return;
    sink.writeln(jsonEncode({'ts': _clock().toUtc().toIso8601String(), 'ev': event, ...data}));
  }

  // ------------------------------------------------------------------ connection lifecycle
  /// Registers a socket for an authenticated user. A second connection for the same user replaces the first.
  Peer attach(String uid, Role role, Connection conn) {
    metrics.connections++;
    var peer = peers[uid];
    peer ??= peers[uid] = Peer(uid, role, '', 'en');
    peer.graceTimer?.cancel();
    final old = peer.conn;
    peer.conn = conn;
    old?.close(4000, 'replaced by a newer connection');
    return peer;
  }

  void detach(Peer peer, Connection conn) {
    if (!identical(peer.conn, conn)) return; // already replaced
    peer.conn = null;
    peer.graceTimer?.cancel();
    peer.graceTimer = Timer(config.disconnectGrace, () => _graceExpired(peer));
  }

  void _graceExpired(Peer peer) {
    if (peer.conn != null) return;
    if (peer.role == Role.driver) {
      peer.online = false;
      final ride = _activeRideOf(peer);
      if (ride != null) {
        if (ride.state == RideState.assigned || ride.state == RideState.arrived) {
          _driverLeaves(ride, peer, 'driver lost connection');
        } else if (ride.state == RideState.onTrip) {
          _notifyRide(ride, extra: {'driverOffline': true});
        }
      }
    } else {
      final ride = _activeRideOf(peer);
      if (ride != null && ride.state != RideState.onTrip) _finish(ride, RideState.cancelled, 'rider lost connection');
    }
  }

  // ------------------------------------------------------------------ message handling
  /// Entry point for every decoded client frame (after `hello`).
  void handle(Peer peer, Json m) {
    final type = m['t'];
    if (type is! String) throw ProtocolException(ErrorCode.badRequest, 'missing message type');
    metrics.messages++;
    switch (type) {
      case T.ping:
        _send(peer, {'t': T.pong, if (m['n'] != null) 'n': m['n']});
      case T.driverOnline:
        _requireRole(peer, Role.driver);
        _setOnline(peer, reqBool(m, 'online'));
      case T.driverLocation:
        _requireRole(peer, Role.driver);
        _location(peer, m);
      case T.rideRequest:
        _requireRole(peer, Role.rider);
        _request(peer, m);
      case T.rideCancel:
        _cancel(peer, _ride(m));
      case T.offerAccept:
        _requireRole(peer, Role.driver);
        _accept(peer, _ride(m));
      case T.offerDecline:
        _requireRole(peer, Role.driver);
        _decline(peer, _ride(m));
      case T.rideArrived:
        _requireRole(peer, Role.driver);
        _arrived(peer, _ride(m));
      case T.rideStart:
        _requireRole(peer, Role.driver);
        _start(peer, _ride(m), reqString(m, 'otp', max: 8));
      case T.rideComplete:
        _requireRole(peer, Role.driver);
        _complete(peer, _ride(m));
      case T.chatUtterance:
        _utterance(peer, m);
      case T.callStart:
        _callStart(peer, _ride(m));
      case T.callAccept:
        _callAnswer(peer, _ride(m), accept: true);
      case T.callDecline:
        _callAnswer(peer, _ride(m), accept: false);
      case T.callEnd:
        _callEnd(peer, _ride(m));
      case T.setLang:
        _setLang(peer, reqLang(m, 'lang'));
      default:
        throw ProtocolException(ErrorCode.badRequest, 'unknown message type "$type"');
    }
  }

  /// A user changed their language: remember it for future matches and tell the counterpart of the
  /// active ride so their phone translates into the right language straight away.
  void _setLang(Peer peer, String lang) {
    peer.lang = lang;
    final ride = _activeRideOf(peer);
    final to = ride == null ? null : _counterpart(ride, peer);
    if (ride != null && to != null) _send(to, {'t': T.peerLang, 'rideId': ride.id, 'lang': lang});
  }

  /// Applies a `hello` frame: profile data used for matching and for translation.
  Json hello(Peer peer, Json m) {
    peer.name = reqString(m, 'name', max: 60);
    peer.lang = reqLang(m, 'lang');
    if (peer.role == Role.driver) {
      final v = m['vehicle'];
      if (v is! Map<String, dynamic>) throw ProtocolException(ErrorCode.badRequest, 'drivers must send a vehicle');
      peer.vehicle = Vehicle(reqEnum(v, 'type', VehicleType.values), reqString(v, 'plate', max: 20), reqString(v, 'model', max: 40, allowEmpty: true));
    }
    final ride = _activeRideOf(peer);
    return {
      't': T.welcome,
      'userId': peer.uid,
      'role': peer.role.name,
      'protocol': protocolVersion,
      if (ride != null) 'ride': _rideJson(ride, forRider: peer.role == Role.rider),
      if (peer.role == Role.driver) 'online': peer.online,
    };
  }

  // ------------------------------------------------------------------ drivers
  void _setOnline(Peer driver, bool online) {
    if (driver.vehicle == null) throw ProtocolException(ErrorCode.forbidden, 'say hello with a vehicle first');
    if (online && driver.rideId != null && (rides[driver.rideId]?.state.active ?? false)) {
      driver.online = true;
      return;
    }
    driver.online = online;
    _log(online ? 'driver_online' : 'driver_offline', {'driver': driver.uid});
    if (online) {
      for (final r in rides.values.where((r) => r.state == RideState.requested)) {
        _dispatch(r);
      }
    } else {
      for (final r in rides.values) {
        if (r.offers.remove(driver.uid) != null) _send(driver, {'t': T.offerCancelled, 'rideId': r.id, 'reason': 'you went offline'});
      }
    }
  }

  void _location(Peer driver, Json m) {
    final lat = reqNum(m, 'lat', min: -90, max: 90), lon = reqNum(m, 'lon', min: -180, max: 180);
    if (!validCoordinate(lat, lon)) throw ProtocolException(ErrorCode.badRequest, 'invalid coordinates');
    driver.lat = lat;
    driver.lon = lon;
    driver.heading = m['heading'] is num ? (m['heading'] as num).toDouble() : 0;
    driver.speed = m['speed'] is num ? (m['speed'] as num).toDouble() : 0;
    driver.locationAt = _clock();
    final ride = _activeRideOf(driver);
    if (ride != null && ride.state.hasPeer) {
      final rider = peers[ride.riderId];
      if (rider != null) {
        _send(rider, {
          't': T.peerLocation,
          'rideId': ride.id,
          'lat': lat,
          'lon': lon,
          'heading': driver.heading,
          'speed': driver.speed,
          'tamper': m['tamper'] == true,
          'ts': _clock().millisecondsSinceEpoch,
        });
      }
    }
  }

  // ------------------------------------------------------------------ rides
  void _request(Peer rider, Json m) {
    if (_activeRideOf(rider) != null) throw ProtocolException(ErrorCode.conflict, 'you already have an active ride');
    final pickup = Place.fromJson(m['pickup'], 'pickup'), drop = Place.fromJson(m['drop'], 'drop');
    if (distanceMeters(pickup.lat, pickup.lon, drop.lat, drop.lon) < 100) throw ProtocolException(ErrorCode.badRequest, 'pickup and drop are too close');
    final mode = reqEnum(m, 'mode', VehicleType.values);
    final fare = reqNum(m, 'fareRupees', min: 1, max: 1000000).round();
    final id = 'r${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${(++_rideSeq).toRadixString(36)}';
    final otp = (1000 + _rng.nextInt(9000)).toString();
    final ride = Ride(id, rider.uid, pickup, drop, mode, fare, otp, _clock());
    rides[id] = ride;
    rider.rideId = id;
    metrics.ridesRequested++;
    _log('ride_requested', {'ride': id, 'rider': rider.uid, 'mode': mode.name, 'fare': fare});
    ride.searchTimer = Timer(config.searchTimeout, () => _searchExpired(ride));
    _notifyRide(ride);
    _dispatch(ride);
  }

  void _dispatch(Ride ride) {
    if (ride.state != RideState.requested) return;
    final now = _clock();
    ride.offers.removeWhere((_, exp) => !exp.isAfter(now));
    final room = config.offerBatch - ride.offers.length;
    if (room > 0) {
      final candidates = <(Peer, double)>[];
      for (final d in peers.values) {
        if (d.role != Role.driver || !d.online || d.conn == null || d.vehicle?.type != ride.mode) continue;
        if (d.lat == null || d.lon == null || d.locationAt == null || now.difference(d.locationAt!) > config.maxLocationAge) continue;
        if (ride.declined.contains(d.uid) || ride.offers.containsKey(d.uid)) continue;
        if (d.rideId != null && (rides[d.rideId]?.state.active ?? false)) continue;
        if (_hasOutstandingOffer(d, except: ride.id)) continue;
        final dist = distanceMeters(d.lat!, d.lon!, ride.pickup.lat, ride.pickup.lon);
        if (dist <= config.searchRadiusM) candidates.add((d, dist));
      }
      candidates.sort((a, b) => a.$2.compareTo(b.$2));
      for (final (d, dist) in candidates.take(room)) {
        ride.offers[d.uid] = now.add(config.offerTtl);
        _send(d, {
          't': T.offer,
          'rideId': ride.id,
          'pickup': ride.pickup.toJson(),
          'drop': ride.drop.toJson(),
          'mode': ride.mode.name,
          'fareRupees': ride.fareRupees,
          'distanceToPickupM': dist.round(),
          'expiresAt': ride.offers[d.uid]!.millisecondsSinceEpoch,
        });
        _log('offer', {'ride': ride.id, 'driver': d.uid, 'distance': dist.round()});
      }
    }
    ride.offerTimer?.cancel();
    final next = ride.offers.isEmpty ? config.retryInterval : ride.offers.values.map((e) => e.difference(now)).reduce((a, b) => a < b ? a : b) + const Duration(milliseconds: 20);
    ride.offerTimer = Timer(next, () => _dispatch(ride));
  }

  bool _hasOutstandingOffer(Peer driver, {String? except}) {
    final now = _clock();
    for (final r in rides.values) {
      if (r.id != except && r.state == RideState.requested && (r.offers[driver.uid]?.isAfter(now) ?? false)) return true;
    }
    return false;
  }

  void _searchExpired(Ride ride) {
    if (ride.state != RideState.requested) return;
    for (final d in ride.offers.keys.toList()) {
      final p = peers[d];
      if (p != null) _send(p, {'t': T.offerCancelled, 'rideId': ride.id, 'reason': 'search ended'});
    }
    metrics.noDrivers++;
    _finish(ride, RideState.noDrivers, 'no driver accepted in time');
  }

  void _accept(Peer driver, Ride ride) {
    final exp = ride.offers[driver.uid];
    if (ride.state != RideState.requested) throw ProtocolException(ErrorCode.conflict, 'this ride is no longer available');
    if (exp == null || !exp.isAfter(_clock())) throw ProtocolException(ErrorCode.conflict, 'the offer expired');
    if (_activeRideOf(driver) != null) throw ProtocolException(ErrorCode.conflict, 'you already have an active ride');
    ride.driverId = driver.uid;
    ride.state = RideState.assigned;
    ride.assignedAt = _clock();
    driver.rideId = ride.id;
    ride.offerTimer?.cancel();
    ride.searchTimer?.cancel();
    for (final other in ride.offers.keys.where((d) => d != driver.uid)) {
      final p = peers[other];
      if (p != null) _send(p, {'t': T.offerCancelled, 'rideId': ride.id, 'reason': 'taken by another driver'});
    }
    ride.offers.clear();
    // The driver's other outstanding offers are void now that they are busy.
    for (final r in rides.values) {
      if (r.id != ride.id && r.offers.remove(driver.uid) != null) _send(driver, {'t': T.offerCancelled, 'rideId': r.id, 'reason': 'you accepted another ride'});
    }
    _log('assigned', {'ride': ride.id, 'driver': driver.uid});
    _notifyRide(ride);
  }

  void _decline(Peer driver, Ride ride) {
    if (ride.offers.remove(driver.uid) == null) return;
    ride.declined.add(driver.uid);
    _dispatch(ride);
  }

  void _arrived(Peer driver, Ride ride) {
    _requireAssigned(driver, ride);
    if (ride.state != RideState.assigned) throw ProtocolException(ErrorCode.conflict, 'ride is ${ride.state.wire}');
    ride.state = RideState.arrived;
    _log('arrived', {'ride': ride.id});
    _notifyRide(ride);
  }

  void _start(Peer driver, Ride ride, String otp) {
    _requireAssigned(driver, ride);
    if (ride.state != RideState.arrived && ride.state != RideState.assigned) throw ProtocolException(ErrorCode.conflict, 'ride is ${ride.state.wire}');
    if (otp != ride.otp) throw ProtocolException(ErrorCode.forbidden, 'wrong OTP');
    ride.state = RideState.onTrip;
    ride.startedAt = _clock();
    _log('started', {'ride': ride.id});
    _notifyRide(ride);
  }

  void _complete(Peer driver, Ride ride) {
    _requireAssigned(driver, ride);
    if (ride.state != RideState.onTrip) throw ProtocolException(ErrorCode.conflict, 'ride is ${ride.state.wire}');
    metrics.ridesCompleted++;
    _finish(ride, RideState.completed, null);
  }

  void _cancel(Peer who, Ride ride) {
    final isRider = ride.riderId == who.uid, isDriver = ride.driverId == who.uid;
    if (!isRider && !isDriver) throw ProtocolException(ErrorCode.forbidden, 'not your ride');
    if (!ride.state.active) throw ProtocolException(ErrorCode.conflict, 'ride is already ${ride.state.wire}');
    if (ride.state == RideState.onTrip) throw ProtocolException(ErrorCode.conflict, 'a trip in progress cannot be cancelled; ask the driver to complete it');
    if (isDriver) {
      _driverLeaves(ride, who, 'driver cancelled');
    } else {
      for (final d in ride.offers.keys) {
        final p = peers[d];
        if (p != null) _send(p, {'t': T.offerCancelled, 'rideId': ride.id, 'reason': 'rider cancelled'});
      }
      metrics.ridesCancelled++;
      _finish(ride, RideState.cancelled, 'cancelled by rider');
    }
  }

  /// The assigned driver drops out: the ride goes back into the pool instead of failing.
  void _driverLeaves(Ride ride, Peer driver, String reason) {
    // Tell the leaving driver their assignment is over (the ride itself lives on for the rider).
    _send(driver, {'t': T.rideUpdate, 'ride': {..._rideJson(ride, forRider: false), 'state': RideState.cancelled.wire, 'reason': reason}});
    _endCall(ride.id, 'driver left the ride');
    driver.rideId = null;
    ride.declined.add(driver.uid);
    ride.driverId = null;
    ride.state = RideState.requested;
    ride.reason = reason;
    _log('redispatch', {'ride': ride.id, 'reason': reason});
    _notifyRide(ride);
    final remaining = config.searchTimeout - _clock().difference(ride.createdAt);
    ride.searchTimer?.cancel();
    ride.searchTimer = Timer(remaining.isNegative ? config.retryInterval : remaining, () => _searchExpired(ride));
    _dispatch(ride);
  }

  void _finish(Ride ride, RideState state, String? reason) {
    ride.state = state;
    ride.reason = reason;
    ride.completedAt = _clock();
    ride.offerTimer?.cancel();
    ride.searchTimer?.cancel();
    _endCall(ride.id, 'ride ended');
    _log('finished', {'ride': ride.id, 'state': state.wire, 'reason': reason});
    _notifyRide(ride);
    final rider = peers[ride.riderId];
    if (rider != null && rider.rideId == ride.id) rider.rideId = null;
    final driver = ride.driverId == null ? null : peers[ride.driverId];
    if (driver != null && driver.rideId == ride.id) driver.rideId = null;
  }

  // ------------------------------------------------------------------ translated conversation
  void _utterance(Peer from, Json m) {
    final ride = _ride(m);
    final peerId = ride.riderId == from.uid ? ride.driverId : (ride.driverId == from.uid ? ride.riderId : null);
    if (peerId == null && ride.riderId != from.uid && ride.driverId != from.uid) throw ProtocolException(ErrorCode.forbidden, 'not your ride');
    if (!ride.state.hasPeer || peerId == null) throw ProtocolException(ErrorCode.conflict, 'no one to talk to yet');
    final text = reqString(m, 'text', max: 2000), translated = reqString(m, 'translated', max: 2000, allowEmpty: true);
    final srcLang = reqLang(m, 'srcLang'), tgtLang = reqLang(m, 'tgtLang');
    final seq = m['seq'] is int ? m['seq'] as int : 0;
    final to = peers[peerId];
    metrics.utterances++;
    if (to != null) {
      _send(to, {'t': T.chatUtterance, 'rideId': ride.id, 'from': from.uid, 'fromRole': from.role.name, 'text': text, 'translated': translated, 'srcLang': srcLang, 'tgtLang': tgtLang, 'seq': seq, 'ts': _clock().millisecondsSinceEpoch});
    }
  }

  // ------------------------------------------------------------------ voice calls
  Peer? _counterpart(Ride ride, Peer me) {
    final id = ride.riderId == me.uid ? ride.driverId : (ride.driverId == me.uid ? ride.riderId : null);
    return id == null ? null : peers[id];
  }

  void _callStart(Peer from, Ride ride) {
    if (ride.riderId != from.uid && ride.driverId != from.uid) throw ProtocolException(ErrorCode.forbidden, 'not your ride');
    final to = _counterpart(ride, from);
    if (!ride.state.hasPeer || to == null) throw ProtocolException(ErrorCode.conflict, 'no one to call yet');
    if (calls.containsKey(ride.id)) throw ProtocolException(ErrorCode.conflict, 'a call is already in progress');
    final call = Call(ride.id, from.uid, to.uid);
    calls[ride.id] = call;
    metrics.callsStarted++;
    call.ringTimer = Timer(config.callRingTimeout, () => _endCall(ride.id, 'no answer'));
    _send(from, {'t': T.callState, 'rideId': ride.id, 'state': 'ringing'});
    _send(to, {'t': T.callIncoming, 'rideId': ride.id, 'from': from.uid, 'fromName': from.name, 'fromRole': from.role.name});
    _log('call_start', {'ride': ride.id, 'from': from.uid});
  }

  void _callAnswer(Peer me, Ride ride, {required bool accept}) {
    final call = calls[ride.id];
    if (call == null) throw ProtocolException(ErrorCode.notFound, 'no call to answer');
    if (call.calleeId != me.uid) throw ProtocolException(ErrorCode.forbidden, 'only the person being called can answer');
    if (call.active) throw ProtocolException(ErrorCode.conflict, 'the call is already connected');
    if (!accept) return _endCall(ride.id, 'declined');
    call.ringTimer?.cancel();
    call.active = true;
    call.answeredAt = _clock();
    metrics.callsAnswered++;
    for (final id in [call.callerId, call.calleeId]) {
      final p = peers[id];
      if (p != null) _send(p, {'t': T.callState, 'rideId': ride.id, 'state': 'active'});
    }
    _log('call_answered', {'ride': ride.id});
  }

  void _callEnd(Peer me, Ride ride) {
    final call = calls[ride.id];
    if (call == null) return;
    if (call.callerId != me.uid && call.calleeId != me.uid) throw ProtocolException(ErrorCode.forbidden, 'not your call');
    _endCall(ride.id, 'hung up');
  }

  void _endCall(String rideId, String reason) {
    final call = calls.remove(rideId);
    if (call == null) return;
    call.ringTimer?.cancel();
    for (final id in [call.callerId, call.calleeId]) {
      final p = peers[id];
      if (p != null) _send(p, {'t': T.callState, 'rideId': rideId, 'state': 'ended', 'reason': reason});
    }
    _log('call_end', {'ride': rideId, 'reason': reason, if (call.answeredAt != null) 'seconds': _clock().difference(call.answeredAt!).inSeconds});
  }

  /// Audio frames: forwarded only between the two parties of an answered call.
  void handleBinary(Peer from, Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxAudioFrameBytes) throw ProtocolException(ErrorCode.tooLarge, 'audio frame must be 1..$maxAudioFrameBytes bytes');
    final rideId = from.rideId;
    final call = rideId == null ? null : calls[rideId];
    if (call == null || !call.active) return; // nobody listening: drop silently
    final to = peers[call.callerId == from.uid ? call.calleeId : call.callerId];
    if (to == null || to.conn == null) return;
    metrics.audioFrames++;
    to.conn!.sendBytes(bytes);
  }

  // ------------------------------------------------------------------ helpers
  Ride _ride(Json m) {
    final r = rides[reqString(m, 'rideId', max: 40)];
    if (r == null) throw ProtocolException(ErrorCode.notFound, 'unknown ride');
    return r;
  }

  void _requireRole(Peer p, Role role) {
    if (p.role != role) throw ProtocolException(ErrorCode.forbidden, 'only ${role.name}s can do this');
  }

  void _requireAssigned(Peer driver, Ride ride) {
    if (ride.driverId != driver.uid) throw ProtocolException(ErrorCode.forbidden, 'you are not the driver of this ride');
  }

  Ride? _activeRideOf(Peer p) {
    final id = p.rideId;
    if (id == null) return null;
    final r = rides[id];
    return (r != null && r.state.active) ? r : null;
  }

  Json _rideJson(Ride r, {required bool forRider}) {
    final driver = r.driverId == null ? null : peers[r.driverId];
    final rider = peers[r.riderId];
    return {
      'id': r.id,
      'state': r.state.wire,
      'pickup': r.pickup.toJson(),
      'drop': r.drop.toJson(),
      'mode': r.mode.name,
      'fareRupees': r.fareRupees,
      if (forRider) 'otp': r.otp,
      if (r.reason != null) 'reason': r.reason,
      if (driver != null) 'driver': {'id': driver.uid, 'name': driver.name, 'lang': driver.lang, 'vehicle': driver.vehicle?.toJson(), if (driver.lat != null) 'lat': driver.lat, if (driver.lon != null) 'lon': driver.lon},
      if (rider != null) 'rider': {'id': rider.uid, 'name': rider.name, 'lang': rider.lang},
    };
  }

  void _notifyRide(Ride ride, {Json extra = const {}}) {
    final rider = peers[ride.riderId];
    if (rider != null) _send(rider, {'t': T.rideUpdate, 'ride': _rideJson(ride, forRider: true), ...extra});
    final driver = ride.driverId == null ? null : peers[ride.driverId];
    if (driver != null) _send(driver, {'t': T.rideUpdate, 'ride': _rideJson(ride, forRider: false), ...extra});
  }

  void _send(Peer p, Json m) => p.conn?.send(m);

  /// Tells a driver that a ride they were assigned was released (cancelled by the rider).
  void sendError(Peer p, ProtocolException e, {Object? ref}) {
    metrics.errors++;
    _send(p, {'t': T.error, 'code': e.code, 'message': e.message, if (ref != null) 'ref': ref});
  }
}
