import 'dart:async';

import 'package:dharani_protocol/dharani_protocol.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../translate/languages.dart';
import '../translate/pipeline.dart';
import 'session_cubit.dart';
import 'translate_cubit.dart';

enum ConversationPhase { idle, listening, translating, speaking }

class Bubble {
  const Bubble({required this.mine, required this.text, required this.translated, required this.srcLang, required this.tgtLang, required this.at});
  final bool mine;
  final String text, translated, srcLang, tgtLang;
  final DateTime at;
}

class ConversationState {
  const ConversationState({this.rideId, this.myLang = 'en', this.peerLang = 'en', this.peerName = '', this.bubbles = const [], this.phase = ConversationPhase.idle, this.auto = false, this.error, this.muted = false});
  final String? rideId;
  final String myLang, peerLang, peerName;
  final List<Bubble> bubbles;
  final ConversationPhase phase;
  final bool auto, muted;
  final String? error;

  bool get active => rideId != null;

  ConversationState copyWith({String? rideId, String? myLang, String? peerLang, String? peerName, List<Bubble>? bubbles, ConversationPhase? phase, bool? auto, bool? muted, String? error, bool clearError = false, bool clearRide = false}) => ConversationState(
        rideId: clearRide ? null : (rideId ?? this.rideId),
        myLang: myLang ?? this.myLang,
        peerLang: peerLang ?? this.peerLang,
        peerName: peerName ?? this.peerName,
        bubbles: bubbles ?? this.bubbles,
        phase: phase ?? this.phase,
        auto: auto ?? this.auto,
        muted: muted ?? this.muted,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Live translated conversation between rider and driver. Each phone recognises its owner's speech
/// (NPU Whisper when available), translates it into the other person's language, and sends only text
/// over the socket; the receiver speaks it. No audio ever leaves a phone.
class ConversationCubit extends Cubit<ConversationState> {
  ConversationCubit({required this.session, required this.translate}) : super(const ConversationState()) {
    _sub = session.messages.listen(_onMessage);
    // The owner switched language in Account: speak/hear the new one from the next sentence.
    _profileSub = session.stream.map((s) => s.profile?.lang).distinct().listen((l) {
      if (l != null) setMyLang(l);
    });
  }

  StreamSubscription<String?>? _profileSub;

  void setMyLang(String lang) {
    if (lang == state.myLang) return;
    emit(state.copyWith(myLang: lang));
    if (state.active) unawaited(translate.ensureLanguagePacks([langByCode(lang), langByCode(state.peerLang)]));
  }

  final SessionCubit session;
  final TranslateCubit translate;
  late final StreamSubscription<Json> _sub;

  int _seq = 0;
  bool _loopRunning = false;

  /// Starts (or keeps) the conversation for a ride that has a counterpart.
  void bind({required String rideId, required String myLang, required String peerLang, required String peerName}) {
    if (state.rideId == rideId && state.peerLang == peerLang) return;
    emit(ConversationState(rideId: rideId, myLang: myLang, peerLang: peerLang, peerName: peerName, auto: state.rideId == rideId ? state.auto : false));
    // Translation needs both language packs on this phone; fetch what is missing right away.
    unawaited(translate.ensureLanguagePacks([langByCode(myLang), langByCode(peerLang)]));
  }

  Future<void> unbind() async {
    await setAuto(false);
    emit(const ConversationState());
  }

  void setMuted(bool v) => emit(state.copyWith(muted: v));

  Future<void>? _loop;

  /// Hands-free mode: keep listening, send each sentence, pause while the other side's voice plays.
  /// Returns as soon as the mode is switched; turning it off waits for the current sentence to finish.
  Future<void> setAuto(bool on) async {
    emit(state.copyWith(auto: on, clearError: true));
    if (!on) {
      if (state.phase == ConversationPhase.listening) await translate.stopCapture();
      await _loop?.timeout(const Duration(seconds: 5), onTimeout: () {});
      return;
    }
    if (_loopRunning) return;
    _loopRunning = true;
    _loop = _autoLoop();
  }

  Future<void> _autoLoop() async {
    try {
      while (state.auto && state.active) {
        final ok = await talkOnce();
        if (!ok) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    } finally {
      _loopRunning = false;
      if (state.phase == ConversationPhase.listening) emit(state.copyWith(phase: ConversationPhase.idle));
    }
  }

  /// Listens for one sentence, translates and sends it. Returns false when the loop should stop (error).
  Future<bool> talkOnce() async {
    final rideId = state.rideId;
    if (rideId == null) return true;
    // Never listen while the other person's voice is playing (the mic would transcribe the speaker).
    for (var i = 0; i < 200 && state.phase == ConversationPhase.speaking; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (state.phase != ConversationPhase.idle) return true;
    final my = langByCode(state.myLang), peer = langByCode(state.peerLang);
    emit(state.copyWith(phase: ConversationPhase.listening, clearError: true));
    try {
      final text = await translate.captureUtterance(my);
      if (text.isEmpty || state.rideId != rideId) {
        emit(state.copyWith(phase: ConversationPhase.idle));
        return true; // silence: keep listening in auto mode
      }
      return await _sendText(text, my, peer);
    } on PipelineException catch (e) {
      emit(state.copyWith(phase: ConversationPhase.idle, auto: false, error: e.message));
      return false;
    } catch (e) {
      emit(state.copyWith(phase: ConversationPhase.idle, auto: false, error: 'Speech recognition failed: $e'));
      return false;
    }
  }

  /// A sentence recognised from the call's microphone (interpreter mode): translate, send, show.
  Future<void> sendRecognized(String text) async {
    final t = text.trim();
    if (t.isEmpty || !state.active) return;
    await _sendText(t, langByCode(state.myLang), langByCode(state.peerLang));
  }

  /// Typed message (accessibility / noisy cabin).
  Future<void> sendTyped(String text) async {
    final t = text.trim();
    if (t.isEmpty || !state.active || state.phase != ConversationPhase.idle) return;
    await _sendText(t, langByCode(state.myLang), langByCode(state.peerLang));
  }

  Future<bool> _sendText(String text, Lang my, Lang peer) async {
    final rideId = state.rideId!;
    emit(state.copyWith(phase: ConversationPhase.translating));
    try {
      final translated = my.code == peer.code ? text : await translate.translatePlain(text, my, peer);
      session.send({'t': T.chatUtterance, 'rideId': rideId, 'text': text, 'translated': translated, 'srcLang': my.code, 'tgtLang': peer.code, 'seq': ++_seq});
      emit(state.copyWith(phase: ConversationPhase.idle, bubbles: [...state.bubbles, Bubble(mine: true, text: text, translated: translated, srcLang: my.code, tgtLang: peer.code, at: DateTime.now())]));
      return true;
    } on PipelineException catch (e) {
      debugPrint('CONVO send failed: ${e.message}');
      emit(state.copyWith(phase: ConversationPhase.idle, auto: false, error: e.message));
      return false;
    }
  }

  Future<void> _onMessage(Json m) async {
    if (m['t'] == T.peerLang && m['rideId'] == state.rideId) {
      final l = m['lang'];
      if (l is String && kLanguages.any((x) => x.code == l) && l != state.peerLang) {
        emit(state.copyWith(peerLang: l));
        unawaited(translate.ensureLanguagePacks([langByCode(state.myLang), langByCode(l)]));
      }
      return;
    }
    if (m['t'] != T.chatUtterance || m['rideId'] != state.rideId) return;
    final my = langByCode(state.myLang);
    debugPrint('CONVO received ${m['srcLang']}->${m['tgtLang']}: ${m['text']} => ${m['translated']}');
    var text = m['translated'] as String? ?? '';
    final src = m['srcLang'] as String, tgt = m['tgtLang'] as String;
    try {
      // The sender translated for the language it knows for us; if our language changed meanwhile, redo it here.
      if (tgt != my.code || text.isEmpty) {
        text = src == my.code ? (m['text'] as String) : await translate.translatePlain(m['text'] as String, langByCode(src), my);
      }
    } on PipelineException {
      text = m['text'] as String;
    }
    emit(state.copyWith(bubbles: [...state.bubbles, Bubble(mine: false, text: m['text'] as String, translated: text, srcLang: src, tgtLang: my.code, at: DateTime.now())]));
    if (state.muted) return;
    final before = state.phase;
    if (before == ConversationPhase.listening) await translate.stopCapture(); // do not transcribe the other person's voice
    emit(state.copyWith(phase: ConversationPhase.speaking));
    try {
      await translate.speakText(text, my);
    } catch (_) {
      // TTS unavailable: the text bubble is still shown.
    } finally {
      emit(state.copyWith(phase: ConversationPhase.idle));
    }
  }

  // A spoken translation can finish after the conversation is torn down; ignore those emits.
  @override
  void emit(ConversationState state) {
    if (!isClosed) super.emit(state);
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    await _profileSub?.cancel();
    return super.close();
  }
}
