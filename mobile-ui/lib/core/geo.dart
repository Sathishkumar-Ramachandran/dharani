import 'dart:math' as math;

double haversineMeters(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final h = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// Point `meters` from (lat, lon) along `bearingDeg`.
({double lat, double lon}) offsetPoint(double lat, double lon, double bearingDeg, double meters) {
  final b = bearingDeg * math.pi / 180;
  final dLat = meters * math.cos(b) / 110574.0;
  final dLon = meters * math.sin(b) / (111320.0 * math.cos(lat * math.pi / 180));
  return (lat: lat + dLat, lon: lon + dLon);
}
