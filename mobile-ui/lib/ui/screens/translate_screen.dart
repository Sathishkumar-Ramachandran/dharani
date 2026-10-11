import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../state/translate_cubit.dart';
import '../../translate/languages.dart';
import '../theme.dart';
import '../widgets/ds.dart';

/// Speech-to-speech translation. Everything runs on the phone.
class TranslateScreen extends StatelessWidget {
  const TranslateScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return BlocBuilder<TranslateCubit, TranslateState>(
      builder: (context, s) {
        final bloc = context.read<TranslateCubit>();
        final needPacks = !(s.packReady(s.src) && s.packReady(s.tgt));
        return Scaffold(
          appBar: AppBar(title: const Text('Translate')),
          body: ListView(
            padding: const EdgeInsets.all(Tokens.pad),
            children: [
              Text('Talk across languages', style: t.textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('Speak in your language. Your driver, shipper or passenger hears it in theirs.',
                  style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
              const SizedBox(height: Tokens.gap + 4),
              _SetupCard(state: s),
              const SizedBox(height: Tokens.gap),
              Row(children: [
                Expanded(child: _LangPicker(label: 'I speak', value: s.src, onChanged: bloc.setSource)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: IconButton.filledTonal(onPressed: bloc.swap, icon: const Icon(Icons.swap_horiz), tooltip: 'Swap languages'),
                ),
                Expanded(child: _LangPicker(label: 'They hear', value: s.tgt, onChanged: bloc.setTarget)),
              ]),
              const SizedBox(height: Tokens.gap),
              if (s.error != null) ...[InlineNotice(s.error!, tone: PillTone.danger), const SizedBox(height: Tokens.gap)],
              if (needPacks) ...[
                InlineNotice(
                  'Download the ${s.src.name} and ${s.tgt.name} language packs once. After that, translation works without internet.',
                  tone: PillTone.warning,
                  action: s.downloading.isEmpty ? 'Download' : null,
                  onAction: bloc.prepareSelected,
                ),
                if (s.downloading.isNotEmpty) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                const SizedBox(height: Tokens.gap),
              ],
              AppCard(
                child: Column(children: [
                  const SizedBox(height: 8),
                  _MicButton(phase: s.phase, onPressed: bloc.toggleListening),
                  const SizedBox(height: 12),
                  Text(
                    switch (s.phase) {
                      TranslatePhase.idle => 'Tap to speak',
                      TranslatePhase.listening => 'Listening… tap to finish',
                      TranslatePhase.translating => 'Translating…',
                      TranslatePhase.speaking => 'Speaking…',
                    },
                    style: t.textTheme.titleMedium,
                  ),
                  if (s.partial.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.partial, textAlign: TextAlign.center, style: t.textTheme.bodyLarge)),
                  if (s.lastTiming != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(s.lastTiming!, style: t.textTheme.labelSmall, textAlign: TextAlign.center)),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Speak the translation'),
                    value: s.autoSpeak,
                    onChanged: bloc.setAutoSpeak,
                  ),
                ]),
              ),
              if (s.history.isNotEmpty) ...[
                const SizedBox(height: Tokens.gap + 4),
                const SectionTitle('Conversation'),
                const SizedBox(height: 8),
                for (final u in s.history)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppCard(
                      onTap: () => bloc.replay(u),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('${u.src.name} · ${u.source}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                        const SizedBox(height: 6),
                        Row(children: [
                          Expanded(child: Text(u.translated, style: t.textTheme.titleMedium)),
                          const Icon(Icons.volume_up_outlined, size: 20),
                        ]),
                        Text(u.tgt.name, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.primary)),
                      ]),
                    ),
                  ),
              ],
              const SizedBox(height: Tokens.gap + 4),
              _EngineCard(state: s),
            ],
          ),
        );
      },
    );
  }
}

