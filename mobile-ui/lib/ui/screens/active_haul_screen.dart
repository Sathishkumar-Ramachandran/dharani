import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:latlong2/latlong.dart';

import '../../models/hazard.dart';
import '../../models/trip_manifest.dart';
import '../../state/location_cubit.dart';
import '../../state/mesh_monitor_cubit.dart';
import '../../state/region_cubit.dart';
import '../../state/trip_state_notifier.dart';
import '../theme.dart';
import '../widgets/dharani_map.dart';
import '../widgets/ds.dart';
import '../widgets/map_sheet.dart';
import '../widgets/swarm_connection_indicator.dart';
import 'b2b_manifest_audit_screen.dart';
import 'map_navigation_view.dart';

/// B2B tab: freight haul planning, live attested tracking and settlement.
class ActiveHaulScreen extends StatelessWidget {
  const ActiveHaulScreen({super.key, this.onOpenAccount});
  final VoidCallback? onOpenAccount;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<TripStateNotifier, TripState>(
      builder: (context, s) {
        if (s.phase == TripPhase.booting) return const Center(child: CircularProgressIndicator());
        if (s.config == null) {
          return Center(child: Padding(padding: const EdgeInsets.all(24), child: InlineNotice(s.error ?? 'The engine could not start.', tone: PillTone.danger)));
        }
        final bloc = context.read<TripStateNotifier>();
        final live = s.phase == TripPhase.running || s.phase == TripPhase.completed;
        final fix = context.watch<LocationCubit>().state.fix;
        final origin = s.manifest?.origin ?? s.config!.origin ?? (fix == null ? null : Place('My location', fix.lat, fix.lon));
        final dest = s.manifest?.destination ?? s.config!.destination;

        return MapSheetScaffold(
          initialSize: live ? 0.40 : 0.52,
          mapBuilder: (inset) => MapNavigationView(
            bottomInset: inset,
            route: [for (final p in s.route?.polyline ?? const []) LatLng(p.lat, p.lon)],
            vehicle: s.telemetry,
            vehicleIcon: s.config!.vehicle == VehicleClass.truck ? Icons.local_shipping : Icons.navigation,
            followVehicle: s.running,
            hazards: s.hazards,
            tolls: [for (final t in s.route?.tolls ?? const []) LatLng(t.lat, t.lon)],
            pins: [
              if (dest != null) MapPin(LatLng(dest.lat, dest.lon), Tokens.danger, Icons.location_on),
              if (origin != null && origin.name != 'My location') MapPin(LatLng(origin.lat, origin.lon), Tokens.success, Icons.trip_origin),
            ],
            onLongPress: live
                ? null
                : (p) => bloc.updateConfig(s.config!.withDestination(Place('Dropped pin', p.latitude, p.longitude))),
          ),
          topOverlay: live ? _LiveStatusBar(state: s) : null,
          sheetChildren: [
            if (s.error != null) ...[InlineNotice(s.error!, tone: PillTone.danger), const SizedBox(height: Tokens.gap)],
            if (live) ..._liveChildren(context, s, bloc) else ..._setupChildren(context, s, bloc, fix == null ? null : Place('My location', fix.lat, fix.lon)),
          ],
        );
      },
    );
  }

  // ------------------------------------------------------------------ setup
  List<Widget> _setupChildren(BuildContext context, TripState s, TripStateNotifier bloc, Place? here) {
    final cfg = s.config!;
    final region = context.watch<RegionCubit>();
    final fix = context.watch<LocationCubit>().state.fix;
    final truck = cfg.vehicle == VehicleClass.truck;
    final t = Theme.of(context);
    final noRoads = region.state.info == null;
    final outside = fix != null && region.state.info != null && !region.state.covers(fix.lat, fix.lon);

    return [
      Row(children: [
        Expanded(child: Text('New freight haul', style: t.textTheme.titleLarge)),
        Pill(noRoads ? 'No offline roads' : (region.state.info!.demo ? 'Demo roads' : 'Offline roads ready'),
            icon: noRoads ? Icons.cloud_off : Icons.offline_pin, tone: noRoads ? PillTone.warning : PillTone.success),
      ]),
      const SizedBox(height: Tokens.gap),
      if (noRoads || outside) ...[
        _RoadsNotice(outside: outside, busy: region.state.busy, stage: region.state.stage, error: region.state.error, fix: fix, onOpenAccount: onOpenAccount),
        const SizedBox(height: Tokens.gap),
      ],
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionTitle('Route'),
          const SizedBox(height: 10),
          _OriginRow(origin: cfg.origin, here: here, onClear: () => bloc.updateConfig(cfg.withOrigin(null))),
          const SizedBox(height: 8),
          PlaceSearchField(
            hint: 'Destination — search or long-press the map',
            icon: Icons.flag_outlined,
            nearLat: fix?.lat,
            nearLon: fix?.lon,
            selectedLabel: cfg.destination?.name,
            onPicked: (r) => bloc.updateConfig(cfg.withDestination(Place(r.name.split(',').first, r.lat, r.lon))),
            onClear: () => bloc.updateConfig(cfg.withDestination(null)),
          ),
        ]),
      ),
      const SizedBox(height: Tokens.gap),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionTitle('Vehicle & load'),
          const SizedBox(height: 10),
          SegmentedButton<VehicleClass>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: VehicleClass.truck, label: Text('Truck'), icon: Icon(Icons.local_shipping_outlined)),
              ButtonSegment(value: VehicleClass.auto, label: Text('Van'), icon: Icon(Icons.airport_shuttle_outlined)),
              ButtonSegment(value: VehicleClass.twoWheeler, label: Text('Bike'), icon: Icon(Icons.two_wheeler)),
            ],
            selected: {cfg.vehicle},
            onSelectionChanged: (v) => bloc.updateConfig(cfg.copyWith(vehicle: v.first)),
          ),
          if (truck) ...[
            const SizedBox(height: 12),
            _SliderRow(label: 'Gross weight', value: '${(cfg.grossWeightKg / 1000).toStringAsFixed(0)} t', slider: Slider(value: cfg.grossWeightKg, min: 5000, max: 40000, divisions: 35, onChanged: (v) => bloc.updateConfig(cfg.copyWith(grossWeightKg: v)))),
            _SliderRow(label: 'Height', value: '${cfg.heightM.toStringAsFixed(1)} m', slider: Slider(value: cfg.heightM, min: 2.5, max: 4.8, divisions: 23, onChanged: (v) => bloc.updateConfig(cfg.copyWith(heightM: v)))),
            Text('Routing avoids roads with lower height or weight limits.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cold chain (2–8 °C SLA)'),
              subtitle: const Text('More than 15 min outside the band disputes the contract'),
              value: cfg.coldChain,
              onChanged: (v) => bloc.updateConfig(cfg.copyWith(coldChain: v)),
            ),
          ],
        ]),
      ),
      const SizedBox(height: Tokens.gap),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionTitle('Tracking source'),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('Simulation'), icon: Icon(Icons.smart_toy_outlined)),
              ButtonSegment(value: false, label: Text('Live GPS'), icon: Icon(Icons.gps_fixed)),
            ],
            selected: {cfg.simulated},
            onSelectionChanged: (v) => bloc.updateConfig(cfg.copyWith(simulated: v.first)),
          ),
          const SizedBox(height: 8),
          if (cfg.simulated) ...[
            Text('A virtual truck drives the real route. Speed up time to watch the whole haul in minutes.', style: t.textTheme.bodySmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              for (final x in const [1, 5, 10, 20])
                ChoiceChip(label: Text('$x× speed'), selected: cfg.timeScale == x, onSelected: (_) => bloc.updateConfig(cfg.copyWith(timeScale: x))),
            ]),
          ] else
            Text('Uses this phone’s GNSS, accelerometer and gyroscope. Drive for real; each fix is signed on-device.', style: t.textTheme.bodySmall),
        ]),
      ),
      const SizedBox(height: Tokens.gap + 4),
      FilledButton.icon(
        onPressed: s.phase == TripPhase.starting ? null : bloc.startTrip,
        icon: s.phase == TripPhase.starting
            ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.play_arrow_rounded),
        label: const Text('Create contract & start'),
      ),
    ];
  }

  // ------------------------------------------------------------------ live
  List<Widget> _liveChildren(BuildContext context, TripState s, TripStateNotifier bloc) {
    final cfg = s.config!;
    final t = s.telemetry;
    final th = Theme.of(context);
    final done = s.phase == TripPhase.completed;
    final disputed = s.escrow.state == 'DISPUTED';
    final steps = ['Confirmed', 'Dispatched', 'In transit', 'Verified', 'Settled'];
    final stepIdx = switch (s.escrow.state) { 'CONFIRMED' => 0, 'DISPATCHED' => 1, 'IN_TRANSIT' => 2, 'GEOFENCE_VERIFIED' => 3, 'SETTLED' => 4, _ => 2 };

    return [
      Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.manifest?.origin.name} → ${s.manifest?.destination.name}', style: th.textTheme.titleMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(s.manifest?.id ?? '', style: th.textTheme.bodySmall?.copyWith(color: th.colorScheme.onSurfaceVariant)),
          ]),
        ),
        if (!done) TextButton.icon(onPressed: bloc.stopTrip, icon: const Icon(Icons.stop_circle_outlined), label: const Text('Stop')),
      ]),
      const SizedBox(height: Tokens.gap),
      if (s.message != null) ...[InlineNotice(s.message!, tone: disputed ? PillTone.danger : (s.escrow.state == 'SETTLED' ? PillTone.success : PillTone.info)), const SizedBox(height: Tokens.gap)],
      if (s.rerouteNotice != null) ...[InlineNotice(s.rerouteNotice!, tone: PillTone.warning), const SizedBox(height: Tokens.gap)],
      if (disputed) ...[StageStepper(steps: const ['Confirmed', 'Dispatched', 'In transit', 'Disputed'], current: 3), const SizedBox(height: Tokens.gap)]
      else ...[StageStepper(steps: steps, current: stepIdx), const SizedBox(height: Tokens.gap)],
      BlocBuilder<MeshMonitorCubit, MeshState>(
        builder: (context, m) => Wrap(spacing: 8, runSpacing: 8, children: [
          Pill(s.sensorHealthy ? (t == null ? 'Awaiting first proof' : 'Proofs valid') : 'Tamper: ${t?.tamperReason}',
              icon: s.sensorHealthy ? Icons.verified_user_outlined : Icons.gpp_bad_outlined,
              tone: t == null ? PillTone.neutral : (s.sensorHealthy ? PillTone.success : PillTone.danger)),
          SwarmConnectionIndicator(path: m.path, peers: m.peers, queuedProofs: m.queuedProofs),
        ]),
      ),
      const SizedBox(height: Tokens.gap),
      AppCard(
        child: Column(children: [
          Wrap(spacing: 28, runSpacing: 14, children: [
            Kpi('Speed', t == null ? '—' : t.speedKph.toStringAsFixed(0), unit: 'km/h'),
            Kpi('Remaining', (s.remainingM / 1000).toStringAsFixed(1), unit: 'km'),
            Kpi('Route', s.route == null ? '—' : (s.route!.distanceM / 1000).toStringAsFixed(1), unit: 'km'),
            Kpi('CO₂', s.route == null ? '—' : (s.route!.carbonGrams / 1000).toStringAsFixed(0), unit: 'kg'),
            Kpi('Proofs', '${s.proofChecksPassed}/${s.samples}'),
          ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => MultiBlocProvider(providers: [BlocProvider.value(value: bloc)], child: const B2bManifestAuditScreen()),
            )),
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Compliance audit'),
          ),
        ]),
      ),
      if (done)
        Padding(padding: const EdgeInsets.only(top: Tokens.gap + 4), child: FilledButton.icon(onPressed: bloc.resetAfterTrip, icon: const Icon(Icons.add), label: const Text('Plan another haul'))),
      if (!done) ...[
        const SizedBox(height: Tokens.gap),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const SectionTitle('Report a hazard', subtitle: 'Shared with nearby vehicles and used when re-routing'),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final k in HazardKind.values.skip(1)) ActionChip(label: Text(k.label), onPressed: () => bloc.reportHazard(k)),
            ]),
            if (cfg.coldChain) ...[
              const SizedBox(height: 14),
              _SliderRow(
                label: 'Reefer temperature (SLA ${cfg.minTempC.toStringAsFixed(0)}–${cfg.maxTempC.toStringAsFixed(0)} °C)',
                value: '${s.reeferTempC.toStringAsFixed(1)} °C',
                slider: Slider(value: s.reeferTempC.clamp(-5.0, 20.0), min: -5, max: 20, onChanged: bloc.setReeferTemp),
              ),
              if (s.escrow.excursionSeconds > 0)
                Text('Excursion: ${(s.escrow.excursionSeconds / 60).toStringAsFixed(1)} of 15 min allowed', style: const TextStyle(color: Tokens.danger)),
            ],
          ]),
        ),
        if (cfg.simulated) ...[
          const SizedBox(height: Tokens.gap),
          AppCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SectionTitle('Fraud drills', subtitle: 'Simulation only — watch the contract react'),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
                onPressed: () => bloc.injectGpsJump(5000),
                icon: const Icon(Icons.gps_off),
                label: const Text('Spoof a 5 km GPS jump'),
              ),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Wheel sensor frozen (mock-GPS rig)'), value: s.freezeWheels, onChanged: bloc.setFreezeWheels),
              BlocBuilder<MeshMonitorCubit, MeshState>(
                builder: (context, m) => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Simulate uplink outage'),
                  subtitle: const Text('Falls back to mesh, then store-and-forward'),
                  value: m.outageSimulated,
                  onChanged: bloc.setSimulatedOutage,
                ),
              ),
            ]),
          ),
        ],
        if (s.route != null && s.route!.steps.isNotEmpty) ...[
          const SizedBox(height: Tokens.gap),
          AppCard(
            padding: EdgeInsets.zero,
            child: ExpansionTile(
              shape: const Border(),
              collapsedShape: const Border(),
              title: const Text('Turn-by-turn'),
              children: [
                for (final step in s.route!.steps)
                  ListTile(dense: true, leading: const Icon(Icons.turn_right, size: 20), title: Text(step.instruction), trailing: step.distanceM > 0 ? Text('${(step.distanceM / 1000).toStringAsFixed(1)} km') : null),
              ],
            ),
          ),
        ],
      ],
    ];
  }

}

