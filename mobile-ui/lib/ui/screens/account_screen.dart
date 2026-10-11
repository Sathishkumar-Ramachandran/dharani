import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../services/location_service.dart';
import '../../state/location_cubit.dart';
import '../../state/mesh_monitor_cubit.dart';
import '../../state/region_cubit.dart';
import '../../state/session_cubit.dart';
import '../../net/dharani_client.dart';
import '../../state/trip_state_notifier.dart';
import '../../translate/languages.dart';
import '../theme.dart';
import '../widgets/ds.dart';
import '../widgets/swarm_connection_indicator.dart';

/// Settings: offline road regions, GPS permission, device identity and network status.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final trip = context.watch<TripStateNotifier>().state;
    final loc = context.watch<LocationCubit>();
    final region = context.watch<RegionCubit>();
    final info = region.state.info;
    final fix = loc.state.fix;

    return Scaffold(
      appBar: AppBar(title: const Text('Account')),
      body: ListView(padding: const EdgeInsets.all(Tokens.pad), children: [
        const SectionTitle('Profile & server'),
        const SizedBox(height: 10),
        BlocBuilder<SessionCubit, SessionState>(
          builder: (context, ses) {
            final p = ses.profile;
            return AppCard(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Icon(Icons.account_circle_outlined),
                  const SizedBox(width: 10),
                  Expanded(child: Text(p == null ? 'Not set up' : '${p.name} · ${p.role.name}${p.vehicle == null ? '' : ' · ${p.vehicle!.type.name} ${p.vehicle!.plate}'}', style: t.textTheme.titleMedium)),
                ]),
                if (p != null) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('lang-${p.lang}'),
                    initialValue: p.lang,
                    decoration: const InputDecoration(labelText: 'My language', helperText: 'Calls and chat are translated into this for you, and from it for the other person.'),
                    items: [for (final l in kLanguages) DropdownMenuItem(value: l.code, child: Text('${l.name} · ${l.native}'))],
                    onChanged: (v) {
                      if (v != null) context.read<SessionCubit>().setLanguage(v);
                    },
                  ),
                ],
                const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  Pill(
                    ses.demo
                        ? 'Simulation (no server)'
                        : switch (ses.conn) {
                            ConnState.connected => 'Server connected',
                            ConnState.connecting => 'Connecting…',
                            ConnState.reconnecting => 'Reconnecting…',
                            ConnState.disconnected => 'Server offline',
                          },
                    icon: ses.connected ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
                    tone: ses.demo ? PillTone.neutral : (ses.connected ? PillTone.success : PillTone.warning),
                  ),
                  if (ses.serverUrl.isNotEmpty && !ses.demo)
                    Pill(ses.searching ? 'Searching Wi-Fi for server…' : (ses.autoServer ? 'Auto: ${ses.resolvedUrl}' : ses.resolvedUrl.isEmpty ? ses.serverUrl : ses.resolvedUrl), icon: Icons.dns_outlined),
                ]),
                if (ses.error != null) ...[const SizedBox(height: 8), InlineNotice(ses.error!, tone: PillTone.warning)],
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  if (!ses.demo && ses.serverUrl.isNotEmpty) OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: () => context.read<SessionCubit>().connect(), child: const Text('Reconnect')),
                  OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)), onPressed: () => context.read<SessionCubit>().signOut(), child: const Text('Change role / server')),
                ]),
              ]),
            );
          },
        ),
        const SizedBox(height: Tokens.gap + 4),
        const SectionTitle('Offline roads', subtitle: 'Routing, fares and map matching run on-device'),
        const SizedBox(height: 10),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (info == null)
              const Text('No road data installed yet.')
            else ...[
              Row(children: [
                Pill(info.demo ? 'Demo corridor (synthetic)' : 'OpenStreetMap region', icon: info.demo ? Icons.science_outlined : Icons.offline_pin, tone: info.demo ? PillTone.warning : PillTone.success),
              ]),
              const SizedBox(height: 10),
              if (!info.demo) Text('${info.edges} road segments · ${info.nodes} nodes', style: t.textTheme.bodyMedium),
              Text('Covers ${info.bounds.south.toStringAsFixed(2)}–${info.bounds.north.toStringAsFixed(2)}°N, ${info.bounds.west.toStringAsFixed(2)}–${info.bounds.east.toStringAsFixed(2)}°E', style: t.textTheme.bodySmall),
              if (info.builtAt != null) Text('Downloaded ${info.builtAt!.toLocal().toString().substring(0, 16)}', style: t.textTheme.bodySmall),
            ],
            if (region.state.error != null) ...[const SizedBox(height: 10), InlineNotice(region.state.error!, tone: PillTone.danger)],
            if (region.state.busy) ...[const SizedBox(height: 12), const LinearProgressIndicator(), const SizedBox(height: 6), Text(region.state.stage ?? '', style: t.textTheme.bodySmall)],
            const SizedBox(height: 14),
            if (fix == null)
              Text('Turn on location to download roads around you.', style: t.textTheme.bodySmall)
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final km in const [5.0, 10.0, 20.0])
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 44)),
                    onPressed: region.state.busy ? null : () => region.download(fix.lat, fix.lon, radiusKm: km),
                    child: Text('Download ${km.toStringAsFixed(0)} km around me'),
                  ),
              ]),
            const SizedBox(height: 8),
            TextButton(onPressed: region.state.busy ? null : region.useDemoCorridor, child: const Text('Use synthetic demo corridor (Bengaluru–Krishnagiri)')),
            Text('Larger areas take longer and use more storage; 20 km skips minor streets.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        const SizedBox(height: Tokens.gap + 4),
        const SectionTitle('Location'),
        const SizedBox(height: 10),
        AppCard(
          child: Row(children: [
            Icon(loc.state.status == LocationStatus.ready ? Icons.gps_fixed : Icons.gps_off, color: loc.state.status == LocationStatus.ready ? Tokens.success : Tokens.warning),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(switch (loc.state.status) {
                  LocationStatus.ready => fix == null ? 'Waiting for a GPS fix…' : 'GPS fix · ±${fix.accuracyM.toStringAsFixed(0)} m',
                  LocationStatus.denied => 'Location permission needed',
                  LocationStatus.deniedForever => 'Location blocked in system settings',
                  LocationStatus.serviceOff => 'Location services are off',
                  LocationStatus.unknown => 'Checking…',
                }, style: t.textTheme.titleSmall),
                if (fix != null) Text('${fix.lat.toStringAsFixed(5)}, ${fix.lon.toStringAsFixed(5)}${fix.mocked ? ' · MOCK LOCATION' : ''}', style: t.textTheme.bodySmall),
              ]),
            ),
            if (loc.state.status != LocationStatus.ready) TextButton(onPressed: () => loc.state.status == LocationStatus.denied ? loc.start() : loc.openSettings(), child: const Text('Fix')),
          ]),
        ),
        const SizedBox(height: Tokens.gap + 4),
        const SectionTitle('Network resilience'),
        const SizedBox(height: 10),
        AppCard(
          child: BlocBuilder<MeshMonitorCubit, MeshState>(
            builder: (context, m) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwarmConnectionIndicator(path: m.path, peers: m.peers, queuedProofs: m.queuedProofs),
              const SizedBox(height: 8),
              Text(m.meshRunning ? 'Sidelink mesh is listening on the local Wi-Fi network.' : 'Sidelink mesh is not running${m.error == null ? '' : ': ${m.error}'}', style: t.textTheme.bodySmall),
            ]),
          ),
        ),
        const SizedBox(height: Tokens.gap + 4),
        const SectionTitle('Device identity'),
        const SizedBox(height: 10),
        AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Vehicle ID', style: t.textTheme.labelSmall),
            SelectableText(trip.vehicleId, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
            const SizedBox(height: 8),
            Text('Ed25519 public key', style: t.textTheme.labelSmall),
            SelectableText(trip.publicKeyHex, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(height: 8),
            Text(trip.nativeVersion, style: t.textTheme.bodySmall),
          ]),
        ),
      ]),
    );
  }
}