class _LangPicker extends StatelessWidget {
  const _LangPicker({required this.label, required this.value, required this.onChanged});
  final String label;
  final Lang value;
  final void Function(Lang) onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () async {
        final picked = await showModalBottomSheet<Lang>(
          context: context,
          showDragHandle: true,
          builder: (_) => SafeArea(
            child: ListView(shrinkWrap: true, children: [
              for (final l in kLanguages)
                ListTile(
                  title: Text(l.name),
                  subtitle: Text(l.native),
                  trailing: l.code == value.code ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.pop(context, l),
                ),
            ]),
          ),
        );
        if (picked != null) onChanged(picked);
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(border: Border.all(color: t.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(value.name, style: t.textTheme.titleMedium),
          Text(value.native, style: t.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

class _MicButton extends StatelessWidget {
  const _MicButton({required this.phase, required this.onPressed});
  final TranslatePhase phase;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    final listening = phase == TranslatePhase.listening;
    final busy = phase == TranslatePhase.translating || phase == TranslatePhase.speaking;
    return GestureDetector(
      onTap: busy ? null : onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: listening ? Tokens.danger : s.primary,
          boxShadow: [BoxShadow(color: (listening ? Tokens.danger : s.primary).withValues(alpha: 0.35), blurRadius: listening ? 28 : 12, spreadRadius: listening ? 6 : 0)],
        ),
        child: busy
            ? const Padding(padding: EdgeInsets.all(30), child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3))
            : Icon(listening ? Icons.stop_rounded : Icons.mic, color: Colors.white, size: 44),
      ),
    );
  }
}

/// Explains which engine is running and what the QAIRT (Snapdragon NPU) backend still needs.
class _EngineCard extends StatelessWidget {
  const _EngineCard({required this.state});
  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bloc = context.read<TranslateCubit>();
    final q = state.qairt;
    final urlCtl = TextEditingController();
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const SectionTitle('Translation engine'),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, children: [
          Pill('${state.device.chipName}${state.device.model.isEmpty ? '' : ' · ${state.device.model}'}', icon: Icons.memory),
          Pill('Android on-device', icon: Icons.phone_android, tone: PillTone.success),
          Pill(state.npuLoaded ? 'NPU speech engine active' : 'NPU speech engine off', icon: Icons.bolt, tone: state.npuLoaded ? PillTone.success : PillTone.warning),
        ]),
        const SizedBox(height: 10),
        Text(
          'Speech recognition runs on the Snapdragon Hexagon NPU (Whisper-Small via Qualcomm AI Runtime) once the model below is downloaded. '
          'Translation and voice use Android’s on-device engines. Without the NPU model, Android’s recognizer is used.',
          style: t.textTheme.bodySmall,
        ),
        if (q != null && !q.available) ...[
          const SizedBox(height: 10),
          for (final r in q.reasons) Padding(padding: const EdgeInsets.only(bottom: 4), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.circle, size: 6), const SizedBox(width: 8), Expanded(child: Text(r, style: t.textTheme.bodySmall))])),
        ],
        if (q != null && q.missingModels.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final m in q.missingModels)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(m.name),
              subtitle: state.modelProgress.containsKey(m.id)
                  ? Padding(padding: const EdgeInsets.only(top: 6), child: LinearProgressIndicator(value: state.modelProgress[m.id]))
                  : Text('${m.kind.toUpperCase()} · ${(m.sizeBytes / 1048576).toStringAsFixed(0)} MB'),
              trailing: state.modelProgress.containsKey(m.id) ? null : TextButton(onPressed: () => bloc.downloadModel(m), child: const Text('Download')),
            ),
        ],
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          shape: const Border(),
          collapsedShape: const Border(),
          title: const Text('Model manifest'),
          children: [
            TextField(controller: urlCtl, decoration: const InputDecoration(hintText: 'https://…/models.json')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => bloc.importManifest(urlCtl.text), child: const Text('Import manifest')),
          ],
        ),
        const Divider(),
        const SizedBox(height: 8),
        Text('Language packs', style: t.textTheme.labelLarge),
        const SizedBox(height: 6),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final l in kLanguages)
            ActionChip(
              avatar: state.downloading.contains(l.code)
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(state.packReady(l) ? Icons.check_circle : Icons.download, size: 16, color: state.packReady(l) ? Tokens.success : null),
              label: Text(l.name),
              onPressed: state.packReady(l) ? null : () => bloc.downloadPack(l),
            ),
        ]),
      ]),
    );
  }
}

/// One tap: download language packs, runtime and models, then activate them.
class _SetupCard extends StatelessWidget {
  const _SetupCard({required this.state});
  final TranslateState state;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final bloc = context.read<TranslateCubit>();
    final running = state.aiPhase == AiSetupPhase.running;
    final (IconData icon, Color color, String title) = switch (state.aiPhase) {
      AiSetupPhase.idle => (Icons.download_for_offline_outlined, t.colorScheme.primary, 'Enable on-device AI'),
      AiSetupPhase.running => (Icons.downloading, t.colorScheme.primary, 'Setting up…'),
      AiSetupPhase.ready => (Icons.bolt, Tokens.success, 'NPU engine ready'),
      AiSetupPhase.partial => (Icons.check_circle_outline, Tokens.warning, 'Offline translation ready'),
      AiSetupPhase.failed => (Icons.error_outline, Tokens.danger, 'Setup incomplete'),
    };
    return AppCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: color),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: t.textTheme.titleMedium)),
        ]),
        const SizedBox(height: 6),
        Text(
          state.aiSummary ?? 'Downloads the language packs, the Qualcomm runtime and the speech models for your phone, verifies them, and turns them on. Wi-Fi recommended.',
          style: t.textTheme.bodySmall,
        ),
        for (final step in state.aiSteps) ...[
          const SizedBox(height: 10),
          Row(children: [
            SizedBox(
              width: 20,
              height: 20,
              child: step.error != null
                  ? const Icon(Icons.error, size: 20, color: Tokens.danger)
                  : step.done
                      ? const Icon(Icons.check_circle, size: 20, color: Tokens.success)
                      : CircularProgressIndicator(strokeWidth: 2, value: step.fraction),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(step.label, style: t.textTheme.bodyMedium)),
            if (!step.done && step.error == null && step.fraction != null) Text('${(step.fraction! * 100).toStringAsFixed(0)}%', style: t.textTheme.labelMedium),
          ]),
          if (step.error != null) Padding(padding: const EdgeInsets.only(left: 30, top: 2), child: Text(step.error!, style: t.textTheme.bodySmall?.copyWith(color: Tokens.danger))),
          if (step.note != null && step.error == null) Padding(padding: const EdgeInsets.only(left: 30, top: 2), child: Text(step.note!, style: t.textTheme.bodySmall)),
        ],
        const SizedBox(height: 14),
        FilledButton.icon(
          onPressed: running ? null : bloc.enableOnDeviceAi,
          icon: Icon(state.aiPhase == AiSetupPhase.idle ? Icons.download : Icons.refresh),
          label: Text(running ? 'Working…' : (state.aiPhase == AiSetupPhase.idle ? 'Download & enable' : 'Check again / resume')),
        ),
        if (!running && state.aiPhase != AiSetupPhase.idle)
          TextButton(onPressed: bloc.removeDownloads, child: const Text('Remove downloaded runtime & models')),
      ]),
    );
  }
}
