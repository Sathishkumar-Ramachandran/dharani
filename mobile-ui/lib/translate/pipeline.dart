import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import 'languages.dart';

class PipelineException implements Exception {
  PipelineException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Speech-to-speech translation built from Android's on-device components:
/// speech recognition (offline language pack) -> ML Kit on-device translation -> text-to-speech.
/// It works today on any recent Android phone; the QAIRT backend replaces it on Snapdragon.
class OnDevicePipeline {
  OnDevicePipeline({SpeechToText? stt, FlutterTts? tts, OnDeviceTranslatorModelManager? models})
      : _stt = stt ?? SpeechToText(),
        _tts = tts ?? FlutterTts(),
        _models = models ?? OnDeviceTranslatorModelManager();

  final SpeechToText _stt;
  final FlutterTts _tts;
  final OnDeviceTranslatorModelManager _models;
  bool _sttReady = false;
  bool lastRecognitionOnDevice = false;

  Future<void> _ensureStt() async {
    if (_sttReady) return;
    _sttReady = await _stt.initialize(onError: (e) {}, debugLogging: false);
    if (!_sttReady) {
      throw PipelineException('Speech recognition is unavailable. Allow microphone access and install a speech service.');
    }
  }

  // ---- language packs ----
  Future<bool> isPackReady(Lang l) => _models.isModelDownloaded(l.mlkit.bcpCode);

  Future<void> downloadPack(Lang l) async {
    final ok = await _models.downloadModel(l.mlkit.bcpCode, isWifiRequired: false);
    if (!ok) throw PipelineException('Could not download the ${l.name} translation pack. Check your connection.');
  }

  // ---- listen ----
  /// Streams partial transcripts; the future of the last event is the final text.
  Stream<({String text, bool isFinal})> listen(Lang src, {Duration maxDuration = const Duration(seconds: 25)}) {
    final controller = StreamController<({String text, bool isFinal})>();
    () async {
      try {
        await _ensureStt();
        final locales = await _stt.locales();
        final wanted = locales.where((l) => l.localeId.replaceAll('-', '_').toLowerCase() == src.locale.toLowerCase());
        final localeId = wanted.isNotEmpty ? wanted.first.localeId : src.locale;
        lastRecognitionOnDevice = true;
        void onResult(SpeechRecognitionResult r) {
          controller.add((text: r.recognizedWords, isFinal: r.finalResult));
          if (r.finalResult) controller.close();
        }

        Future<void> start(bool onDevice) => _stt.listen(
              onResult: onResult,
              listenOptions: SpeechListenOptions(
                partialResults: true,
                onDevice: onDevice,
                cancelOnError: true,
                localeId: localeId,
                listenFor: maxDuration,
                pauseFor: const Duration(seconds: 3),
              ),
            );
        try {
          await start(true);
        } catch (_) {
          lastRecognitionOnDevice = false;
          await start(false);
        }
      } on PipelineException catch (e) {
        controller.addError(e);
        await controller.close();
      } catch (e) {
        controller.addError(PipelineException('Could not start listening: $e'));
        await controller.close();
      }
    }();
    return controller.stream;
  }

  Future<void> stopListening() => _stt.stop();
  Future<void> cancelListening() => _stt.cancel();

  // ---- translate ----
  Future<String> translate(String text, Lang src, Lang tgt) async {
    if (src.code == tgt.code) return text;
    final translator = OnDeviceTranslator(sourceLanguage: src.mlkit, targetLanguage: tgt.mlkit);
    try {
      return await translator.translateText(text);
    } catch (e) {
      throw PipelineException('Translation failed. Download the ${src.name} and ${tgt.name} packs first.');
    } finally {
      await translator.close();
    }
  }

  // ---- speak ----
  Future<void> speak(String text, Lang lang) async {
    await _tts.setLanguage(lang.locale.replaceAll('_', '-'));
    await _tts.awaitSpeakCompletion(true);
    await _tts.speak(text);
  }

  Future<void> stopSpeaking() => _tts.stop();
}
