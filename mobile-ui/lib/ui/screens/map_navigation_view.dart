import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../models/hazard.dart';
import '../../models/telemetry_node.dart';
import '../../services/location_service.dart';
import '../../state/location_cubit.dart';
import '../../state/region_cubit.dart';
import '../widgets/dharani_map.dart';

/// Map with the standard controls: zoom, recenter on the real GPS fix, follow the vehicle and
/// fit the route. Screens place their bottom sheet over it and pass `bottomInset`.
class MapNavigationView extends StatefulWidget {
  const MapNavigationView({
    super.key,
    this.route = const [],
    this.vehicle,
    this.vehicleIcon = Icons.navigation,
    this.pins = const [],
    this.hazards = const [],
    this.tolls = const [],
    this.onLongPress,
    this.bottomInset = 0,
    this.followVehicle = false,
    this.showCoverage = true,
  });

  final List<LatLng> route;
  final TelemetryNode? vehicle;
  final IconData vehicleIcon;
  final List<MapPin> pins;
  final List<RoadHazard> hazards;
  final List<LatLng> tolls;
  final void Function(LatLng)? onLongPress;
  final double bottomInset;
  final bool followVehicle;
  final bool showCoverage;

  @override
  State<MapNavigationView> createState() => _MapNavigationViewState();
}

class _MapNavigationViewState extends State<MapNavigationView> {
  final _controller = MapController();
  bool _follow = false;

  @override
  void initState() {
    super.initState();
    _follow = widget.followVehicle;
  }

  @override
  void didUpdateWidget(MapNavigationView old) {
    super.didUpdateWidget(old);
    if (widget.followVehicle != old.followVehicle) _follow = widget.followVehicle;
    // Frame a new route as soon as it appears.
    // Compare by content: screens rebuild the list on every frame while the sheet is dragged,
    // and re-framing the camera each time made the map fight the user's finger.
    if (widget.route.length > 1 && widget.vehicle == null && _routeChanged(old.route, widget.route)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
    }
  }

  static bool _routeChanged(List<LatLng> a, List<LatLng> b) =>
      a.length != b.length || (a.isNotEmpty && (a.first != b.first || a.last != b.last));

  void _fit() {
    if (widget.route.length < 2) return;
    try {
      _controller.fitCamera(CameraFit.coordinates(
        coordinates: widget.route,
        padding: EdgeInsets.fromLTRB(48, 120, 48, widget.bottomInset + 48),
        maxZoom: 17,
      ));
    } catch (_) {}
  }

  void _toUser(UserFix? f) {
    if (f == null) return;
    setState(() => _follow = false);
    _controller.move(LatLng(f.lat, f.lon), 16);
  }

  void _zoom(double d) => _controller.move(_controller.camera.center, (_controller.camera.zoom + d).clamp(3.0, 19.0));

  @override
  Widget build(BuildContext context) {
    final loc = context.watch<LocationCubit>().state;
    final region = context.watch<RegionCubit>().state;
    final fix = loc.fix;
    final hasVehicle = widget.vehicle != null;
    return Stack(children: [
      Positioned.fill(
        child: DharaniMap(
          controller: _controller,
          route: widget.route,
          vehicle: widget.vehicle,
          vehicleIcon: widget.vehicleIcon,
          user: fix,
          pins: widget.pins,
          hazards: widget.hazards,
          tolls: widget.tolls,
          coverage: widget.showCoverage && !(region.info?.demo ?? false) ? region.info?.bounds : null,
          follow: _follow && hasVehicle,
          onLongPress: widget.onLongPress,
          onUserGesture: () {
            if (_follow) setState(() => _follow = false);
          },
          bottomInset: widget.bottomInset,
        ),
      ),
      Positioned(
        right: 12,
        bottom: widget.bottomInset + 16,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          MapFab(icon: Icons.add, tooltip: 'Zoom in', onPressed: () => _zoom(1)),
          const SizedBox(height: 8),
          MapFab(icon: Icons.remove, tooltip: 'Zoom out', onPressed: () => _zoom(-1)),
          const SizedBox(height: 8),
          if (widget.route.length > 1) ...[
            MapFab(icon: Icons.route, tooltip: 'Show whole route', onPressed: _fit),
            const SizedBox(height: 8),
          ],
          if (hasVehicle) ...[
            MapFab(icon: Icons.navigation, tooltip: 'Follow vehicle', active: _follow, onPressed: () => setState(() => _follow = true)),
            const SizedBox(height: 8),
          ],
          MapFab(
            icon: loc.hasFix ? Icons.my_location : Icons.location_disabled,
            tooltip: 'My location',
            onPressed: loc.hasFix ? () => _toUser(fix) : () => context.read<LocationCubit>().start(),
          ),
        ]),
      ),
    ]);
  }
}

