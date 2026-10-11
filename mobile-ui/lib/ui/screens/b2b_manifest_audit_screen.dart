import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../state/trip_state_notifier.dart';
import '../widgets/anti_tamper_badge.dart';

String _rupees(int paise) => '₹${(paise / 100).toStringAsFixed(2)}';

class B2bManifestAuditScreen extends StatelessWidget {
  const B2bManifestAuditScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manifest compliance audit')),
      body: BlocBuilder<TripStateNotifier, TripState>(
        builder: (context, s) {
          final m = s.manifest;
          if (m == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('No active manifest. Start a haul to see its cryptographic audit trail.', textAlign: TextAlign.center),
              ),
            );
          }
          final a = s.attestation;
          final t = s.telemetry;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text('e-Way bill ${m.ewayBill}'),
                subtitle: Text('${m.id}\n${m.origin.name} → ${m.destination.name}\n'
                    '${m.tonnage} t · ${m.volumeM3.toStringAsFixed(0)} m³${m.coldChain ? ' · cold chain' : ''}'),
                isThreeLine: true,
              ),
            ),
            _Section(
              title: 'Cryptographic validity',
              children: [
                AntiTamperBadge(valid: s.sensorHealthy, reason: t?.tamperReason, pending: a == null),
                const SizedBox(height: 8),
                _Mono('Signer (Ed25519)', s.publicKeyHex),
                if (a != null) ...[
                  _Mono('Payload SHA-256', a.digestHex),
                  _Mono('Signature', a.signatureHex),
                  Row(children: [
                    Icon(t?.signatureValid == true ? Icons.check_circle : Icons.cancel,
                        color: t?.signatureValid == true ? Colors.green : Theme.of(context).colorScheme.error, size: 18),
                    const SizedBox(width: 6),
                    Expanded(child: Text('${s.proofChecksPassed} of ${s.samples} proofs verified by the receiving node')),
                  ]),
                ],
              ],
            ),
            _Section(
              title: 'Seal integrity',
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(s.sensorHealthy ? Icons.lock : Icons.lock_open,
                      color: s.sensorHealthy ? Colors.green : Theme.of(context).colorScheme.error),
                  title: Text(s.sensorHealthy ? 'Sensor stream intact' : 'Tamper flag raised'),
                  subtitle: Text(s.sensorHealthy
                      ? 'GNSS, IMU and wheel odometer agree within 3σ; speed below 140 km/h.'
                      : 'Reason: ${t?.tamperReason}. The flag is signed into every later proof.'),
                ),
                if (t?.temperatureC != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.thermostat),
                    title: Text('Cargo temperature ${t!.temperatureC!.toStringAsFixed(1)} °C'),
                    subtitle: Text(s.escrow.excursionSeconds > 0
                        ? 'Outside SLA for ${(s.escrow.excursionSeconds / 60).toStringAsFixed(1)} min (limit 15 min)'
                        : 'Within SLA band'),
                  ),
              ],
            ),
            _Section(
              title: 'FASTag toll reconciliation',
              children: [
                Text('${s.tolls.length} of ${s.expectedTolls} planned plazas crossed'
                    '${s.tolls.length == s.expectedTolls ? ' · reconciled' : ''}'),
                const SizedBox(height: 4),
                if (s.tolls.isEmpty) const Text('No toll events yet.', style: TextStyle(fontSize: 12)),
                for (final e in s.tolls)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.toll),
                    title: Text(e.plaza),
                    subtitle: Text('${e.at.toLocal().toString().substring(0, 19)} · receipt ${e.receiptHash}'),
                    trailing: Text('₹${e.amountRupees}'),
                  ),
                const Text('Events are derived from map-matched passage through a toll edge and bound to the signed '
                    'position digest. Amounts are indicative; no FASTag network is contacted.',
                    style: TextStyle(fontSize: 11)),
              ],
            ),
            _Section(
              title: 'Escrow · ${s.escrow.state}',
              children: [
                _Row('Freight held', _rupees(s.escrow.freightHeldPaise)),
                _Row('Carrier collateral held', _rupees(s.escrow.collateralHeldPaise)),
                _Row('Paid to carrier', _rupees(s.escrow.paidToCarrierPaise)),
                _Row('Collateral returned', _rupees(s.escrow.returnedCollateralPaise)),
                _Row('SLA penalty to consignor', _rupees(s.escrow.refundedPaise)),
                if (s.escrow.locked)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('Funds are locked. The audit log below was routed to the arbitration node.',
                        style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                if (s.escrow.decision.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.escrow.decision)),
              ],
            ),
            _Section(
              title: 'Tamper-evident audit log',
              children: [
                Row(children: [
                  Icon(s.auditChainValid ? Icons.link : Icons.link_off,
                      color: s.auditChainValid ? Colors.green : Theme.of(context).colorScheme.error, size: 18),
                  const SizedBox(width: 6),
                  Expanded(child: Text(s.auditChainValid ? 'Hash chain intact (${s.audit.length} entries)' : 'Hash chain broken')),
                ]),
                for (final l in s.audit)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l.event),
                    subtitle: Text('${l.detail}\n#${l.hash.substring(0, 16)}'),
                    isThreeLine: true,
                  ),
              ],
            ),
          ]);
        },
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Card(
        margin: const EdgeInsets.only(top: 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...children,
          ]),
        ),
      );
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Flexible(child: Text(label)), const SizedBox(width: 12), Text(value)]),
      );
}

class _Mono extends StatelessWidget {
  const _Mono(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          SelectableText(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ]),
      );
}
