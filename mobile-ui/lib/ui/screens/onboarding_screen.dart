import 'package:dharani_protocol/dharani_protocol.dart' as proto;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../net/dharani_client.dart';
import '../../state/session_cubit.dart';
import '../../translate/languages.dart';
import '../theme.dart';
import '../widgets/ds.dart';

/// First launch: who are you (rider or driver), your language, and where the server is.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  proto.Role _role = proto.Role.rider;
  proto.VehicleType _vehicle = proto.VehicleType.cab;
  String _lang = 'en';
  final _name = TextEditingController();
  final _plate = TextEditingController();
  final _model = TextEditingController();
  late final _url = TextEditingController(text: context.read<SessionCubit>().state.serverUrl == kAutoServer ? '' : context.read<SessionCubit>().state.serverUrl);
  String? _formError;

  @override
  void dispose() {
    for (final c in [_name, _plate, _model, _url]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({required bool demo}) async {
    setState(() => _formError = null);
    if (_name.text.trim().isEmpty) return setState(() => _formError = 'Enter your name.');
    final driver = _role == proto.Role.driver;
    if (driver && _plate.text.trim().length < 4) return setState(() => _formError = 'Enter the vehicle registration number.');
    await context.read<SessionCubit>().configure(
          profile: Profile(
            role: _role,
            name: _name.text.trim(),
            lang: _lang,
            vehicle: driver ? (type: _vehicle, plate: _plate.text.trim().toUpperCase(), model: _model.text.trim()) : null,
          ),
          serverUrl: _url.text,
          demo: demo,
        );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final session = context.watch<SessionCubit>().state;
    final driver = _role == proto.Role.driver;
    return Scaffold(
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(Tokens.pad + 4), children: [
          const SizedBox(height: 12),
          Text('Welcome to Dharani', style: t.textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Zero-commission rides and freight with live translation between rider and driver.', style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 24),
          SegmentedButton<proto.Role>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: proto.Role.rider, icon: Icon(Icons.person_pin_circle_outlined), label: Text('I need a ride')),
              ButtonSegment(value: proto.Role.driver, icon: Icon(Icons.local_taxi_outlined), label: Text('I drive')),
            ],
            selected: {_role},
            onSelectionChanged: (v) => setState(() => _role = v.first),
          ),
          const SizedBox(height: 16),
          TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Your name')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _lang,
            decoration: const InputDecoration(labelText: 'Language you speak'),
            items: [for (final l in kLanguages) DropdownMenuItem(value: l.code, child: Text('${l.name} · ${l.native}'))],
            onChanged: (v) => setState(() => _lang = v ?? 'en'),
          ),
          if (driver) ...[
            const SizedBox(height: 16),
            Text('Your vehicle', style: t.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<proto.VehicleType>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: proto.VehicleType.auto, icon: Icon(Icons.electric_rickshaw), label: Text('Auto')),
                ButtonSegment(value: proto.VehicleType.cab, icon: Icon(Icons.local_taxi), label: Text('Cab')),
                ButtonSegment(value: proto.VehicleType.bike, icon: Icon(Icons.two_wheeler), label: Text('Bike')),
              ],
              selected: {_vehicle},
              onSelectionChanged: (v) => setState(() => _vehicle = v.first),
            ),
            const SizedBox(height: 12),
            TextField(controller: _plate, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Registration number', hintText: 'KA01AB1234')),
            const SizedBox(height: 12),
            TextField(controller: _model, decoration: const InputDecoration(labelText: 'Vehicle model (optional)')),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Server address (optional)', hintText: 'Found automatically on this Wi-Fi', helperText: 'Leave empty: the phone finds the Dharani server on the same Wi-Fi by itself.'),
          ),
          if (_formError != null || session.error != null) ...[
            const SizedBox(height: 12),
            InlineNotice(_formError ?? session.error!, tone: PillTone.danger),
          ],
          const SizedBox(height: 20),
          FilledButton(onPressed: () => _submit(demo: false), child: Text(driver ? 'Start driving' : 'Continue')),
          if (!driver) ...[
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => _submit(demo: true), child: const Text('Try with simulated drivers (no server)')),
          ],
        ]),
      ),
    );
  }
}
