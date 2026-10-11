import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/hazard.dart';
import '../../models/telemetry_node.dart';
import '../../services/location_service.dart';
import '../../services/overpass_service.dart';
import '../theme.dart';

class MapPin {
  const MapPin(this.point, this.color, this.icon, {this.label});
  final LatLng point;
  final Color color;
  final IconData icon;
  final String? label;
}

/// OpenStreetMap tiles with the live GPS dot, the planned route, the (interpolated) vehicle,
/// hazards and the extent of the installed offline road region.
class DharaniMap extends StatefulWidget {
  const DharaniMap({
    super.key,
    required this.controller,
    this.route = const [],
    this.vehicle,
    this.vehicleIcon = Icons.navigation,
    this.user,
    this.pins = const [],
    this.hazards = const [],
    this.tolls = const [],
    this.coverage,
    this.follow = false,
    this.onLongPress,
    this.onUserGesture,
    this.bottomInset = 0,
  });

  final MapController controller;
  final List<LatLng> route;
  final TelemetryNode? vehicle;
  final IconData vehicleIcon;
  final UserFix? user;
  final List<MapPin> pins;
  final List<RoadHazard> hazards;
  final List<LatLng> tolls;
  final RegionBounds? coverage;
  final bool follow;
  final void Function(LatLng)? onLongPress;
  final VoidCallback? onUserGesture;
  final double bottomInset; // keeps attribution above the bottom sheet

  @override
  State<DharaniMap> createState() => _DharaniMapState();
}

