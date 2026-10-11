import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/secure_storage.dart';
import '../translate/device_info.dart';
import '../translate/languages.dart';
import '../translate/model_manager.dart';
import '../translate/pipeline.dart';
import '../translate/qairt_backend.dart';
import '../translate/npu_asr.dart';

enum TranslatePhase { idle, listening, translating, speaking }

class Utterance {
  const Utterance(this.source, this.translated, this.src, this.tgt);
  final String source, translated;
  final Lang src, tgt;
}

/// One line of the "Enable on-device AI" checklist.
class AiStep {
  const AiStep(this.label, {this.fraction, this.done = false, this.error, this.note});
  final String label;
  final double? fraction; // null = indeterminate
  final bool done;
  final String? error, note;

  AiStep copyWith({double? fraction, bool? done, String? error, String? note, bool clearFraction = false}) => AiStep(label,
      fraction: clearFraction ? null : (fraction ?? this.fraction), done: done ?? this.done, error: error ?? this.error, note: note ?? this.note);
}

enum AiSetupPhase { idle, running, ready, partial, failed }

class TranslateState {
  const TranslateState({
    this.aiPhase = AiSetupPhase.idle,
    this.aiSteps = const [],
    this.aiSummary,
    this.npuLoaded = false,
    this.lastTiming,
    required this.src,
    required this.tgt,
    this.phase = TranslatePhase.idle,
    this.partial = '',
    this.history = const [],
    this.packs = const {},
    this.downloading = const {},
    this.device = const DeviceInfo(),
    this.qairt,
    this.modelProgress = const {},
    this.error,
    this.onDevice = true,
    this.autoSpeak = true,
  });

  final AiSetupPhase aiPhase;
  final List<AiStep> aiSteps;
  final String? aiSummary;
  final bool npuLoaded;
  final String? lastTiming;
  final Lang src, tgt;
  final TranslatePhase phase;
  final String partial;
  final List<Utterance> history;
  final Map<String, bool> packs;
  final Set<String> downloading;
  final DeviceInfo device;
  final QairtStatus? qairt;
  final Map<String, double> modelProgress;
  final String? error;
  final bool onDevice, autoSpeak;

  bool packReady(Lang l) => packs[l.code] ?? false;
  bool packsReadyFor(String a, String b) => (packs[a] ?? false) && (packs[b] ?? false);

  TranslateState copyWith({
    AiSetupPhase? aiPhase,
    List<AiStep>? aiSteps,
    String? aiSummary,
    bool? npuLoaded,
    String? lastTiming,
    Lang? src,
    Lang? tgt,
    TranslatePhase? phase,
    String? partial,
    List<Utterance>? history,
    Map<String, bool>? packs,
    Set<String>? downloading,
    DeviceInfo? device,
    QairtStatus? qairt,
    Map<String, double>? modelProgress,
    String? error,
    bool clearError = false,
    bool? onDevice,
    bool? autoSpeak,
  }) =>
      TranslateState(
        aiPhase: aiPhase ?? this.aiPhase,
        aiSteps: aiSteps ?? this.aiSteps,
        aiSummary: aiSummary ?? this.aiSummary,
        npuLoaded: npuLoaded ?? this.npuLoaded,
        lastTiming: lastTiming ?? this.lastTiming,
        src: src ?? this.src,
        tgt: tgt ?? this.tgt,
        phase: phase ?? this.phase,
        partial: partial ?? this.partial,
        history: history ?? this.history,
        packs: packs ?? this.packs,
        downloading: downloading ?? this.downloading,
        device: device ?? this.device,
        qairt: qairt ?? this.qairt,
        modelProgress: modelProgress ?? this.modelProgress,
        error: clearError ? null : (error ?? this.error),
        onDevice: onDevice ?? this.onDevice,
        autoSpeak: autoSpeak ?? this.autoSpeak,
      );
}

/// Speech-to-speech translation: listen -> translate -> speak, fully on the phone.
class TranslateCubit extends Cubit<TranslateState> {
  TranslateCubit({required this.pipeline, required this.models, required this.npu, DeviceInfo? device, SecureStore? store, this.bundledManifest})
      : _deviceOverride = device,
        _store = store ?? SecureStore(),
        super(TranslateState(src: langByCode('hi'), tgt: langByCode('en')));

  final OnDevicePipeline pipeline;
  final ModelManager models;
  final DeviceInfo? _deviceOverride;
  final SecureStore _store;
  final NpuAsr npu;

  /// JSON shipped with the app (assets/ai_pack.json); installed when no manifest exists yet.
  final String? bundledManifest;
  static const manifestUrlKey = 'ai_manifest_url';
  StreamSubscription<({String text, bool isFinal})>? _listenSub;
  late final QairtBackend _qairt;

