import 'package:flutter/material.dart';

class AntiTamperBadge extends StatelessWidget {
  const AntiTamperBadge({super.key, required this.valid, this.reason, this.pending = false});

  final bool valid;
  final String? reason;
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color color = pending ? scheme.outline : (valid ? Colors.green.shade700 : scheme.error);
    final String text = pending
        ? 'Awaiting first proof'
        : valid
            ? 'Cryptographic proof valid'
            : 'Tamper alert${reason == null || reason == 'none' ? '' : ': $reason'}';
    return Semantics(
      label: text,
      child: Chip(
        avatar: Icon(pending ? Icons.hourglass_empty : (valid ? Icons.verified_user : Icons.gpp_bad), color: color, size: 20),
        label: Text(text),
        side: BorderSide(color: color.withValues(alpha: 0.5)),
        backgroundColor: color.withValues(alpha: 0.08),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
