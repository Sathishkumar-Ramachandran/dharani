import 'dart:io';

import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_bloc/flutter_bloc.dart';

import 'services/engine_host.dart';
import 'net/call_audio.dart';
import 'state/call_cubit.dart';
import 'state/conversation_cubit.dart';
import 'state/driver_cubit.dart';
import 'state/location_cubit.dart';
import 'state/mesh_monitor_cubit.dart';
import 'state/region_cubit.dart';
import 'state/ride_cubit.dart';
import 'state/session_cubit.dart';
import 'state/translate_cubit.dart';
import 'state/trip_state_notifier.dart';
import 'translate/model_manager.dart';
import 'translate/npu_asr.dart';
import 'translate/pipeline.dart';
import 'ui/screens/account_screen.dart';
import 'ui/widgets/call_overlay.dart';
import 'ui/screens/active_haul_screen.dart';
import 'ui/screens/drive_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/ride_screen.dart';
import 'ui/screens/translate_screen.dart';
import 'ui/theme.dart';
import 'services/stay_reachable.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const DharaniApp());
}

/// Everything the app needs, created once. Tests inject their own.
class AppDependencies {
  AppDependencies({
    required this.host,
    required this.mesh,
    required this.location,
    required this.region,
    required this.trip,
    required this.ride,
    required this.translate,
    required this.session,
    required this.driver,
    required this.conversation,
    required this.call,
  });

  final EngineHost host;
  final MeshMonitorCubit mesh;
  final LocationCubit location;
  final RegionCubit region;
  final TripStateNotifier trip;
  final RideCubit ride;
  final TranslateCubit translate;
  final SessionCubit session;
  final DriverCubit driver;
  final ConversationCubit conversation;
  final CallCubit call;

  static Future<AppDependencies> create() async {
    final host = EngineHost();
    await host.init();
    final dir = host.dir;
    final npu = NpuAsr();
    final mesh = MeshMonitorCubit();
    final location = LocationCubit();
    final session = SessionCubit();
    final translate = TranslateCubit(
      pipeline: OnDevicePipeline(),
      models: ModelManager(rootDir: dir, extractor: npu.unzip),
      npu: npu,
      bundledManifest: await rootBundle.loadString('assets/ai_pack.json'),
    );
    final conversation = ConversationCubit(session: session, translate: translate);
    return AppDependencies(
      host: host,
      mesh: mesh,
      location: location,
      region: RegionCubit(host),
      trip: TripStateNotifier(host: host, mesh: mesh, location: location),
      ride: RideCubit(host: host, location: location, session: session),
      translate: translate,
      session: session,
      driver: DriverCubit(session: session, location: location, host: host),
      conversation: conversation,
      call: CallCubit(session: session, audio: PlatformCallAudio(), ensureMic: npu.ensureMic, conversation: conversation, npuReady: () => translate.state.npuLoaded, packsReady: translate.packsReadyFor),
    );
  }
}

class DharaniApp extends StatefulWidget {
  const DharaniApp({super.key, this.dependencies});
  final Future<AppDependencies>? dependencies;

  @override
  State<DharaniApp> createState() => _DharaniAppState();
}

class _DharaniAppState extends State<DharaniApp> {
  late final Future<AppDependencies> _deps = widget.dependencies ?? AppDependencies.create();

