/// Wire protocol shared by the Dharani apps and the Dharani server.
///
/// Transport: WebSocket carrying one JSON object per text frame, always with a `t` (type) field.
/// Authentication: `POST /v1/register` returns a signed token; the socket is opened at
/// `/v1/ws?token=<token>`. The first client frame must be `hello`.
library;

import 'dart:math' as math;

const int protocolVersion = 1;

/// LAN discovery: a phone broadcasts [discoveryProbe] over UDP to this port; the server answers the
/// sender with JSON {"dharani":"server","protocol":N,"port":P,"tls":bool}. No configuration needed.
const int discoveryPort = 47998;
const String discoveryProbe = 'dharani.discover.v1';
const int maxFrameBytes = 64 * 1024;

/// Voice: binary WebSocket frames, PCM16 little-endian mono at [audioSampleRate], [audioFrameBytes] per 20 ms.
const int audioSampleRate = 16000;
const int audioFrameBytes = 640;
const int maxAudioFrameBytes = 4096;

typedef Json = Map<String, dynamic>;

/// Message types.
class T {
  // client -> server
  static const hello = 'hello';
  static const ping = 'ping';
  static const driverOnline = 'driver.online';
  static const driverLocation = 'driver.location';
  static const rideRequest = 'ride.request';
  static const rideCancel = 'ride.cancel';
  static const offerAccept = 'offer.accept';
  static const offerDecline = 'offer.decline';
  static const rideArrived = 'ride.arrived';
  static const rideStart = 'ride.start';
  static const rideComplete = 'ride.complete';
  static const chatUtterance = 'chat.utterance';
  static const callStart = 'call.start';
  static const callAccept = 'call.accept';
  static const callDecline = 'call.decline';
  static const callEnd = 'call.end';
  static const setLang = 'profile.lang';
  // server -> client
  static const welcome = 'welcome';
  static const pong = 'pong';
  static const error = 'error';
  static const offer = 'offer';
  static const offerCancelled = 'offer.cancelled';
  static const rideUpdate = 'ride.update';
  static const peerLocation = 'peer.location';
  static const peerLang = 'peer.lang';
  static const callIncoming = 'call.incoming';
  static const callState = 'call.state';
}

enum Role { rider, driver }

enum VehicleType { auto, cab, bike }

enum RideState { requested, assigned, arrived, onTrip, completed, cancelled, noDrivers }

extension RideStateWire on RideState {
  String get wire => switch (this) {
        RideState.requested => 'REQUESTED',
        RideState.assigned => 'ASSIGNED',
        RideState.arrived => 'ARRIVED',
        RideState.onTrip => 'ON_TRIP',
        RideState.completed => 'COMPLETED',
        RideState.cancelled => 'CANCELLED',
        RideState.noDrivers => 'NO_DRIVERS',
      };

  bool get active => this == RideState.requested || this == RideState.assigned || this == RideState.arrived || this == RideState.onTrip;
  bool get hasPeer => this == RideState.assigned || this == RideState.arrived || this == RideState.onTrip;

  static RideState parse(String s) => RideState.values.firstWhere((v) => v.wire == s, orElse: () => throw FormatException('bad ride state $s'));
}

/// Error codes sent in `error` frames.
class ErrorCode {
  static const badRequest = 'bad_request';
  static const unauthorized = 'unauthorized';
  static const forbidden = 'forbidden';
  static const notFound = 'not_found';
  static const conflict = 'conflict';
  static const rateLimited = 'rate_limited';
  static const tooLarge = 'too_large';
  static const protocol = 'protocol';
}

class ProtocolException implements Exception {
  ProtocolException(this.code, this.message);
  final String code, message;
  @override
  String toString() => '$code: $message';
}

class Place {
  const Place(this.name, this.lat, this.lon);
  final String name;
  final double lat, lon;

  Json toJson() => {'name': name, 'lat': lat, 'lon': lon};

  factory Place.fromJson(Object? j, String field) {
    if (j is! Map) throw ProtocolException(ErrorCode.badRequest, '$field must be an object');
    final lat = j['lat'], lon = j['lon'];
    if (lat is! num || lon is! num || !validCoordinate(lat.toDouble(), lon.toDouble())) {
      throw ProtocolException(ErrorCode.badRequest, '$field has invalid coordinates');
    }
    final name = j['name'];
    return Place(name is String ? (name.length > 120 ? name.substring(0, 120) : name) : '', lat.toDouble(), lon.toDouble());
  }
}

bool validCoordinate(double lat, double lon) => lat.isFinite && lon.isFinite && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180 && !(lat == 0 && lon == 0);

double distanceMeters(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * 6371000.0 * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// Supported speech languages (BCP-47 base codes).
const supportedLanguages = {'en', 'hi', 'ta', 'te', 'kn', 'mr', 'bn', 'gu', 'ur', 'fr'};

// ---- field readers used by the server to validate untrusted frames ----
String reqString(Json m, String k, {int max = 200, bool allowEmpty = false}) {
  final v = m[k];
  if (v is! String || (!allowEmpty && v.isEmpty) || v.length > max) throw ProtocolException(ErrorCode.badRequest, 'field "$k" must be a string of 1..$max characters');
  return v;
}

double reqNum(Json m, String k, {double? min, double? max}) {
  final v = m[k];
  if (v is! num || !v.toDouble().isFinite) throw ProtocolException(ErrorCode.badRequest, 'field "$k" must be a number');
  final d = v.toDouble();
  if ((min != null && d < min) || (max != null && d > max)) throw ProtocolException(ErrorCode.badRequest, 'field "$k" out of range');
  return d;
}

bool reqBool(Json m, String k) {
  final v = m[k];
  if (v is! bool) throw ProtocolException(ErrorCode.badRequest, 'field "$k" must be a boolean');
  return v;
}

T0 reqEnum<T0 extends Enum>(Json m, String k, List<T0> values) {
  final v = m[k];
  for (final e in values) {
    if (e.name == v) return e;
  }
  throw ProtocolException(ErrorCode.badRequest, 'field "$k" must be one of ${values.map((e) => e.name).join(', ')}');
}

String reqLang(Json m, String k) {
  final v = reqString(m, k, max: 8);
  if (!supportedLanguages.contains(v)) throw ProtocolException(ErrorCode.badRequest, 'unsupported language "$v"');
  return v;
}
