import 'dart:convert';
import 'dart:io';

import 'package:dharani_mobile/services/overpass_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('overpass response becomes a routable graph with OSM restrictions', () {
    final r = buildRoadGraph(File('test/fixtures/overpass_sample.json').readAsStringSync());
    expect(r.nodes, 5);
    expect(r.edges, 4); // 2 + 1 + 1; footway and private service road are skipped
    final g = jsonDecode(r.json) as Map<String, dynamic>;
    final edges = (g['edges'] as List).cast<Map<String, dynamic>>();
    expect(edges[0]['name'], 'NH 48');
    expect(edges[0]['speed_kph'], 60);
    expect(edges[0]['toll'], isTrue);
    expect(edges[2]['truck'], isFalse);
    expect(edges[2]['oneway'], isTrue);
    expect(edges[3]['max_height_m'], 4.5);
    expect(edges[3]['two_wheeler'], isFalse); // motorway
    expect(edges[3]['oneway'], isTrue);
  });

  test('region bounds and query', () {
    final b = RegionBounds.around(12.9, 77.6, 10);
    expect(b.contains(12.9, 77.6), isTrue);
    expect(b.contains(13.5, 77.6), isFalse);
    expect(b.north - b.south, closeTo(0.1808, 0.002));
    expect(b.east - b.west, closeTo(0.1843, 0.002));
    expect(OverpassService.query(b), contains('residential'));
    expect(OverpassService.query(RegionBounds.around(12.9, 77.6, 60)), isNot(contains('residential')));
  });
}
