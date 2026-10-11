import 'package:dharani_protocol/dharani_protocol.dart';

class PartyInfo {
  const PartyInfo({required this.id, required this.name, required this.lang, this.plate, this.model, this.vehicle, this.lat, this.lon});
  final String id, name, lang;
  final String? plate, model;
  final VehicleType? vehicle;
  final double? lat, lon;

  factory PartyInfo.fromJson(Json j) {
    final v = j['vehicle'] as Map<String, dynamic>?;
    return PartyInfo(
      id: j['id'] as String,
      name: (j['name'] as String?) ?? '',
      lang: (j['lang'] as String?) ?? 'en',
      plate: v?['plate'] as String?,
      model: v?['model'] as String?,
      vehicle: v == null ? null : VehicleType.values.firstWhere((t) => t.name == v['type'], orElse: () => VehicleType.cab),
      lat: (j['lat'] as num?)?.toDouble(),
      lon: (j['lon'] as num?)?.toDouble(),
    );
  }
}

/// A ride as the server describes it to this client.
class RemoteRide {
  const RemoteRide({required this.id, required this.state, required this.pickup, required this.drop, required this.mode, required this.fareRupees, this.otp, this.reason, this.driver, this.rider});
  final String id;
  final RideState state;
  final Place pickup, drop;
  final VehicleType mode;
  final int fareRupees;
  final String? otp, reason;
  final PartyInfo? driver, rider;

  bool get active => state.active;

  factory RemoteRide.fromJson(Json j) => RemoteRide(
        id: j['id'] as String,
        state: RideStateWire.parse(j['state'] as String),
        pickup: Place.fromJson(j['pickup'], 'pickup'),
        drop: Place.fromJson(j['drop'], 'drop'),
        mode: VehicleType.values.firstWhere((t) => t.name == j['mode']),
        fareRupees: (j['fareRupees'] as num).toInt(),
        otp: j['otp'] as String?,
        reason: j['reason'] as String?,
        driver: j['driver'] == null ? null : PartyInfo.fromJson(j['driver'] as Json),
        rider: j['rider'] == null ? null : PartyInfo.fromJson(j['rider'] as Json),
      );
}

class RideOffer {
  const RideOffer({required this.rideId, required this.pickup, required this.drop, required this.mode, required this.fareRupees, required this.distanceToPickupM, required this.expiresAt});
  final String rideId;
  final Place pickup, drop;
  final VehicleType mode;
  final int fareRupees, distanceToPickupM;
  final DateTime expiresAt;

  factory RideOffer.fromJson(Json j) => RideOffer(
        rideId: j['rideId'] as String,
        pickup: Place.fromJson(j['pickup'], 'pickup'),
        drop: Place.fromJson(j['drop'], 'drop'),
        mode: VehicleType.values.firstWhere((t) => t.name == j['mode']),
        fareRupees: (j['fareRupees'] as num).toInt(),
        distanceToPickupM: (j['distanceToPickupM'] as num).toInt(),
        expiresAt: DateTime.fromMillisecondsSinceEpoch((j['expiresAt'] as num).toInt()),
      );
}

String friendlyError(Json m) {
  final msg = (m['message'] as String?) ?? 'Something went wrong.';
  return switch (m['code']) {
    ErrorCode.conflict => msg,
    ErrorCode.rateLimited => 'Too many actions in a row. Wait a moment.',
    ErrorCode.forbidden => msg,
    _ => msg,
  };
}
