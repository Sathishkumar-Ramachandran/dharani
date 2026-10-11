import 'dart:async';
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_bloc/flutter_bloc.dart';

import '../net/call_audio.dart';
import 'conversation_cubit.dart';
import 'session_cubit.dart';

enum CallPhase { idle, calling, incoming, active, ended }

class CallState {
  const CallState({this.phase = CallPhase.idle, this.rideId, this.peerName = '', this.muted = false, this.speaker = false, this.seconds = 0, this.sent = 0, this.received = 0, this.error, this.endReason, this.interpreter = false, this.interpreterNote, this.lastRecognisedMs});
  final CallPhase phase;
  final String? rideId;
  final String peerName;
  final bool muted, speaker;
  final int seconds, sent, received;
  final String? error, endReason, interpreterNote;

  /// Interpreter mode: the speaker's voice is recognised, translated and spoken on the other phone.
  final bool interpreter;
  final int? lastRecognisedMs;

  bool get busy => phase == CallPhase.calling || phase == CallPhase.incoming || phase == CallPhase.active;

  CallState copyWith({CallPhase? phase, String? rideId, String? peerName, bool? muted, bool? speaker, int? seconds, int? sent, int? received, String? error, String? endReason, bool? interpreter, String? interpreterNote, int? lastRecognisedMs, bool clearError = false, bool clearRide = false}) => CallState(
        phase: phase ?? this.phase,
        rideId: clearRide ? null : (rideId ?? this.rideId),
        peerName: peerName ?? this.peerName,
        muted: muted ?? this.muted,
        speaker: speaker ?? this.speaker,
        seconds: seconds ?? this.seconds,
        sent: sent ?? this.sent,
        received: received ?? this.received,
        error: clearError ? null : (error ?? this.error),
        endReason: endReason ?? this.endReason,
        interpreter: interpreter ?? this.interpreter,
        interpreterNote: interpreterNote ?? this.interpreterNote,
        lastRecognisedMs: lastRecognisedMs ?? this.lastRecognisedMs,
      );
}

/// Real-time bidirectional voice call between rider and driver: signalling over the JSON socket,
/// audio as binary frames, 20 ms each, in both directions at the same time.
class CallCubit extends Cubit<CallState> {
  CallCubit({required this.session, required this.audio, required this.ensureMic, this.defaultSpeaker = false, this.conversation, this.npuReady, this.packsReady}) : super(CallState(speaker: defaultSpeaker)) {
    _msg = session.messages.listen(_onMessage);
    _rx = session.audio.listen(_onAudio);
    // A language changed mid-call (either side): re-plan so translation targets the right language.
    _langSub = conversation?.stream.map((c) => '${c.myLang}>${c.peerLang}').distinct().skip(1).listen((_) {
      if (state.phase == CallPhase.active) unawaited(setInterpreter(_wantInterpreter));
    });
  }

  StreamSubscription<String>? _langSub;

  final SessionCubit session;
  final CallAudioEngine audio;
  final Future<bool> Function() ensureMic;
  final bool defaultSpeaker;

  /// Used for interpreter mode: peer language, and sending the recognised sentences.
  final ConversationCubit? conversation;

  /// True when the NPU speech model is loaded (interpreter mode needs it: the call owns the microphone).
  final bool Function()? npuReady;

  /// True when both languages' translation packs are on this phone.
  final bool Function(String a, String b)? packsReady;
  StreamSubscription<({String text, int ms})>? _texts;
  StreamSubscription<ConversationState>? _gate;
  bool _wantInterpreter = true;
  late final StreamSubscription<Json> _msg;
  late final StreamSubscription<Uint8List> _rx;
  StreamSubscription<Uint8List>? _mic;
  Timer? _clock, _endTimer;
  int _sent = 0, _received = 0;

  // ------------------------------------------------------------ user actions
  Future<void> call({required String rideId, required String peerName}) async {
    if (state.busy) return;
    if (!session.state.connected) {
      emit(state.copyWith(error: 'Not connected to the server.'));
      return;
    }
    if (!await ensureMic()) {
      emit(state.copyWith(error: 'Microphone permission is needed for calls.'));
      return;
    }
    emit(CallState(phase: CallPhase.calling, rideId: rideId, peerName: peerName, speaker: defaultSpeaker));
    session.send({'t': T.callStart, 'rideId': rideId});
  }

  Future<void> accept() async {
    final id = state.rideId;
    if (state.phase != CallPhase.incoming || id == null) return;
    if (!await ensureMic()) {
      decline();
      emit(state.copyWith(error: 'Microphone permission is needed for calls.'));
      return;
    }
    session.send({'t': T.callAccept, 'rideId': id});
  }

  void decline() {
    final id = state.rideId;
    if (id != null && state.phase == CallPhase.incoming) session.send({'t': T.callDecline, 'rideId': id});
  }

  void hangUp() {
    final id = state.rideId;
    if (id != null && state.busy) session.send({'t': T.callEnd, 'rideId': id});
  }

  Future<void> toggleMute() async {
    final m = !state.muted;
    emit(state.copyWith(muted: m));
    await audio.setMuted(m);
  }

  Future<void> toggleSpeaker() async {
    final s = !state.speaker;
    emit(state.copyWith(speaker: s));
    await audio.setSpeaker(s);
  }