class _DharaniMapState extends State<DharaniMap> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 950));
  _Fix? _from, _to;
  bool _centeredOnUser = false;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    _anim.addListener(_followVehicle);
    _setTarget(widget.vehicle, initial: true);
  }

  @override
  void didUpdateWidget(DharaniMap old) {
    super.didUpdateWidget(old);
    if (!identical(old.vehicle, widget.vehicle)) _setTarget(widget.vehicle);
    if (widget.user != null && !_centeredOnUser && _mapReady && widget.vehicle == null) {
      _centeredOnUser = true;
      widget.controller.move(LatLng(widget.user!.lat, widget.user!.lon), 15);
    }
  }

  void _setTarget(TelemetryNode? n, {bool initial = false}) {
    if (n == null) {
      _from = _to = null;
      return;
    }
    final target = _Fix(n.snappedLatitude, n.snappedLongitude, n.headingDeg);
    if (_to == null || initial) {
      _from = _to = target;
    } else {
      _from = _current();
      _to = target;
    }
    _anim.forward(from: 0);
  }

  _Fix? _current() {
    final a = _from, b = _to;
    if (a == null || b == null) return b;
    final t = _anim.value;
    final dh = ((b.heading - a.heading + 540) % 360) - 180;
    return _Fix(a.lat + (b.lat - a.lat) * t, a.lon + (b.lon - a.lon) * t, (a.heading + dh * t + 360) % 360);
  }

  void _followVehicle() {
    if (!widget.follow || !_mapReady) return;
    final c = _current();
    if (c == null) return;
    widget.controller.move(LatLng(c.lat, c.lon), widget.controller.camera.zoom);
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  static const _hazardColors = {
    HazardKind.pothole: Color(0xFFD97706),
    HazardKind.congestion: Color(0xFFDC2626),
    HazardKind.blackIce: Color(0xFF0284C7),
    HazardKind.detour: Color(0xFF9333EA),
    HazardKind.stalledVehicle: Color(0xFFEA580C),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final user = widget.user;
    final initial = user != null ? LatLng(user.lat, user.lon) : const LatLng(20.5937, 78.9629);
    final cov = widget.coverage;
    return FlutterMap(
      mapController: widget.controller,
      options: MapOptions(
        initialCenter: initial,
        initialZoom: user != null ? 15 : 5,
        minZoom: 3,
        maxZoom: 19,
        onMapReady: () {
          _mapReady = true;
          if (user != null) _centeredOnUser = true;
        },
        onLongPress: widget.onLongPress == null ? null : (_, p) => widget.onLongPress!(p),
        onPositionChanged: (_, hasGesture) {
          if (hasGesture) widget.onUserGesture?.call();
        },
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.dharani.dharani_mobile',
          maxNativeZoom: 19,
        ),
        if (cov != null)
          PolygonLayer(polygons: [
            Polygon(
              points: [LatLng(cov.south, cov.west), LatLng(cov.south, cov.east), LatLng(cov.north, cov.east), LatLng(cov.north, cov.west)],
              color: Tokens.accent.withValues(alpha: 0.04),
              borderColor: Tokens.accent.withValues(alpha: 0.35),
              borderStrokeWidth: 1.5,
            ),
          ]),
        if (widget.route.length > 1)
          PolylineLayer(polylines: [
            Polyline(
              points: widget.route,
              strokeWidth: 6,
              color: scheme.primary,
              borderStrokeWidth: 2,
              borderColor: Colors.white,
              strokeCap: StrokeCap.round,
              strokeJoin: StrokeJoin.round,
            ),
          ]),
        if (user != null)
          CircleLayer(circles: [
            CircleMarker(
              point: LatLng(user.lat, user.lon),
              radius: math.max(user.accuracyM, 8),
              useRadiusInMeter: true,
              color: const Color(0xFF2563EB).withValues(alpha: 0.12),
              borderColor: const Color(0xFF2563EB).withValues(alpha: 0.4),
              borderStrokeWidth: 1,
            ),
          ]),
        MarkerLayer(markers: [
          for (final t in widget.tolls) Marker(point: t, width: 28, height: 28, child: const _Dot(Icons.toll, Color(0xFFD97706))),
          for (final h in widget.hazards)
            Marker(
              point: LatLng(h.lat, h.lon),
              width: 34,
              height: 34,
              child: _Dot(Icons.warning_rounded, _hazardColors[h.kind] ?? Colors.orange, ring: h.fromPeer),
            ),
          for (final p in widget.pins) Marker(point: p.point, width: 38, height: 38, alignment: Alignment.topCenter, child: Icon(p.icon, color: p.color, size: 36)),
          if (user != null)
            Marker(
              point: LatLng(user.lat, user.lon),
              width: 22,
              height: 22,
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 3),
                  boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                ),
              ),
            ),
        ]),
        if (_to != null)
          AnimatedBuilder(
            animation: _anim,
            builder: (context, _) {
              final c = _current()!;
              final bad = widget.vehicle?.tamper ?? false;
              return MarkerLayer(markers: [
                Marker(
                  point: LatLng(c.lat, c.lon),
                  width: 46,
                  height: 46,
                  child: Container(
                    decoration: BoxDecoration(
                      color: bad ? Tokens.danger : Tokens.success,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 6)],
                    ),
                    child: Transform.rotate(
                      angle: widget.vehicleIcon == Icons.navigation ? c.heading * math.pi / 180 : 0,
                      child: Icon(widget.vehicleIcon, color: Colors.white, size: 24),
                    ),
                  ),
                ),
              ]);
            },
          ),
        Padding(
          padding: EdgeInsets.only(bottom: widget.bottomInset),
          child: const RichAttributionWidget(
            alignment: AttributionAlignment.bottomLeft,
            attributions: [TextSourceAttribution('© OpenStreetMap contributors')],
          ),
        ),
      ],
    );
  }
}

class _Fix {
  const _Fix(this.lat, this.lon, this.heading);
  final double lat, lon, heading;
}

class _Dot extends StatelessWidget {
  const _Dot(this.icon, this.color, {this.ring = false});
  final IconData icon;
  final Color color;
  final bool ring;
  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: ring ? 3 : 2),
          boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
        ),
        child: Icon(icon, color: Colors.white, size: 16),
      );
}

/// Round floating control that sits on the map.
class MapFab extends StatelessWidget {
  const MapFab({super.key, required this.icon, required this.onPressed, this.tooltip, this.active = false});
  final IconData icon;
  final VoidCallback onPressed;
  final String? tooltip;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Material(
      color: active ? s.primary : s.surface,
      elevation: 3,
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: active ? s.onPrimary : s.onSurface),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}