  Future<void> init() async {
    final device = _deviceOverride ?? await DeviceInfo.read();
    if (bundledManifest != null && (await models.loadManifest()).isEmpty) {
      await models.saveManifestText(bundledManifest!);
    }
    _qairt = QairtBackend(models: models, device: device, npu: npu);
    emit(state.copyWith(device: device));
    await refreshPacks();
    await refreshQairt();
    // Models downloaded earlier: bring the NPU engine back up without another tap.
    if (state.qairt?.available == true) {
      try {
        await npu.load();
        emit(state.copyWith(npuLoaded: true, aiPhase: AiSetupPhase.ready, aiSummary: 'NPU ready: speech recognition runs on the Snapdragon Hexagon NPU.'));
      } catch (_) {}
    }
  }

  Future<void> refreshQairt() async => emit(state.copyWith(qairt: await _qairt.probe()));

  Future<void> refreshPacks() async {
    final packs = <String, bool>{};
    for (final l in kLanguages) {
      try {
        packs[l.code] = await pipeline.isPackReady(l);
      } catch (_) {
        packs[l.code] = false;
      }
    }
    emit(state.copyWith(packs: packs));
  }

  void setSource(Lang l) {
    if (l.code == state.tgt.code) return swap();
    emit(state.copyWith(src: l, clearError: true));
  }

  void setTarget(Lang l) {
    if (l.code == state.src.code) return swap();
    emit(state.copyWith(tgt: l, clearError: true));
  }

  void swap() => emit(state.copyWith(src: state.tgt, tgt: state.src, clearError: true));

  void setAutoSpeak(bool v) => emit(state.copyWith(autoSpeak: v));

  Future<void> downloadPack(Lang l) async {
    if (state.downloading.contains(l.code)) return;
    emit(state.copyWith(downloading: {...state.downloading, l.code}, clearError: true));
    try {
      await pipeline.downloadPack(l);
      emit(state.copyWith(packs: {...state.packs, l.code: true}));
    } on PipelineException catch (e) {
      emit(state.copyWith(error: e.message));
    } catch (e) {
      emit(state.copyWith(error: 'Pack download failed: $e'));
    } finally {
      emit(state.copyWith(downloading: {...state.downloading}..remove(l.code)));
    }
  }

  /// Downloads the packs for the selected pair, then they work without network.
  Future<void> prepareSelected() async {
    for (final l in [state.src, state.tgt]) {
      if (!state.packReady(l)) await downloadPack(l);
    }
  }

  // ---- one-tap setup ----
  /// Downloads and enables everything this phone can use, in order:
  /// 1. ML Kit language packs for the selected pair (works offline afterwards),
  /// 2. the QAIRT runtime and models from the manifest (checksummed, resumable),
  /// 3. activation of the runtime libraries.
  /// The result is reported truthfully: the Android engine can be ready while the NPU engine is not.
  Future<void> enableOnDeviceAi() async {
    if (state.aiPhase == AiSetupPhase.running) return;
    var steps = <AiStep>[];
    void push() => emit(state.copyWith(aiSteps: List.of(steps), aiPhase: AiSetupPhase.running));
    void update(int i, AiStep s) {
      steps[i] = s;
      push();
    }

    emit(state.copyWith(aiPhase: AiSetupPhase.running, aiSteps: const [AiStep('Preparing…')], clearError: true));
    try {
      // Refresh the manifest when a URL was saved.
      final url = await _store.read(manifestUrlKey);
      if (url != null && url.isNotEmpty) {
        try {
          await models.fetchManifest(url);
        } catch (e) {
          steps = [AiStep('Model manifest', error: '$e')];
          push();
        }
      }
      final specs = await _qairt.applicable();
      steps = [
        ...steps,
        AiStep('Language packs: ${state.src.name} + ${state.tgt.name}'),
        for (final m in specs) AiStep('Download: ${m.name}'),
        if (specs.isNotEmpty) const AiStep('Load speech model on the NPU'),
      ];
      push();
      final base = steps.indexWhere((s) => s.label.startsWith('Language packs'));

      // 1. language packs
      for (final l in [state.src, state.tgt]) {
        if (!state.packReady(l)) await downloadPack(l);
      }
      final packsOk = state.packReady(state.src) && state.packReady(state.tgt);
      update(base, steps[base].copyWith(done: packsOk, error: packsOk ? null : (state.error ?? 'Download failed'), fraction: 1.0));

      // 2. runtime + models
      for (var i = 0; i < specs.length; i++) {
        final idx = base + 1 + i;
        try {
          await for (final p in models.download(specs[i])) {
            update(idx, steps[idx].copyWith(fraction: p.verifying ? 0.999 : p.fraction, note: p.verifying ? 'Verifying checksum…' : null));
          }
          update(idx, steps[idx].copyWith(done: true, fraction: 1.0));
        } on ModelException catch (e) {
          update(idx, steps[idx].copyWith(error: e.message));
        } catch (e) {
          update(idx, steps[idx].copyWith(error: '$e'));
        }
      }

      // 3. load on the NPU
      if (specs.isNotEmpty) {
        final idx = steps.length - 1;
        final q = await _qairt.probe();
        if (!q.available) {
          update(idx, steps[idx].copyWith(error: q.reasons.first, fraction: 1.0));
        } else {
          try {
            final ms = await npu.load();
            emit(state.copyWith(npuLoaded: true));
            update(idx, steps[idx].copyWith(done: true, fraction: 1.0, note: 'Loaded in $ms ms'));
          } catch (e) {
            update(idx, steps[idx].copyWith(error: 'NPU could not load the model: $e', fraction: 1.0));
          }
        }
      }

      await refreshPacks();
      await refreshQairt();
      final npuOk = state.qairt?.available == true && state.npuLoaded;
      final summary = npuOk
          ? 'NPU ready: speech recognition runs on the Snapdragon Hexagon NPU. Translation and voice use Android on-device engines.'
          : packsOk
              ? 'Offline translation is ready (Android on-device). NPU engine not active: ${state.qairt?.reasons.isEmpty == false ? state.qairt!.reasons.first : 'setup incomplete'}'
              : 'Setup incomplete. Fix the items marked in red and tap again; finished downloads are kept.';
      emit(state.copyWith(
          aiPhase: npuOk ? AiSetupPhase.ready : (packsOk ? AiSetupPhase.partial : AiSetupPhase.failed),
          aiSummary: summary));
    } catch (e) {
      emit(state.copyWith(aiPhase: AiSetupPhase.failed, aiSummary: 'Setup failed: $e'));
    }
  }

