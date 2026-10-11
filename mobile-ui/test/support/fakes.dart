import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dharani_mobile/net/call_audio.dart';
import 'package:dharani_mobile/services/location_service.dart';
import 'package:dharani_mobile/translate/languages.dart';
import 'package:dharani_mobile/translate/npu_asr.dart';
import 'package:dharani_mobile/translate/pipeline.dart';

class FakePipeline extends OnDevicePipeline {
  final ready = <String>{};
  bool failDownloads = false;
  final spoken = <String>[];
  final scripted = <String>[]; // what the "microphone" hears next
  final speakDelay = const Duration(milliseconds: 30);

  @override
  Future<bool> isPackReady(Lang l) async => ready.contains(l.code);
  @override
  Future<void> downloadPack(Lang l) async {
    if (failDownloads) throw PipelineException('offline');
    ready.add(l.code);
  }

  @override
  Stream<({String text, bool isFinal})> listen(Lang src, {Duration maxDuration = const Duration(seconds: 25)}) async* {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    if (scripted.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 60));
      yield (text: '', isFinal: true);
      return;
    }
    final t = scripted.removeAt(0);
    yield (text: t, isFinal: true);
  }

  @override
  Future<void> stopListening() async {}
  @override
  Future<String> translate(String text, Lang src, Lang tgt) async => src.code == tgt.code ? text : '[${src.code}>${tgt.code}] $text';
  @override
  Future<void> speak(String text, Lang lang) async {
    spoken.add('${lang.code}:$text');
    await Future<void>.delayed(speakDelay);
  }
}

class FakeNpu extends NpuAsr {
  bool bundled = true;
  bool loadFails = false;
  bool loaded = false;
  String heard = 'namaste';
  ({String lang, bool translate})? lastListen;
  @override
  Future<bool> runtimeBundled() async => bundled;
  @override
  Future<int> load() async {
    if (loadFails) throw Exception('HTP device creation failed');
    loaded = true;
    return 321;
  }

  @override
  Future<void> release() async => loaded = false;
  @override
  Future<bool> ensureMic() async => true;
  @override
  Future<NpuResult> listen({required String lang, required bool translate, int maxSeconds = 25}) async {
    lastListen = (lang: lang, translate: translate);
    return NpuResult(text: heard, melMs: 400, encoderMs: 230, decodeMs: 450, tokens: 16);
  }

  @override
  Future<void> unzip(String zipPath, String targetDir) async {
    for (final f in ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync())) {
      if (f.isFile) {
        final out = File('$targetDir/${f.name}')..createSync(recursive: true);
        out.writeAsBytesSync(f.content as List<int>);
      }
    }
  }
}

/// A scripted GPS: tests push fixes into [push].
class FakeLocationService extends LocationService {
  final _ctl = StreamController<UserFix>.broadcast();
  UserFix? first;

  void push(double lat, double lon, {double speed = 8, double heading = 90, bool mocked = false}) => _ctl.add(UserFix(lat, lon, 5, heading, speed, mocked));

  @override
  Future<LocationStatus> ensurePermission({bool request = true}) async => LocationStatus.ready;
  @override
  Future<UserFix?> current() async => first;
  @override
  Stream<UserFix> stream({bool background = false}) => _ctl.stream;
  @override
  Future<void> openSettings() async {}
  @override
  Future<void> openLocationSettings() async {}
}

/// In-memory call audio: tests push "microphone" frames and inspect what would have been played.
class FakeCallAudio implements CallAudioEngine {
  final _mic = StreamController<Uint8List>.broadcast();
  final played = <Uint8List>[];
  bool started = false, muted = false, speaker = false;
  int starts = 0;

  /// Simulates the phone's microphone producing a frame (dropped while muted, like the native engine).
  void speak(Uint8List frame) {
    if (started && !muted && relayRaw) _mic.add(frame);
  }

  @override
  Stream<Uint8List> get mic => _mic.stream;
  final _texts = StreamController<({String text, int ms})>.broadcast();
  bool relayRaw = true, gated = false;
  String? translateLang;

  /// Simulates the NPU recognising a sentence from the local microphone.
  void recognise(String text) {
    if (started && translateLang != null && !muted && !gated) _texts.add((text: text, ms: 900));
  }

  @override
  Stream<({String text, int ms})> get texts => _texts.stream;
  @override
  Future<void> start({required bool speaker, bool relayRaw = true, String? translateLang}) async {
    started = true;
    starts++;
    this.speaker = speaker;
    this.relayRaw = relayRaw;
    this.translateLang = translateLang;
  }

  @override
  Future<void> configure({required bool relayRaw, String? translateLang}) async {
    this.relayRaw = relayRaw;
    this.translateLang = translateLang;
  }

  @override
  Future<void> setGate(bool g) async => gated = g;

  @override
  void play(Uint8List pcm) => played.add(pcm);
  @override
  Future<void> setMuted(bool m) async => muted = m;
  @override
  Future<void> setSpeaker(bool on) async => speaker = on;
  @override
  Future<Map<String, int>> stats() async => {'captured': 0, 'played': played.length, 'dropped': 0};
  @override
  Future<void> stop() async => started = false;
}
