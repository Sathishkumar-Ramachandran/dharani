import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../state/call_cubit.dart';
import '../../state/conversation_cubit.dart';
import '../../state/translate_cubit.dart';
import '../../translate/languages.dart';
import 'ds.dart';

/// Live translated conversation with the other person on the ride.
class ConversationPanel extends StatefulWidget {
  const ConversationPanel({super.key});
  @override
  State<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends State<ConversationPanel> {
  final _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _label(String code) => langByCode(code).name;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final npu = context.select<TranslateCubit, bool>((c) => c.state.npuLoaded);
    final call = context.watch<CallCubit>().state;
    final tstate = context.watch<TranslateCubit>().state;
    return BlocBuilder<ConversationCubit, ConversationState>(
      builder: (context, s) {
        if (!s.active) return const SizedBox.shrink();
        final bloc = context.read<ConversationCubit>();
        final listening = s.phase == ConversationPhase.listening;
        final busy = s.phase == ConversationPhase.translating || s.phase == ConversationPhase.speaking;
        return AppCard(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: call.busy ? null : () => context.read<CallCubit>().call(rideId: s.rideId!, peerName: s.peerName),
                  icon: const Icon(Icons.call),
                  label: Text(call.busy ? 'In call' : 'Voice call ${s.peerName}'),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              const Icon(Icons.translate, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text('Live translation', style: t.textTheme.titleMedium)),
              IconButton(
                tooltip: s.muted ? 'Unmute spoken translation' : 'Mute spoken translation',
                onPressed: () => bloc.setMuted(!s.muted),
                icon: Icon(s.muted ? Icons.volume_off : Icons.volume_up),
              ),
            ]),
            Wrap(spacing: 8, runSpacing: 6, children: [
              Pill('You: ${_label(s.myLang)}', icon: Icons.person_outline),
              Pill('${s.peerName.isEmpty ? 'Other' : s.peerName}: ${_label(s.peerLang)}', icon: Icons.person),
              if (npu) const Pill('NPU speech recognition', icon: Icons.bolt, tone: PillTone.success),
            ]),
            const SizedBox(height: 10),
            if (!tstate.packsReadyFor(s.myLang, s.peerLang))
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InlineNotice(
                  tstate.error != null && tstate.downloading.isEmpty
                      ? 'Could not download the ${_label(s.myLang)}/${_label(s.peerLang)} translation packs: ${tstate.error}'
                      : 'Downloading the ${_label(s.myLang)} and ${_label(s.peerLang)} translation packs (internet needed once)…',
                  tone: tstate.error != null && tstate.downloading.isEmpty ? PillTone.danger : PillTone.warning,
                  action: tstate.error != null && tstate.downloading.isEmpty ? 'Retry' : null,
                  onAction: () => context.read<TranslateCubit>().ensureLanguagePacks([langByCode(s.myLang), langByCode(s.peerLang)]),
                ),
              ),
            if (s.bubbles.isEmpty)
              Text('Speak in ${_label(s.myLang)}. ${s.peerName.isEmpty ? 'They' : s.peerName} hears it in ${_label(s.peerLang)}, and the reply comes back in your language. Only text is sent, never audio.', style: t.textTheme.bodySmall)
            else
              for (final b in s.bubbles.reversed.take(5).toList().reversed) _BubbleView(bubble: b),
            if (s.error != null) Padding(padding: const EdgeInsets.only(top: 8), child: InlineNotice(s.error!, tone: PillTone.danger)),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: (busy || call.phase == CallPhase.active) ? null : (listening ? () => bloc.translate.stopCapture() : () => bloc.talkOnce()),
                  icon: Icon(listening ? Icons.stop_rounded : Icons.mic),
                  label: Text(switch (s.phase) {
                    ConversationPhase.idle => 'Tap to speak',
                    ConversationPhase.listening => 'Listening… tap to send',
                    ConversationPhase.translating => 'Translating…',
                    ConversationPhase.speaking => 'Playing reply…',
                  }),
                ),
              ),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Hands-free'),
              subtitle: const Text('Keeps listening and speaks replies automatically'),
              value: s.auto,
              onChanged: (v) => bloc.setAuto(v),
            ),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _text,
                  textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(hintText: 'Or type a message', isDense: true),
                  onSubmitted: (v) {
                    bloc.sendTyped(v);
                    _text.clear();
                  },
                ),
              ),
              IconButton(
                onPressed: () {
                  bloc.sendTyped(_text.text);
                  _text.clear();
                },
                icon: const Icon(Icons.send),
              ),
            ]),
          ]),
        );
      },
    );
  }
}

class _BubbleView extends StatelessWidget {
  const _BubbleView({required this.bubble});
  final Bubble bubble;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final mine = bubble.mine;
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: mine ? t.colorScheme.primary.withValues(alpha: 0.12) : t.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(mine ? bubble.text : bubble.translated, style: t.textTheme.bodyLarge),
          const SizedBox(height: 2),
          Text(mine ? '→ ${bubble.translated}' : bubble.text, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ]),
      ),
    );
  }
}
