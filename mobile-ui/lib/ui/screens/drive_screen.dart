import 'dart:async';

import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:latlong2/latlong.dart';

import '../../net/dharani_client.dart';
import '../../net/remote_models.dart';
import '../../state/driver_cubit.dart';
import '../../state/session_cubit.dart';
import '../../translate/languages.dart';
import '../theme.dart';
import '../widgets/conversation_panel.dart';
import '../widgets/dharani_map.dart';
import '../widgets/ds.dart';
import '../widgets/map_sheet.dart';
import 'map_navigation_view.dart';

/// Driver home: go online, receive offers, run the ride, talk to the rider in their language.
class DriveScreen extends StatelessWidget {
  const DriveScreen({super.key, this.onOpenAccount});
  final VoidCallback? onOpenAccount;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DriverCubit, DriverState>(
      builder: (context, s) {
        final session = context.watch<SessionCubit>().state;
        final bloc = context.read<DriverCubit>();
        final ride = s.ride;
        final target = ride == null ? null : (ride.state == proto.RideState.onTrip ? ride.drop : ride.pickup);
        return MapSheetScaffold(
          initialSize: ride != null || s.offer != null ? 0.5 : 0.36,
          mapBuilder: (inset) => MapNavigationView(
            bottomInset: inset,
            route: [for (final p in s.route) LatLng(p.lat, p.lon)],
            pins: [
              if (ride != null) MapPin(LatLng(ride.pickup.lat, ride.pickup.lon), Tokens.success, Icons.trip_origin),
              if (target != null) MapPin(LatLng(target.lat, target.lon), Tokens.danger, Icons.location_on),
              if (s.offer != null) MapPin(LatLng(s.offer!.pickup.lat, s.offer!.pickup.lon), Tokens.success, Icons.trip_origin),
            ],
          ),
          sheetChildren: [
            _ConnectionBanner(session: session, onOpenAccount: onOpenAccount),
            if (s.error != null) ...[InlineNotice(s.error!, tone: PillTone.danger), const SizedBox(height: Tokens.gap)],
            if (s.message != null) ...[InlineNotice(s.message!), const SizedBox(height: Tokens.gap)],
            if (ride != null)
              ..._rideChildren(context, s, ride, bloc)
            else if (s.offer != null)
              _OfferCard(offer: s.offer!, onAccept: bloc.accept, onDecline: bloc.decline)
            else
              ..._idleChildren(context, s, bloc, session),
          ],
        );
      },
    );
  }

  List<Widget> _idleChildren(BuildContext context, DriverState s, DriverCubit bloc, SessionState session) {
    final t = Theme.of(context);
    final v = session.profile?.vehicle;
    return [
      Row(children: [
        Expanded(child: Text(s.online ? 'You are online' : 'You are offline', style: t.textTheme.titleLarge)),
        Pill(s.online ? 'Accepting rides' : 'Not accepting', icon: s.online ? Icons.circle : Icons.circle_outlined, tone: s.online ? PillTone.success : PillTone.neutral),
      ]),
      const SizedBox(height: 4),
      Text(v == null ? '' : '${v.type.name.toUpperCase()} · ${v.plate}${v.model.isEmpty ? '' : ' · ${v.model}'}', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: Tokens.gap + 4),
      if (s.online)
        AppCard(
          child: Row(children: [
            const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
            const SizedBox(width: 14),
            Expanded(child: Text('Looking for ${v?.type.name ?? 'ride'} requests near you. Keep the app open; your location is shared only while online.', style: t.textTheme.bodyMedium)),
          ]),
        ),
      const SizedBox(height: Tokens.gap + 4),
      s.online
          ? OutlinedButton.icon(onPressed: () => bloc.goOnline(false), icon: const Icon(Icons.power_settings_new), label: const Text('Go offline'))
          : FilledButton.icon(onPressed: session.connected ? () => bloc.goOnline(true) : null, icon: const Icon(Icons.power_settings_new), label: const Text('Go online')),
    ];
  }

  List<Widget> _rideChildren(BuildContext context, DriverState s, RemoteRide ride, DriverCubit bloc) {
    final t = Theme.of(context);
    final stage = switch (ride.state) { proto.RideState.assigned => 0, proto.RideState.arrived => 1, _ => 2 };
    final onTrip = ride.state == proto.RideState.onTrip;
    return [
      StageStepper(steps: const ['To pickup', 'Arrived', 'On trip'], current: stage),
      const SizedBox(height: Tokens.gap + 4),
      Row(children: [
        CircleAvatar(radius: 24, backgroundColor: t.colorScheme.primary.withValues(alpha: 0.12), child: Icon(Icons.person, color: t.colorScheme.primary)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ride.rider?.name ?? 'Rider', style: t.textTheme.titleMedium),
            Text('Speaks ${_langName(ride.rider?.lang)}', style: t.textTheme.bodySmall),
          ]),
        ),
        Text('₹${ride.fareRupees}', style: t.textTheme.titleLarge),
      ]),
      const SizedBox(height: Tokens.gap),
      AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Stop(icon: Icons.trip_origin, color: Tokens.success, label: 'Pickup', name: ride.pickup.name, active: !onTrip),
          const SizedBox(height: 8),
          _Stop(icon: Icons.location_on, color: Tokens.danger, label: 'Drop', name: ride.drop.name, active: onTrip),
          const Divider(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Kpi(onTrip ? 'To drop' : 'To pickup', (s.remainingM / 1000).toStringAsFixed(1), unit: 'km'),
            Kpi('ETA', '${(s.etaS / 60).ceil()}', unit: 'min'),
          ]),
        ]),
      ),
      const SizedBox(height: Tokens.gap),
      if (!onTrip) ...[
        if (ride.state == proto.RideState.assigned) FilledButton.icon(onPressed: bloc.arrived, icon: const Icon(Icons.flag), label: const Text('I have arrived')),
        if (ride.state == proto.RideState.arrived || ride.state == proto.RideState.assigned) ...[
          const SizedBox(height: 8),
          _StartTrip(onStart: bloc.start, wrong: s.otpWrong),
        ],
        const SizedBox(height: 8),
        TextButton(onPressed: bloc.cancelRide, child: const Text('Cancel this ride')),
      ] else
        FilledButton.icon(onPressed: bloc.complete, icon: const Icon(Icons.check_circle), label: Text('Complete trip · ₹${ride.fareRupees}')),
      const SizedBox(height: Tokens.gap),
      const ConversationPanel(),
    ];
  }

  static String _langName(String? code) => kLanguages.where((l) => l.code == code).map((l) => l.name).firstOrNull ?? 'their language';
}