class _LiveStatusBar extends StatelessWidget {
  const _LiveStatusBar({required this.state});
  final TripState state;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Material(
      color: s.surface,
      elevation: 3,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(children: [
          Icon(Icons.local_shipping, color: s.primary),
          const SizedBox(width: 10),
          Expanded(child: Text(state.escrow.state.replaceAll('_', ' '), style: const TextStyle(fontWeight: FontWeight.w700))),
          Text('${(state.remainingM / 1000).toStringAsFixed(1)} km left', style: Theme.of(context).textTheme.bodyMedium),
        ]),
      ),
    );
  }
}

class _OriginRow extends StatelessWidget {
  const _OriginRow({required this.origin, required this.here, required this.onClear});
  final Place? origin, here;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final label = origin?.name ?? (here != null ? 'My location' : 'Waiting for GPS…');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(color: t.inputDecorationTheme.fillColor, borderRadius: BorderRadius.circular(12)),
      child: Row(children: [
        Icon(origin == null ? Icons.my_location : Icons.trip_origin, size: 20, color: Tokens.success),
        const SizedBox(width: 12),
        Expanded(child: Text(label)),
        if (origin != null) IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: onClear),
      ]),
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({required this.label, required this.value, required this.slider});
  final String label, value;
  final Slider slider;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Flexible(child: Text(label)), Text(value, style: const TextStyle(fontWeight: FontWeight.w700))]),
        slider,
      ]);
}

/// Prompts the user to install roads for the area (the offline router needs them).
class _RoadsNotice extends StatelessWidget {
  const _RoadsNotice({required this.outside, required this.busy, this.stage, this.error, this.fix, this.onOpenAccount});
  final bool outside, busy;
  final String? stage, error;
  final dynamic fix;
  final VoidCallback? onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final region = context.read<RegionCubit>();
    if (busy) {
      return AppCard(child: Row(children: [const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 12), Expanded(child: Text(stage ?? 'Working…'))]));
    }
    return Column(children: [
      if (error != null) ...[InlineNotice(error!, tone: PillTone.danger), const SizedBox(height: 8)],
      InlineNotice(
        outside ? 'Your location is outside the downloaded roads.' : 'Download roads for your area once; routing then works fully offline.',
        tone: PillTone.warning,
        action: fix == null ? 'Open Account' : 'Download',
        onAction: fix == null ? onOpenAccount : () => region.download(fix.lat as double, fix.lon as double),
      ),
    ]);
  }
}
