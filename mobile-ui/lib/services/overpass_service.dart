import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Geographic rectangle of an offline road region.
class RegionBounds {
  const RegionBounds(this.south, this.west, this.north, this.east);
  final double south, west, north, east;

  factory RegionBounds.around(double lat, double lon, double radiusKm) {
    final dLat = radiusKm / 110.574;
    final dLon = radiusKm / (111.320 * _cosDeg(lat));
    return RegionBounds(lat - dLat, lon - dLon, lat + dLat, lon + dLon);
  }

  static double _cosDeg(double d) => math.max(0.0175, math.cos(d * math.pi / 180));

  bool contains(double lat, double lon) => lat >= south && lat <= north && lon >= west && lon <= east;
  double get spanDeg => (north - south) > (east - west) ? (north - south) : (east - west);

  Map<String, dynamic> toJson() => {'south': south, 'west': west, 'north': north, 'east': east};
  factory RegionBounds.fromJson(Map<String, dynamic> j) => RegionBounds((j['south'] as num).toDouble(),
      (j['west'] as num).toDouble(), (j['north'] as num).toDouble(), (j['east'] as num).toDouble());
}

class GraphBuildResult {
  const GraphBuildResult(this.json, this.nodes, this.edges);
  final String json;
  final int nodes, edges;
}

/// Converts an Overpass `out body` response into the road_graph.json format used by the native
/// router. Pure and synchronous so it can run in an isolate (and be unit tested).
GraphBuildResult buildRoadGraph(String overpassJson) {
  final data = jsonDecode(overpassJson) as Map<String, dynamic>;
  final coords = <int, (double, double)>{};
  final ways = <Map<String, dynamic>>[];
  for (final e in data['elements'] as List) {
    final m = e as Map<String, dynamic>;
    if (m['type'] == 'node') {
      coords[m['id'] as int] = ((m['lat'] as num).toDouble(), (m['lon'] as num).toDouble());
    } else if (m['type'] == 'way') {
      ways.add(m);
    }
  }

  double num0(Object? v) {
    if (v == null) return 0;
    final m = RegExp(r'[0-9]+(\.[0-9]+)?').firstMatch(v.toString());
    if (m == null) return 0;
    var x = double.parse(m.group(0)!);
    final s = v.toString();
    if (s.contains('mph')) x *= 1.609;
    return x;
  }

  const defaultSpeed = {
    'motorway': 80.0, 'motorway_link': 50.0, 'trunk': 70.0, 'trunk_link': 45.0, 'primary': 55.0,
    'primary_link': 40.0, 'secondary': 45.0, 'secondary_link': 35.0, 'tertiary': 40.0, 'tertiary_link': 30.0,
    'unclassified': 30.0, 'residential': 25.0, 'living_street': 15.0, 'service': 15.0,
  };

  final index = <int, int>{};
  final nodeLat = <double>[], nodeLon = <double>[];
  int nid(int osmId) {
    final existing = index[osmId];
    if (existing != null) return existing;
    final c = coords[osmId]!;
    nodeLat.add(c.$1);
    nodeLon.add(c.$2);
    return index[osmId] = nodeLat.length - 1;
  }

  final edges = StringBuffer();
  var edgeCount = 0;
  for (final w in ways) {
    final tags = (w['tags'] as Map<String, dynamic>?) ?? const {};
    final hw = tags['highway'] as String? ?? '';
    if (!defaultSpeed.containsKey(hw)) continue;
    if (tags['access'] == 'no' || tags['access'] == 'private') continue;
    final speed = num0(tags['maxspeed']) > 0 ? num0(tags['maxspeed']) : defaultSpeed[hw]!;
    final name = (tags['ref'] ?? tags['name'] ?? '').toString();
    final oneway = tags['oneway'] == 'yes' || tags['oneway'] == '1' || hw.startsWith('motorway') || tags['junction'] == 'roundabout';
    final toll = tags['toll'] == 'yes';
    final truckOk = tags['hgv'] != 'no' && hw != 'living_street';
    final twoWheelerOk = !(hw == 'motorway' || hw == 'motorway_link') && tags['motorcycle'] != 'no';
    final maxHeight = num0(tags['maxheight']);
    final maxWeight = num0(tags['maxweight']);
    final props = StringBuffer(',"speed_kph":${speed.round()}');
    if (name.isNotEmpty) props.write(',"name":${jsonEncode(name)}');
    if (oneway) props.write(',"oneway":true');
    if (toll) props.write(',"toll":true');
    if (!truckOk) props.write(',"truck":false');
    if (!twoWheelerOk) props.write(',"two_wheeler":false');
    if (maxHeight > 0) props.write(',"max_height_m":$maxHeight');
    if (maxWeight > 0) props.write(',"max_weight_t":$maxWeight');
    final p = props.toString();

    final refs = (w['nodes'] as List).cast<int>();
    for (var i = 0; i + 1 < refs.length; i++) {
      final a = refs[i], b = refs[i + 1];
      if (a == b || !coords.containsKey(a) || !coords.containsKey(b)) continue;
      if (edgeCount > 0) edges.write(',');
      edges.write('{"a":${nid(a)},"b":${nid(b)}$p}');
      edgeCount++;
    }
  }

  final nodes = StringBuffer();
  for (var i = 0; i < nodeLat.length; i++) {
    if (i > 0) nodes.write(',');
    nodes.write('[${nodeLat[i].toStringAsFixed(6)},${nodeLon[i].toStringAsFixed(6)}]');
  }
  return GraphBuildResult('{"format":"dharani-road-graph/1","nodes":[$nodes],"edges":[$edges]}', nodeLat.length, edgeCount);
}