  /// Removes downloaded runtime/model files (language packs are managed by Google Play services).
  Future<void> removeDownloads() async {
    try {
      await npu.release();
    } catch (_) {}
    emit(state.copyWith(npuLoaded: false));
    for (final m in await models.loadManifest()) {
      await models.delete(m);
    }
    emit(state.copyWith(aiPhase: AiSetupPhase.idle, aiSteps: const [], aiSummary: null));
    await refreshQairt();
  }

  Future<void> saveManifestUrl(String url) async {
    await _store.write(manifestUrlKey, url.trim());
  }

  // ---- QAIRT model downloads ----
  Future<void> importManifest(String url) async {
    try {
      await saveManifestUrl(url);
      await models.fetchManifest(url.trim());
      await refreshQairt();
    } on ModelException catch (e) {
      emit(state.copyWith(error: e.message));
    } catch (e) {
      emit(state.copyWith(error: 'Could not read the manifest: $e'));
    }
  }

  Future<void> downloadModel(ModelSpec spec) async {
    emit(state.copyWith(modelProgress: {...state.modelProgress, spec.id: 0}, clearError: true));
    try {
      await for (final p in models.download(spec)) {
        emit(state.copyWith(modelProgress: {...state.modelProgress, spec.id: p.verifying ? 0.999 : p.fraction}));
      }
    } on ModelException catch (e) {
      emit(state.copyWith(error: '${spec.name}: ${e.message}'));
    } catch (e) {
      emit(state.copyWith(error: '${spec.name}: $e'));
    } finally {
      emit(state.copyWith(modelProgress: {...state.modelProgress}..remove(spec.id)));
      await refreshQairt();
    }
  }

  // ---- conversation ----
  Future<void> toggleListening() async {
    if (state.phase == TranslatePhase.listening) {
      if (state.npuLoaded) {
        await npu.stopRecording();
      } else {
        await pipeline.stopListening();
      }
      return;
    }
    if (state.phase != TranslatePhase.idle) return;
    if (state.npuLoaded) return _listenOnNpu();
    emit(state.copyWith(phase: TranslatePhase.listening, partial: '', clearError: true));
    final done = Completer<String>();
    var last = '';
    await _listenSub?.cancel();
    _listenSub = pipeline.listen(state.src).listen(
      (e) {
        last = e.text;
        emit(state.copyWith(partial: e.text));
        if (e.isFinal && !done.isCompleted) done.complete(e.text);
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(last);
      },
    );
    try {
      final text = (await done.future.timeout(const Duration(seconds: 40), onTimeout: () => last)).trim();
      if (text.isEmpty) {
        emit(state.copyWith(phase: TranslatePhase.idle, error: 'I did not hear anything. Tap the mic and speak.'));
        return;
      }
      await _translateAndSpeak(text);
    } on PipelineException catch (e) {
      emit(state.copyWith(phase: TranslatePhase.idle, error: e.message));
    } catch (e) {
      emit(state.copyWith(phase: TranslatePhase.idle, error: '$e'));
    }
  }