  @override
  void initState() {
    super.initState();
    // One-time start-up work, kept out of build() so a rebuild can never restart it.
    _deps.then((d) {
      d.location.start();
      d.trip.bootstrap();
      d.translate.init();
      d.session.load(provisionFile: File('${d.host.dir}/provision.json'));
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Dharani',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: FutureBuilder<AppDependencies>(
        future: _deps,
        builder: (context, snap) {
          if (snap.hasError) {
            return Scaffold(body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Dharani could not start the native engine.\n${snap.error}', textAlign: TextAlign.center))));
          }
          if (!snap.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
          final d = snap.data!;
          return MultiBlocProvider(
            providers: [
              BlocProvider.value(value: d.mesh),
              BlocProvider.value(value: d.location),
              BlocProvider.value(value: d.region),
              BlocProvider.value(value: d.trip),
              BlocProvider.value(value: d.ride),
              BlocProvider.value(value: d.translate),
              BlocProvider.value(value: d.session),
              BlocProvider.value(value: d.driver),
              BlocProvider.value(value: d.conversation),
              BlocProvider.value(value: d.call),
            ],
            child: const AppShell(),
          );
        },
      ),
    );
  }
}

/// Tab layout per role (used by the shell and tests).
class AppRole {
  static List<String> tabsFor(proto.Role role) => role == proto.Role.driver ? const ['Drive', 'Freight', 'Translate', 'Account'] : const ['Ride', 'Freight', 'Translate', 'Account'];
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SessionCubit, SessionState>(
      buildWhen: (a, b) => a.loaded != b.loaded || a.configured != b.configured || a.role != b.role,
      builder: (context, s) {
        if (!s.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        if (!s.configured) return const OnboardingScreen();
        final role = s.role!;
        final tabs = AppRole.tabsFor(role);
        final idx = _index.clamp(0, tabs.length - 1);
        void goAccount() => setState(() => _index = tabs.length - 1);
        final pages = role == proto.Role.driver
            ? <Widget>[DriveScreen(onOpenAccount: goAccount), ActiveHaulScreen(onOpenAccount: goAccount), const TranslateScreen(), const AccountScreen()]
            : <Widget>[RideScreen(onOpenAccount: goAccount), ActiveHaulScreen(onOpenAccount: goAccount), const TranslateScreen(), const AccountScreen()];
        const icons = {
          'Ride': (Icons.directions_car_outlined, Icons.directions_car),
          'Drive': (Icons.local_taxi_outlined, Icons.local_taxi),
          'Freight': (Icons.local_shipping_outlined, Icons.local_shipping),
          'Translate': (Icons.translate, Icons.translate),
          'Account': (Icons.person_outline, Icons.person),
        };
        return MultiBlocListener(
          listeners: [
            // Stay reachable on battery with the screen off while a ride or call is active.
            BlocListener<RideCubit, RideState>(
              listenWhen: (a, b) => a.active != b.active,
              listener: (context, r) => r.active ? StayReachable.hold('ride', text: 'Ride in progress') : StayReachable.release('ride'),
            ),
            BlocListener<CallCubit, CallState>(
              listenWhen: (a, b) => a.busy != b.busy,
              listener: (context, c) => c.busy ? StayReachable.hold('call', text: 'Call in progress') : StayReachable.release('call'),
            ),
            BlocListener<CallCubit, CallState>(
              listenWhen: (a, b) => (a.phase == CallPhase.incoming) != (b.phase == CallPhase.incoming),
              listener: (context, c) => c.phase == CallPhase.incoming ? StayReachable.alert('Incoming call', c.peerName.isEmpty ? 'Dharani call' : c.peerName) : StayReachable.clearAlert(),
            ),
            // Rider: bind the live conversation once a driver is assigned, release it when the ride ends.
            BlocListener<RideCubit, RideState>(
              listenWhen: (a, b) => role == proto.Role.rider && (a.stage != b.stage || a.remoteId != b.remoteId || a.driverLang != b.driverLang),
              listener: (context, r) {
                final convo = context.read<ConversationCubit>();
                final profile = context.read<SessionCubit>().state.profile!;
                final live = r.remote && r.remoteId != 'pending' && (r.stage == RideStage.toPickup || r.stage == RideStage.onTrip) && r.driverLang != null;
                if (live) {
                  convo.bind(rideId: r.remoteId!, myLang: profile.lang, peerLang: r.driverLang!, peerName: r.driverName);
                } else if (convo.state.active) {
                  convo.unbind();
                }
              },
            ),
            // Driver: same, from the ride the server assigned.
            BlocListener<DriverCubit, DriverState>(
              listenWhen: (a, b) => role == proto.Role.driver && a.ride?.id != b.ride?.id,
              listener: (context, d) {
                final convo = context.read<ConversationCubit>();
                final profile = context.read<SessionCubit>().state.profile!;
                final ride = d.ride;
                if (ride?.rider != null) {
                  convo.bind(rideId: ride!.id, myLang: profile.lang, peerLang: ride.rider!.lang, peerName: ride.rider!.name);
                } else if (convo.state.active) {
                  convo.unbind();
                }
              },
            ),
          ],
          child: Scaffold(
            body: Stack(children: [
              Positioned.fill(child: IndexedStack(index: idx, children: pages)),
              const Positioned(left: 0, right: 0, top: 0, child: CallOverlay()),
            ]),
            bottomNavigationBar: NavigationBar(
              selectedIndex: idx,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final t in tabs) NavigationDestination(icon: Icon(icons[t]!.$1), selectedIcon: Icon(icons[t]!.$2), label: t),
              ],
            ),
          ),
        );
      },
    );
  }
}