class OverpassException implements Exception {
  OverpassException(this.message);
  final String message;
  @override
  String toString() => message;
}

class OverpassService {
  OverpassService({http.Client? client, this.endpoint = 'https://overpass-api.de/api/interpreter'})
      : _client = client ?? http.Client();

  final http.Client _client;
  final String endpoint;

  /// Larger regions skip minor streets so the graph stays small enough for a phone.
  static String query(RegionBounds b) {
    final minor = b.spanDeg <= 0.25 ? '|unclassified|residential|living_street' : '';
    final bbox = '${b.south},${b.west},${b.north},${b.east}';
    return '[out:json][timeout:120];'
        '(way["highway"~"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link$minor)\$"]($bbox););'
        'out body;>;out skel qt;';
  }

  /// Downloads the region and writes `road_graph.json` + `region.json` into `dir`.
  Future<GraphBuildResult> downloadRegion(RegionBounds b, String dir, {void Function(String stage)? onStage}) async {
    onStage?.call('Downloading roads…');
    final http.Response res;
    try {
      res = await _client
          .post(Uri.parse(endpoint), headers: {'User-Agent': 'DharaniMobile/0.3 (offline routing)'}, body: {'data': query(b)})
          .timeout(const Duration(seconds: 150));
    } on SocketException {
      throw OverpassException('No internet connection. Connect once to download roads for this area.');
    } on http.ClientException catch (e) {
      throw OverpassException('Download failed: ${e.message}');
    }
    if (res.statusCode == 429 || res.statusCode == 504) {
      throw OverpassException('The map server is busy. Try again in a minute.');
    }
    if (res.statusCode != 200) throw OverpassException('Map server error ${res.statusCode}.');

    onStage?.call('Building offline routing graph…');
    final result = await compute(buildRoadGraph, utf8.decode(res.bodyBytes));
    if (result.edges == 0) throw OverpassException('No drivable roads were found in this area.');

    final tmp = File('$dir/road_graph.json.tmp');
    await tmp.writeAsString(result.json, flush: true);
    await tmp.rename('$dir/road_graph.json');
    await File('$dir/region.json').writeAsString(
        jsonEncode({...b.toJson(), 'nodes': result.nodes, 'edges': result.edges, 'built_at': DateTime.now().toIso8601String()}),
        flush: true);
    return result;
  }
}
