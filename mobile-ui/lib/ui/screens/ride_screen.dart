import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:latlong2/latlong.dart';

import '../../models/trip_manifest.dart';
import '../../state/location_cubit.dart';
import '../../state/region_cubit.dart';
import '../../state/ride_cubit.dart';
import '../../state/session_cubit.dart';
import '../widgets/conversation_panel.dart';
import '../theme.dart';
import '../widgets/dharani_map.dart';
import '../widgets/ds.dart';
import '../widgets/map_sheet.dart';
import 'map_navigation_view.dart';

String _eta(double seconds) {
  final m = (seconds / 60).ceil();
  return m < 1 ? '<1 min' : (m < 60 ? '$m min' : '${m ~/ 60} h ${m % 60} min');
}

/// B2C tab: book a ride. Zero-commission fares are computed on-device from the offline route.
class RideScreen extends StatelessWidget {
  const RideScreen({super.key, this.onOpenAccount});
  final VoidCallback? onOpenAccount;

  IconData _icon(RideMode m) => switch (m) { RideMode.auto => Icons.electric_rickshaw, RideMode.cab => Icons.local_taxi, RideMode.bike => Icons.two_wheeler };

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RideCubit, RideState>(
      builder: (context, s) {
        final bloc = context.read<RideCubit>();
        final fix = context.watch<LocationCubit>().state.fix;
        final here = fix == null ? null : Place('My location', fix.lat, fix.lon);
        final pickup = s.pickup ?? here;
        final drop = s.drop;
        final active = s.active;
        final route = [for (final p in s.activeRoute.isNotEmpty ? s.activeRoute : (s.selectedQuote?.route.polyline ?? const [])) LatLng(p.lat, p.lon)];

        return MapSheetScaffold(
          initialSize: active ? 0.36 : 0.5,
          minSize: 0.14,
          mapBuilder: (inset) => MapNavigationView(
            bottomInset: inset,
            route: route,
            vehicle: s.driver,
            vehicleIcon: _icon(s.selected),
            followVehicle: active,
            pins: [
              if (pickup != null && s.pickup != null) MapPin(LatLng(pickup.lat, pickup.lon), Tokens.success, Icons.trip_origin),
              if (drop != null) MapPin(LatLng(drop.lat, drop.lon), Tokens.danger, Icons.location_on),
            ],
            onLongPress: active ? null : (p) => bloc.setDrop(Place('Dropped pin', p.latitude, p.longitude)),
          ),
          sheetChildren: [
            if (s.error != null) ...[InlineNotice(s.error!, tone: PillTone.danger, action: s.error!.contains('Account') ? 'Open' : null, onAction: onOpenAccount), const SizedBox(height: Tokens.gap)],
            ..._content(context, s, bloc, pickup, fix),
          ],
        );
      },
    );
  }

  List<Widget> _content(BuildContext context, RideState s, RideCubit bloc, Place? pickup, dynamic fix) {
    final t = Theme.of(context);
    switch (s.stage) {
      case RideStage.idle:
      case RideStage.quoted:
      case RideStage.failed:
        final region = context.watch<RegionCubit>();
        final noRoads = region.state.info == null;
        return [
          Text('Where to?', style: t.textTheme.titleLarge),
          const SizedBox(height: Tokens.gap),
          if (noRoads) ...[
            region.state.busy
                ? AppCard(child: Row(children: [const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)), const SizedBox(width: 12), Expanded(child: Text(region.state.stage ?? 'Working…'))]))
                : InlineNotice(
                    region.state.error ?? 'Download roads for your area once; fares and routes then work offline.',
                    tone: PillTone.warning,
                    action: 'Download',
                    onAction: fix == null ? onOpenAccount : () => region.download(fix.lat as double, fix.lon as double),
                  ),
            const SizedBox(height: Tokens.gap),
          ],
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(color: t.inputDecorationTheme.fillColor, borderRadius: BorderRadius.circular(12)),
            child: Row(children: [
              const Icon(Icons.trip_origin, size: 20, color: Tokens.success),
              const SizedBox(width: 12),
              Expanded(child: Text(s.pickup?.name ?? (pickup != null ? 'My location' : 'Waiting for GPS…'))),
              if (s.pickup != null) IconButton(visualDensity: VisualDensity.compact, icon: const Icon(Icons.close, size: 18), onPressed: () => bloc.setPickup(null)),
            ]),
          ),
          const SizedBox(height: 8),
          PlaceSearchField(
            hint: 'Search destination, or long-press the map',
            icon: Icons.location_on_outlined,
            nearLat: (fix?.lat as double?),
            nearLon: (fix?.lon as double?),
            selectedLabel: s.drop?.name,
            onPicked: (r) => bloc.setDrop(Place(r.name.split(',').first, r.lat, r.lon)),
            onClear: () => bloc.setDrop(null),
          ),
          if (s.busy) const Padding(padding: EdgeInsets.only(top: 16), child: LinearProgressIndicator()),
          if (s.quotes.isNotEmpty) ...[
            const SizedBox(height: Tokens.gap + 4),
            const SectionTitle('Choose a ride', subtitle: 'Fares are indicative · 0% commission'),
            const SizedBox(height: 8),
            for (final q in s.quotes) _QuoteTile(quote: q, selected: q.mode == s.selected, icon: _icon(q.mode), onTap: () => bloc.selectMode(q.mode)),
            const SizedBox(height: Tokens.gap),
            Row(children: [
              const Icon(Icons.account_balance_wallet_outlined, size: 18),
              const SizedBox(width: 8),
              const Expanded(child: Text('Pay the driver directly by UPI or cash')),
            ]),
            const SizedBox(height: Tokens.gap),
            FilledButton(
              onPressed: bloc.requestRide,
              child: Text('Book ${s.selected.label} · ₹${s.selectedQuote?.fareRupees ?? ''}'),
            ),
            const SizedBox(height: 8),
            Builder(builder: (context) {
              final sess = context.watch<SessionCubit>().state;
              final live = sess.configured && !sess.demo;
              return Text(live ? (sess.connected ? 'Matched with real drivers nearby through your server.' : 'Not connected to the server. Check Account.') : 'Simulated drivers: connect a server in Account to book real ones.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant), textAlign: TextAlign.center);
            }),
          ] else if (s.drop == null && !noRoads) ...[
            const SizedBox(height: Tokens.gap),
            Text('Pick a destination to see fares and ETAs.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ],
        ];
      case RideStage.searching:
        return [
          const SizedBox(height: 8),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Center(child: Text('Finding a nearby driver…', style: t.textTheme.titleMedium)),
          const SizedBox(height: 16),
          OutlinedButton(onPressed: bloc.cancel, child: const Text('Cancel')),
        ];
      case RideStage.toPickup:
      case RideStage.onTrip:
        final onTrip = s.stage == RideStage.onTrip;
        return [
          StageStepper(steps: const ['Booked', 'Driver arriving', 'On trip', 'Arrived'], current: onTrip ? 2 : 1),
          const SizedBox(height: Tokens.gap + 4),
          Row(children: [
            CircleAvatar(radius: 24, backgroundColor: t.colorScheme.primary.withValues(alpha: 0.12), child: Icon(_icon(s.selected), color: t.colorScheme.primary)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.driverName, style: t.textTheme.titleMedium),
                Text('${s.selected.label} · ${s.vehicleNo}', style: t.textTheme.bodySmall),
              ]),
            ),
            if (!onTrip) Pill('OTP ${s.otp}', icon: Icons.lock_outline, tone: PillTone.info),
          ]),
          const SizedBox(height: Tokens.gap),
          AppCard(
            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Kpi(onTrip ? 'Arrive in' : 'Driver arrives in', _eta(s.etaS)),
              Kpi('Distance', (s.remainingM / 1000).toStringAsFixed(1), unit: 'km'),
              Kpi('Fare', '₹${s.selectedQuote?.fareRupees ?? ''}'),
            ]),
          ),
          if (s.message != null) ...[const SizedBox(height: Tokens.gap), InlineNotice(s.message!)],
          const SizedBox(height: Tokens.gap),
          if (!s.remote)
            Row(children: [
              Icon(s.driver?.tamper == true ? Icons.gpp_bad_outlined : Icons.verified_user_outlined, size: 18, color: s.driver?.tamper == true ? Tokens.danger : Tokens.success),
              const SizedBox(width: 8),
              Expanded(child: Text('${s.proofs} signed location proofs from the driver’s device', style: t.textTheme.bodySmall)),
            ]),
          if (s.remote && s.driver?.tamper == true) const InlineNotice('The driver’s phone reports a mock location. Be careful.', tone: PillTone.danger),
          const SizedBox(height: Tokens.gap),
          if (s.remote) ...[const ConversationPanel(), const SizedBox(height: Tokens.gap)],
          if (!onTrip) OutlinedButton(onPressed: bloc.cancel, child: const Text('Cancel ride')),
        ];
      case RideStage.completed:
        return [
          const Icon(Icons.check_circle, color: Tokens.success, size: 56),
          const SizedBox(height: 8),
          Center(child: Text('You have arrived', style: t.textTheme.titleLarge)),
          const SizedBox(height: Tokens.gap),
          AppCard(
            child: Column(children: [
              _line('Fare', '₹${s.selectedQuote?.fareRupees ?? ''}'),
              _line('Platform commission', '₹0'),
              _line('Driver', '${s.driverName} · ${s.vehicleNo}'),
              _line('Location proofs', '${s.proofs} verified'),
            ]),
          ),
          if (s.message != null) ...[const SizedBox(height: Tokens.gap), InlineNotice(s.message!, tone: PillTone.success)],
          const SizedBox(height: Tokens.gap),
          FilledButton(onPressed: bloc.reset, child: const Text('Done')),
        ];
      case RideStage.disputed:
        return [
          const Icon(Icons.gpp_bad, color: Tokens.danger, size: 56),
          const SizedBox(height: 8),
          Center(child: Text('Ride flagged', style: t.textTheme.titleLarge)),
          const SizedBox(height: Tokens.gap),
          InlineNotice(s.message ?? '', tone: PillTone.danger),
          const SizedBox(height: Tokens.gap),
          FilledButton(onPressed: bloc.reset, child: const Text('Close')),
        ];
    }
  }

  Widget _line(String a, String b) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(a), Flexible(child: Text(b, style: const TextStyle(fontWeight: FontWeight.w600), textAlign: TextAlign.end))]),
      );
}

class _QuoteTile extends StatelessWidget {
  const _QuoteTile({required this.quote, required this.selected, required this.icon, required this.onTap});
  final RideQuote quote;
  final bool selected;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: selected ? t.colorScheme.primary : t.colorScheme.outlineVariant, width: selected ? 2 : 1),
            color: selected ? t.colorScheme.primary.withValues(alpha: 0.05) : null,
          ),
          child: Row(children: [
            Icon(icon, size: 30, color: selected ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(quote.mode.label, style: t.textTheme.titleMedium),
                Text('${quote.mode.blurb} · ${_eta(quote.route.durationS)}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              ]),
            ),
            Text('₹${quote.fareRupees}', style: t.textTheme.titleMedium),
          ]),
        ),
      ),
    );
  }
}