class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.session, this.onOpenAccount});
  final SessionState session;
  final VoidCallback? onOpenAccount;

  @override
  Widget build(BuildContext context) {
    if (session.connected) return const SizedBox.shrink();
    final text = switch (session.conn) {
      ConnState.connecting => 'Connecting to the server…',
      ConnState.reconnecting => session.error ?? 'Connection lost. Reconnecting…',
      _ => 'Not connected to the server.',
    };
    return Padding(padding: const EdgeInsets.only(bottom: Tokens.gap), child: InlineNotice(text, tone: PillTone.warning, action: 'Server', onAction: onOpenAccount));
  }
}

class _Stop extends StatelessWidget {
  const _Stop({required this.icon, required this.color, required this.label, required this.name, required this.active});
  final IconData icon;
  final Color color;
  final String label, name;
  final bool active;
  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: Theme.of(context).textTheme.labelSmall), Text(name.isEmpty ? '—' : name, style: TextStyle(fontWeight: active ? FontWeight.w700 : FontWeight.w400))])),
      ]);
}

/// OTP entry: the rider reads the 4 digits out; the server checks them.
class _StartTrip extends StatefulWidget {
  const _StartTrip({required this.onStart, required this.wrong});
  final void Function(String otp) onStart;
  final bool wrong;
  @override
  State<_StartTrip> createState() => _StartTripState();
}

class _StartTripState extends State<_StartTrip> {
  final _otp = TextEditingController();
  @override
  void dispose() {
    _otp.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(
          child: TextField(
            controller: _otp,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: InputDecoration(labelText: 'Rider OTP', counterText: '', errorText: widget.wrong ? 'Wrong OTP' : null),
          ),
        ),
        const SizedBox(width: 10),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(120, 52)), onPressed: () => widget.onStart(_otp.text), child: const Text('Start trip')),
      ]);
}

class _OfferCard extends StatefulWidget {
  const _OfferCard({required this.offer, required this.onAccept, required this.onDecline});
  final RideOffer offer;
  final VoidCallback onAccept, onDecline;
  @override
  State<_OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<_OfferCard> {
  Timer? _tick;
  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final o = widget.offer;
    final left = o.expiresAt.difference(DateTime.now()).inMilliseconds.clamp(0, 60000);
    return AppCard(
      tint: t.colorScheme.primary.withValues(alpha: 0.05),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text('New ride request', style: t.textTheme.titleMedium)),
          Text('₹${o.fareRupees}', style: t.textTheme.headlineSmall),
        ]),
        const SizedBox(height: 8),
        _Stop(icon: Icons.trip_origin, color: Tokens.success, label: '${(o.distanceToPickupM / 1000).toStringAsFixed(1)} km away', name: o.pickup.name, active: true),
        const SizedBox(height: 8),
        _Stop(icon: Icons.location_on, color: Tokens.danger, label: 'Drop', name: o.drop.name, active: false),
        const SizedBox(height: 12),
        LinearProgressIndicator(value: left / 20000),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: widget.onDecline, child: const Text('Decline'))),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: FilledButton(onPressed: widget.onAccept, child: Text('Accept · ${(left / 1000).ceil()}s'))),
        ]),
      ]),
    );
  }
}
