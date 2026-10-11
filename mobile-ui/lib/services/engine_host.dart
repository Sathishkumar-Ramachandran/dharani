import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../core/native_bridge.dart';
import 'overpass_service.dart';

/// Describes the road network currently loaded into the native router.
class RegionInfo {
  const RegionInfo({required this.bounds, required this.nodes, required this.edges, required this.demo, this.builtAt});
  final RegionBounds bounds;
  final int nodes, edges;
  final bool demo;
  final DateTime? builtAt;

  factory RegionInfo.fromJson(Map<String, dynamic> j) => RegionInfo(
        bounds: RegionBounds.fromJson(j),
        nodes: (j['nodes'] as num?)?.toInt() ?? 0,
        edges: (j['edges'] as num?)?.toInt() ?? 0,
        demo: j['demo'] as bool? ?? false,
        builtAt: DateTime.tryParse(j['built_at'] as String? ?? ''),
      );
}

/// Owns the native engine for the whole app: initialisation, the installed road region, and the
/// rule that only one attested session (freight trip or ride) runs at a time.
class EngineHost {
  EngineHost({DharaniNative? native, this.storageOverride}) : _nativeOverride = native;

  final DharaniNative? _nativeOverride;
  final String? storageOverride;

  late final DharaniNative native;
  late final String dir;
  String vehicleId = '';
  String publicKeyHex = '';
  String version = '';
  RegionInfo? region;
  bool _ready = false;
  String? _owner;

  bool get ready => _ready;

  Future<void> init() async {
    if (_ready) return;
    dir = storageOverride ?? (await getApplicationSupportDirectory()).path;
    await Directory(dir).create(recursive: true);
    native = _nativeOverride ?? DharaniNative.open();
    native.initialize(dir);
    final id = native.identity();
    vehicleId = id.vehicleId;
    publicKeyHex = id.publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    version = native.version;
    region = await readRegion();
    _ready = true;
  }

  Future<RegionInfo?> readRegion() async {
    final f = File('$dir/region.json');
    if (!await f.exists() || !await File('$dir/road_graph.json').exists()) return null;
    try {
      return RegionInfo.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Called after a region download wrote a fresh road_graph.json.
  Future<void> reloadGraph() async {
    native.loadGraph('$dir/road_graph.json');
    region = await readRegion();
  }

  /// Installs the bundled synthetic Bengaluru–Krishnagiri corridor (demos and tests).
  Future<void> installDemoGraph() async {
    final text = await rootBundle.loadString('assets/road_graph.json');
    await File('$dir/road_graph.json').writeAsString(text, flush: true);
    await File('$dir/region.json').writeAsString(
        jsonEncode({'south': 12.50, 'west': 77.60, 'north': 12.95, 'east': 78.25, 'nodes': 0, 'edges': 0, 'demo': true}),
        flush: true);
    await reloadGraph();
  }

  /// Only one attested session may use the engine's tamper filter at a time.
  bool claim(String owner) {
    if (_owner != null && _owner != owner) return false;
    _owner = owner;
    return true;
  }

  void release(String owner) {
    if (_owner == owner) _owner = null;
  }

  String? get activeOwner => _owner;

  void shutdown() {
    if (!_ready) return;
    try {
      native.shutdown();
    } catch (_) {}
    _ready = false;
  }
}