  // ------------------------------------------------------------ server frames
  Future<void> _onMessage(Json m) async {
    switch (m['t']) {
      case T.callIncoming:
        if (state.busy) {
          session.send({'t': T.callDecline, 'rideId': m['rideId']});
          return;
        }
        emit(CallState(phase: CallPhase.incoming, rideId: m['rideId'] as String, peerName: (m['fromName'] as String?) ?? '', speaker: defaultSpeaker));
      case T.callState:
        if (m['rideId'] != state.rideId) return;
        switch (m['state']) {
          case 'ringing':
            emit(state.copyWith(phase: CallPhase.calling));
          case 'active':
            await _startAudio();
          case 'ended':
            await _stopAudio();
            emit(state.copyWith(phase: CallPhase.ended, endReason: m['reason'] as String?, seconds: state.seconds));
            _endTimer?.cancel();
            _endTimer = Timer(const Duration(seconds: 2), () {
              if (!isClosed && state.phase == CallPhase.ended) emit(const CallState());
            });
        }
      case T.error:
        if (state.busy && state.phase != CallPhase.active) emit(state.copyWith(error: m['message'] as String?));
    }
  }

  Future<void> _startAudio() async {
    try {
      _sent = _received = 0;
      final mode = _interpreterPlan();
      final speaker = mode.on ? true : state.speaker; // the translation is spoken aloud, so use the loudspeaker
      await audio.start(speaker: speaker, relayRaw: !mode.on, translateLang: mode.lang);
      await audio.setMuted(state.muted);
      if (mode.on) _attachInterpreter();
      _mic = audio.mic.listen((f) {
        session.sendAudio(f);
        _sent++;
      });
      _clock?.cancel();
      var secs = 0;
      _clock = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!isClosed) emit(state.copyWith(seconds: ++secs, sent: _sent, received: _received));
      });
      emit(state.copyWith(phase: CallPhase.active, seconds: 0, speaker: speaker, interpreter: mode.on, interpreterNote: mode.note, clearError: true));
    } catch (e) {
      emit(state.copyWith(error: 'Could not start call audio: $e'));
      hangUp();
    }
  }

  void _onAudio(Uint8List frame) {
    if (state.phase != CallPhase.active) return;
    _received++;
    audio.play(frame);
  }

  /// Decides whether this call is interpreted. Needs: different languages on the two phones, the NPU
  /// speech model loaded here, and a bound conversation (peer language known).
  ({bool on, String? lang, String? note}) _interpreterPlan() {
    final my = conversation?.state.myLang ?? session.state.profile?.lang;
    final peer = conversation?.state.peerLang;
    if (!_wantInterpreter) return (on: false, lang: null, note: 'Original voices');
    if (my == null || peer == null || conversation == null || !conversation!.state.active) return (on: false, lang: null, note: 'Original voices');
    if (my == peer) return (on: false, lang: null, note: 'Same language: original voices');
    if (!(npuReady?.call() ?? false)) return (on: false, lang: null, note: 'Interpreter needs the NPU speech model (Translate tab → Download & enable). Using original voices.');
    if (packsReady != null && !packsReady!(my, peer)) {
      return (on: false, lang: null, note: 'Language packs for $my/$peer are still downloading (needs internet once). Using original voices.');
    }
    return (on: true, lang: my, note: 'Interpreter: $my → $peer');
  }

  void _attachInterpreter() {
    _texts?.cancel();
    _texts = audio.texts.listen((t) {
      debugPrint('INTERP recognised in ${t.ms} ms: ${t.text}');
      emit(state.copyWith(lastRecognisedMs: t.ms));
      conversation?.sendRecognized(t.text);
    });
    // Do not transcribe our own loudspeaker while the translation of the other side is playing.
    _gate?.cancel();
    _gate = conversation?.stream.listen((c) => audio.setGate(c.phase == ConversationPhase.speaking));
  }

  /// Switch between interpreter (translated speech) and the speakers' own voices during a call.
  Future<void> setInterpreter(bool on) async {
    _wantInterpreter = on;
    if (state.phase != CallPhase.active) return;
    final plan = _interpreterPlan();
    await audio.configure(relayRaw: !plan.on, translateLang: plan.lang);
    if (plan.on) {
      _attachInterpreter();
    } else {
      await _texts?.cancel();
      await _gate?.cancel();
      _texts = _gate = null;
      await audio.setGate(false);
    }
    emit(state.copyWith(interpreter: plan.on, interpreterNote: plan.note));
  }

  Future<void> _stopAudio() async {
    await _texts?.cancel();
    await _gate?.cancel();
    _texts = _gate = null;
    _clock?.cancel();
    await _mic?.cancel();
    _mic = null;
    try {
      await audio.stop();
    } catch (_) {}
  }

  // Server frames and timers can land after the cubit is closed (call teardown
  // awaits audio shutdown); drop those emits instead of throwing.
  @override
  void emit(CallState state) {
    if (!isClosed) super.emit(state);
  }

  @override
  Future<void> close() async {
    _clock?.cancel();
    _endTimer?.cancel();
    await _langSub?.cancel();
    await _stopAudio();
    await _msg.cancel();
    await _rx.cancel();
    return super.close();
  }
}
