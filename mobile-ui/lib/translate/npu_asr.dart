import 'dart:io';

import 'package:flutter/services.dart';

class NpuResult {
  const NpuResult({required this.text, this.recordMs = 0, this.melMs = 0, this.encoderMs = 0, this.decodeMs = 0, this.tokens = 0});
  final String text;
  final int recordMs, melMs, encoderMs, decodeMs, tokens;
  int get processingMs => melMs + encoderMs + decodeMs;
}

/// Speech recognition on the Snapdragon NPU (Whisper-Small via ONNX Runtime QNN), implemented in Kotlin.
class NpuAsr {
  NpuAsr([MethodChannel? channel]) : _ch = channel ?? const MethodChannel('dharani/ai');
  final MethodChannel _ch;

  /// True when the QNN/ONNX Runtime libraries are packaged in this build.
  Future<bool> runtimeBundled() async {
    if (!Platform.isAndroid) return false;
    try {
      final m = await _ch.invokeMapMethod<String, dynamic>('status');
      return m?['runtimeBundled'] == true;
    } on MissingPluginException {
      return false;
    }
  }

  Future<bool> ensureMic() async => (await _ch.invokeMethod<bool>('ensureMic')) ?? false;

  Future<int>? _loading;
  bool _loaded = false;

  /// Loads encoder and decoder on the NPU; returns the load time in ms. Concurrent callers share one load,
  /// and an already loaded model is not loaded again.
  Future<int> load() {
    if (_loaded) return Future.value(0);
    return _loading ??= () async {
      try {
        final ms = (await _ch.invokeMethod<int>('load')) ?? 0;
        _loaded = true;
        return ms;
      } finally {
        _loading = null;
      }
    }();
  }

  Future<void> release() async {
    _loaded = false;
    await _ch.invokeMethod<void>('release');
  }

  /// Unpacks a zip natively (fast, streaming).
  Future<void> unzip(String zipPath, String targetDir) => _ch.invokeMethod<void>('unzip', {'src': zipPath, 'dst': targetDir});

  /// Records until the speaker pauses, then transcribes (or translates to English) on the NPU.
  Future<NpuResult> listen({required String lang, required bool translate, int maxSeconds = 25}) async {
    final m = await _ch.invokeMapMethod<String, dynamic>('listen', {'lang': lang, 'translate': translate, 'maxSeconds': maxSeconds});
    int i(String k) => (m?[k] as num?)?.toInt() ?? 0;
    return NpuResult(text: (m?['text'] as String?) ?? '', recordMs: i('recordMs'), melMs: i('melMs'), encoderMs: i('encoderMs'), decodeMs: i('decodeMs'), tokens: i('tokens'));
  }

  Future<void> stopRecording() => _ch.invokeMethod<void>('stopRecording');
}
