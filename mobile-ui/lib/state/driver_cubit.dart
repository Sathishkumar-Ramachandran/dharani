import 'dart:async';

import 'package:dharani_protocol/dharani_protocol.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/geo.dart';
import '../core/native_bridge.dart';
import '../net/dharani_client.dart' show ConnState;
import '../net/remote_models.dart';
import '../services/engine_host.dart';
import 'location_cubit.dart';
import 'session_cubit.dart';
import '../services/stay_reachable.dart';

class DriverState {
  const DriverState({this.online = false, this.offer, this.ride, this.route = const [], this.remainingM = 0, this.etaS = 0, this.message, this.error, this.otpWrong = false});
  final bool online;
  final RideOffer? offer;
  final RemoteRide? ride;
  final List<({double lat, double lon})> route;
  final double remainingM, etaS;
  final String? message, error;
  final bool otpWrong;

  DriverState copyWith({bool? online, RideOffer? offer, RemoteRide? ride, List<({double lat, double lon})>? route, double? remainingM, double? etaS, String? message, String? error, bool? otpWrong, bool clearOffer = false, bool clearRide = false, bool clearError = false, bool clearMessage = false}) => DriverState(
        online: online ?? this.online,
        offer: clearOffer ? null : (offer ?? this.offer),
        ride: clearRide ? null : (ride ?? this.ride),
        route: clearRide ? const [] : (route ?? this.route),
        remainingM: remainingM ?? this.remainingM,
        etaS: etaS ?? this.etaS,
        message: clearMessage ? null : (message ?? this.message),
        error: clearError ? null : (error ?? this.error),
        otpWrong: otpWrong ?? this.otpWrong,
      );
}

/// The driver's side: availability, incoming offers, the active ride and live location reporting.
class DriverCubit extends Cubit<DriverState> {
  DriverCubit({required this.session, required this.location, this.host, this.locationInterval = const Duration(seconds: 1)}) : super(const DriverState()) {
    _msgSub = session.messages.listen(_onMessage);
    _connSub = session.stream.listen((s) {
      // After a reconnect the server re-sends `welcome`; re-assert availability there.
      if (!s.connected) emit(state.copyWith(message: s.conn == ConnState.reconnecting ? 'Reconnecting…' : null));
    });
    _locSub = location.stream.listen(_onFix);
  }

  final SessionCubit session;
  final LocationCubit location;
  final EngineHost? host;
  final Duration locationInterval;
  late final StreamSubscription<Json> _msgSub;
  late final StreamSubscription<SessionState> _connSub;
  late final StreamSubscription<LocationState> _locSub;
  Timer? _offerTimer;
  DateTime _lastSent = DateTime.fromMillisecondsSinceEpoch(0);
  String? _routedFor; // ride id + state the current route was computed for

  VehicleType? get _vehicle => session.state.profile?.vehicle?.type;

  // ------------------------------------------------------------ actions
  void goOnline(bool online) {
    if (!session.state.connected) {
      emit(state.copyWith(error: 'Not connected to the server.'));
      return;
    }
    session.send({'t': T.driverOnline, 'online': online});
    emit(state.copyWith(online: online, clearError: true, clearOffer: !online));
    // While online the phone must keep reporting even with the screen off: foreground location service.
    location.setBackground(online);
    if (online) {
      StayReachable.hold('driver', text: 'Online · waiting for ride requests');
      StayReachable.ensureBatteryExempt();
    } else {
      StayReachable.release('driver');
    }
    if (online) _sendLocation(force: true);
  }

  void accept() {
    final o = state.offer;
    if (o == null) return;
    StayReachable.clearAlert();
    session.send({'t': T.offerAccept, 'rideId': o.rideId});
    emit(state.copyWith(message: 'Accepting…'));
  }

  void decline() {
    final o = state.offer;
    if (o == null) return;
    StayReachable.clearAlert();
    session.send({'t': T.offerDecline, 'rideId': o.rideId});
    _offerTimer?.cancel();
    emit(state.copyWith(clearOffer: true, clearMessage: true));
  }

  void arrived() => _rideAction(T.rideArrived);
  void complete() => _rideAction(T.rideComplete);

  void start(String otp) {
    final r = state.ride;
    if (r == null) return;
    emit(state.copyWith(otpWrong: false, clearError: true));
    session.send({'t': T.rideStart, 'rideId': r.id, 'otp': otp.trim()});
  }

  void cancelRide() => _rideAction(T.rideCancel);

  void _rideAction(String type) {
    final r = state.ride;
    if (r == null) return;
    session.send({'t': type, 'rideId': r.id});
  }

