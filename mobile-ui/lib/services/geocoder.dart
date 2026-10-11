import 'dart:convert';

import 'package:http/http.dart' as http;

class GeoResult {
  const GeoResult(this.name, this.lat, this.lon);
  final String name;
  final double lat, lon;
}

/// Place search through OpenStreetMap Nominatim (needs internet; routing itself does not).
class Geocoder {
  Geocoder({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;

  Future<List<GeoResult>> search(String query, {double? nearLat, double? nearLon}) async {
    final q = query.trim();
    if (q.length < 3) return const [];
    final params = {
      'q': q,
      'format': 'jsonv2',
      'limit': '6',
      if (nearLat != null && nearLon != null)
        'viewbox': '${nearLon - 0.6},${nearLat + 0.6},${nearLon + 0.6},${nearLat - 0.6}',
    };
    final res = await _client
        .get(Uri.https('nominatim.openstreetmap.org', '/search', params), headers: {'User-Agent': 'DharaniMobile/0.3'})
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('Search failed (${res.statusCode})');
    return [
      for (final r in jsonDecode(res.body) as List)
        GeoResult(r['display_name'] as String, double.parse(r['lat'] as String), double.parse(r['lon'] as String))
    ];
  }
}
