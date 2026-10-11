import 'dart:async';

import 'package:flutter/services.dart';

/// Full-duplex voice on the phone: 20 ms PCM16 frames in, 20 ms frames out, plus on-device
/// speech recognition of the local speaker for interpreter mode.
abstract class CallAudioEngine {
  /// Microphone frames (640 bytes each) while a call is running, not muted, and raw relay is on.
  Stream<Uint8List> get mic;

  /// Sentences recognised from the local microphone (interpreter mode).
  Stream<({String text, int ms})> get texts;

  /// [relayRaw]: send the speaker's own voice. [translateLang]: recognise this language on the NPU.
  Future<void> start({required bool speaker, bool relayRaw = true, String? translateLang});
  Future<void> configure({required bool relayRaw, String? translateLang});

  /// While true the recogniser ignores the microphone (our own speaker is playing the translation).
  Future<void> setGate(bool gated);
  void play(Uint8List pcm);
  Future<void> setMuted(bool muted);
  Future<void> setSpeaker(bool on);
  Future<Map<String, int>> stats();
  Future<void> stop();
}

class PlatformCallAudio implements CallAudioEngine {
  PlatformCallAudio();
  static const _method = MethodChannel('dharani/call');
  static const _events = EventChannel('dharani/call/mic');
  static const _textEvents = EventChannel('dharani/call/text');

  Stream<Uint8List>? _mic;
  Stream<({String text, int ms})>? _texts;

  @override
  Stream<Uint8List> get mic => _mic ??= _events.receiveBroadcastStream().map((e) => e as Uint8List);

  @override
  Stream<({String text, int ms})> get texts => _texts ??= _textEvents.receiveBroadcastStream().map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return (text: m['text'] as String, ms: (m['ms'] as num).toInt());
      });

  @override
  Future<void> start({required bool speaker, bool relayRaw = true, String? translateLang}) =>
      _method.invokeMethod<void>('start', {'speaker': speaker, 'relayRaw': relayRaw, 'translateLang': translateLang});

  @override
  Future<void> configure({required bool relayRaw, String? translateLang}) =>
      _method.invokeMethod<void>('configure', {'relayRaw': relayRaw, 'translateLang': translateLang});

  @override
  Future<void> setGate(bool gated) => _method.invokeMethod<void>('gate', {'gate': gated});

  @override
  void play(Uint8List pcm) {
    // fire-and-forget: ordering is preserved by the platform channel and a late frame is useless anyway
    _method.invokeMethod<void>('play', {'pcm': pcm});
  }

  @override
  Future<void> setMuted(bool muted) => _method.invokeMethod<void>('mute', {'muted': muted});

  @override
  Future<void> setSpeaker(bool on) => _method.invokeMethod<void>('speaker', {'on': on});

  @override
  Future<Map<String, int>> stats() async {
    final m = await _method.invokeMapMethod<String, dynamic>('stats');
    return {for (final e in (m ?? const {}).entries) e.key: (e.value as num).toInt()};
  }

  @override
  Future<void> stop() => _method.invokeMethod<void>('stop');
}