  // ------------------------------------------------------------ server frames
  void _onMessage(Json m) {
    switch (m['t']) {
      case T.welcome:
        final ride = m['ride'];
        final online = m['online'] == true;
        // The server forgets availability when it restarts; keep what the driver chose.
        if (state.online && !online) session.send({'t': T.driverOnline, 'online': true});
        if (ride is Map<String, dynamic>) _applyRide(RemoteRide.fromJson(ride));
        emit(state.copyWith(online: state.online || online, clearError: true));
      case T.offer:
        final o = RideOffer.fromJson(m);
        if (state.ride != null) return; // busy
        _offerTimer?.cancel();
        _offerTimer = Timer(o.expiresAt.difference(DateTime.now()), () {
          if (state.offer?.rideId == o.rideId) {
            StayReachable.clearAlert();
            emit(state.copyWith(clearOffer: true, message: 'Offer expired'));
          }
        });
        emit(state.copyWith(offer: o, clearError: true, clearMessage: true));
        // Screen off / another app in front: wake the phone and open the app on the offer.
        StayReachable.alert('New ride request', 'Tap to see pickup, drop and fare');
      case T.offerCancelled:
        StayReachable.clearAlert();
        if (state.offer?.rideId == m['rideId']) {
          _offerTimer?.cancel();
          emit(state.copyWith(clearOffer: true, message: m['reason'] as String?));
        }
      case T.rideUpdate:
        _applyRide(RemoteRide.fromJson(m['ride'] as Json));
      case T.error:
        final text = friendlyError(m);
        emit(state.copyWith(error: text, otpWrong: text.toLowerCase().contains('otp'), clearMessage: true));
    }
  }

  void _applyRide(RemoteRide r) {
    if (r.state == RideState.requested) {
      // The ride was released (e.g. we cancelled): back to idle.
      if (state.ride?.id == r.id) emit(state.copyWith(clearRide: true, message: 'Ride released'));
      return;
    }
    if (!r.active) {
      emit(state.copyWith(clearRide: true, message: switch (r.state) {
        RideState.completed => 'Ride completed · ₹${r.fareRupees}',
        RideState.cancelled => 'Ride cancelled${r.reason == null ? '' : ': ${r.reason}'}',
        _ => 'Ride ended',
      }));
      return;
    }
    _offerTimer?.cancel();
    emit(state.copyWith(ride: r, clearOffer: true, clearError: true, clearMessage: true));
    _route(r);
  }

  /// Guidance: to the pickup until the trip starts, then to the drop-off.
  void _route(RemoteRide r) {
    final fix = location.state.fix;
    final h = host;
    final key = '${r.id}:${r.state == RideState.onTrip}';
    if (fix == null || h == null || !h.ready || _routedFor == key) return;
    final target = r.state == RideState.onTrip ? r.drop : r.pickup;
    try {
      final route = h.native.calculateRoute(startLat: fix.lat, startLon: fix.lon, destLat: target.lat, destLon: target.lon, costing: _vehicle == VehicleType.bike ? 2 : 0);
      _routedFor = key;
      emit(state.copyWith(route: route.polyline, remainingM: route.distanceM, etaS: route.durationS));
    } on DharaniException {
      // No road data for this area: the straight-line distance in _onFix still works.
    }
  }

  // ------------------------------------------------------------ location
  void _onFix(LocationState s) {
    final fix = s.fix;
    if (fix == null) return;
    final r = state.ride;
    if (r != null) {
      final target = r.state == RideState.onTrip ? r.drop : r.pickup;
      final d = haversineMeters(fix.lat, fix.lon, target.lat, target.lon);
      emit(state.copyWith(remainingM: d, etaS: d / (fix.speedMps > 2 ? fix.speedMps : 8)));
      _route(r);
    }
    if (state.online || r != null) _sendLocation();
  }

  void _sendLocation({bool force = false}) {
    final fix = location.state.fix;
    if (fix == null || !session.state.connected) return;
    final now = DateTime.now();
    if (!force && now.difference(_lastSent) < locationInterval) return;
    _lastSent = now;
    session.send({'t': T.driverLocation, 'lat': fix.lat, 'lon': fix.lon, 'heading': fix.headingDeg, 'speed': fix.speedMps, 'accuracy': fix.accuracyM, 'tamper': fix.mocked});
  }

  @override
  Future<void> close() async {
    _offerTimer?.cancel();
    await _msgSub.cancel();
    await _connSub.cancel();
    await _locSub.cancel();
    return super.close();
  }
}
