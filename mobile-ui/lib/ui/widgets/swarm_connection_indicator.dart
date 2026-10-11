import 'package:flutter/material.dart';

import '../../models/telemetry_node.dart';

class SwarmConnectionIndicator extends StatelessWidget {
  const SwarmConnectionIndicator({super.key, required this.path, this.peers = 0, this.queuedProofs = 0});

  final NetworkPath path;
  final int peers;
  final int queuedProofs;

  IconData get _icon => switch (path) {
        NetworkPath.fiveG => Icons.signal_cellular_alt,
        NetworkPath.sidelinkMesh => Icons.hub,
        NetworkPath.satelliteNtn => Icons.satellite_alt,
        NetworkPath.offline => Icons.signal_cellular_off,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = path == NetworkPath.offline ? scheme.error : scheme.primary;
    final details = [
      path.shortLabel,
      if (peers > 0) '$peers peer${peers == 1 ? '' : 's'}',
      if (queuedProofs > 0) '$queuedProofs queued',
    ].join(' · ');
    return Tooltip(
      message: path.label,
      child: Chip(
        avatar: Icon(_icon, color: color, size: 20),
        label: Text(details),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