  /// Whisper-Small on the Hexagon NPU. English as the target uses Whisper's own translate task, so
  /// source speech -> English text is a single NPU pass; other targets use ML Kit afterwards.
  Future<void> _listenOnNpu() async {
    emit(state.copyWith(phase: TranslatePhase.listening, partial: 'Listening…', clearError: true));
    try {
      if (!await npu.ensureMic()) {
        emit(state.copyWith(phase: TranslatePhase.idle, error: 'Microphone permission is needed.'));
        return;
      }
      final toEnglish = state.tgt.code == 'en' && state.src.code != 'en';
      final r = await npu.listen(lang: state.src.code, translate: toEnglish);
      if (r.text.trim().isEmpty) {
        emit(state.copyWith(phase: TranslatePhase.idle, partial: '', error: 'I did not hear anything. Tap the mic and speak.'));
        return;
      }
      emit(state.copyWith(lastTiming: 'NPU: features ${r.melMs} ms · encoder ${r.encoderMs} ms · decode ${r.decodeMs} ms (${r.tokens} tokens)'));
      await _translateAndSpeak(r.text.trim(), alreadyTranslated: toEnglish);
    } catch (e) {
      emit(state.copyWith(phase: TranslatePhase.idle, partial: '', error: 'NPU speech recognition failed: $e'));
    }
  }

  // ---- building blocks for the live ride conversation (do not touch the Translate tab's own state) ----
  /// Captures one utterance in [src] and returns the recognised text ('' when nothing was said).
  /// Uses the NPU Whisper engine when loaded, otherwise Android's recognizer.
  Future<String> captureUtterance(Lang src, {int maxSeconds = 20}) async {
    if (state.npuLoaded) {
      if (!await npu.ensureMic()) throw PipelineException('Microphone permission is needed.');
      final r = await npu.listen(lang: src.code, translate: false, maxSeconds: maxSeconds);
      return r.text.trim();
    }
    final done = Completer<String>();
    var last = '';
    final sub = pipeline.listen(src, maxDuration: Duration(seconds: maxSeconds)).listen(
      (e) {
        last = e.text;
        if (e.isFinal && !done.isCompleted) done.complete(e.text);
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(last);
      },
    );
    try {
      return (await done.future.timeout(Duration(seconds: maxSeconds + 10), onTimeout: () => last)).trim();
    } finally {
      await sub.cancel();
    }
  }

  Future<String> translatePlain(String text, Lang src, Lang tgt) => pipeline.translate(text, src, tgt);

  bool packsReadyFor(String a, String b) => state.packsReadyFor(a, b);

  /// Makes sure the on-device translation packs for a conversation's two languages are present
  /// (needs the internet once per language). Safe to call repeatedly.
  Future<void> ensureLanguagePacks(List<Lang> langs) async {
    await refreshPacks();
    for (final l in langs) {
      if (!state.packReady(l)) await downloadPack(l);
    }
  }

  Future<void> speakText(String text, Lang lang) => pipeline.speak(text, lang);

  Future<void> stopCapture() async {
    if (state.npuLoaded) {
      await npu.stopRecording();
    } else {
      await pipeline.stopListening();
    }
  }

  /// Also used by typed input.
  Future<void> translateText(String text) => _translateAndSpeak(text.trim());

  Future<void> _translateAndSpeak(String text, {bool alreadyTranslated = false}) async {
    if (text.isEmpty) return;
    final src = state.src, tgt = state.tgt;
    emit(state.copyWith(phase: TranslatePhase.translating, partial: text));
    try {
      final out = alreadyTranslated ? text : await pipeline.translate(text, src, tgt);
      emit(state.copyWith(history: [Utterance(text, out, src, tgt), ...state.history], partial: ''));
      if (state.autoSpeak) {
        emit(state.copyWith(phase: TranslatePhase.speaking));
        await pipeline.speak(out, tgt);
      }
      emit(state.copyWith(phase: TranslatePhase.idle));
    } on PipelineException catch (e) {
      emit(state.copyWith(phase: TranslatePhase.idle, error: e.message));
    } catch (e) {
      emit(state.copyWith(phase: TranslatePhase.idle, error: '$e'));
    }
  }

  Future<void> replay(Utterance u) async {
    if (state.phase != TranslatePhase.idle) return;
    emit(state.copyWith(phase: TranslatePhase.speaking));
    try {
      await pipeline.speak(u.translated, u.tgt);
    } finally {
      emit(state.copyWith(phase: TranslatePhase.idle));
    }
  }

  @override
  Future<void> close() async {
    await _listenSub?.cancel();
    return super.close();
  }
}
