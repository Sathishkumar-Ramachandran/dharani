import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../state/call_cubit.dart';
import '../theme.dart';

String _clock(int s) => '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

/// Floats above every tab: ringing card for an incoming call, a status bar while calling or connected.
class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CallCubit, CallState>(
      builder: (context, s) {
        if (s.phase == CallPhase.idle) return const SizedBox.shrink();
        final bloc = context.read<CallCubit>();
        final scheme = Theme.of(context).colorScheme;
        final name = s.peerName.isEmpty ? 'your ride partner' : s.peerName;
        final (Color bg, Widget body) = switch (s.phase) {
          CallPhase.incoming => (
              Tokens.accent,
              Row(children: [
                const Icon(Icons.call_received, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(child: Text('Incoming call from $name', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16))),
                IconButton.filled(style: IconButton.styleFrom(backgroundColor: Tokens.danger), tooltip: 'Decline', onPressed: bloc.decline, icon: const Icon(Icons.call_end, color: Colors.white)),
                const SizedBox(width: 8),
                IconButton.filled(style: IconButton.styleFrom(backgroundColor: Tokens.success), tooltip: 'Answer', onPressed: bloc.accept, icon: const Icon(Icons.call, color: Colors.white)),
              ])
            ),
          CallPhase.calling => (
              scheme.inverseSurface,
              Row(children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                const SizedBox(width: 12),
                Expanded(child: Text('Calling $name…', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600))),
                IconButton.filled(style: IconButton.styleFrom(backgroundColor: Tokens.danger), tooltip: 'Cancel', onPressed: bloc.hangUp, icon: const Icon(Icons.call_end, color: Colors.white)),
              ])
            ),
          CallPhase.active => (
              Tokens.success,
              Row(children: [
                const Icon(Icons.call, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    Text('${_clock(s.seconds)} · ${s.interpreter ? 'interpreter on${s.lastRecognisedMs == null ? '' : ' · ${s.lastRecognisedMs} ms'}' : '↑${s.sent} ↓${s.received}'}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ]),
                ),
                IconButton(
                  tooltip: s.interpreter ? 'Interpreter on: tap to hear original voices' : 'Tap for live interpreter',
                  onPressed: () => bloc.setInterpreter(!s.interpreter),
                  icon: Icon(Icons.translate, color: s.interpreter ? Colors.yellowAccent : Colors.white),
                ),
                IconButton(tooltip: s.muted ? 'Unmute' : 'Mute', onPressed: bloc.toggleMute, icon: Icon(s.muted ? Icons.mic_off : Icons.mic, color: Colors.white)),
                IconButton(tooltip: 'Speaker', onPressed: bloc.toggleSpeaker, icon: Icon(s.speaker ? Icons.volume_up : Icons.hearing, color: Colors.white)),
                IconButton.filled(style: IconButton.styleFrom(backgroundColor: Tokens.danger), tooltip: 'End call', onPressed: bloc.hangUp, icon: const Icon(Icons.call_end, color: Colors.white)),
              ])
            ),
          _ => (scheme.inverseSurface, Row(children: [const Icon(Icons.call_end, color: Colors.white), const SizedBox(width: 12), Expanded(child: Text('Call ended${s.endReason == null ? '' : ' · ${s.endReason}'}', style: const TextStyle(color: Colors.white)))])),
        };
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Material(
              color: bg,
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: body),
            ),
          ),
        );
      },
    );
  }
}
