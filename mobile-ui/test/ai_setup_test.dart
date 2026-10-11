import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dharani_mobile/core/secure_storage.dart';
import 'package:dharani_mobile/state/translate_cubit.dart';
import 'package:dharani_mobile/translate/device_info.dart';
import 'package:dharani_mobile/translate/languages.dart';
import 'package:dharani_mobile/translate/model_manager.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null; // the test binding stubs HTTP with 400s; these tests use a real local server
  late HttpServer server;
  late Directory dir;
  late List<int> zipBytes, tokBytes;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('ai_');
    final a = Archive()
      ..addFile(ArchiveFile('pkg/encoder.onnx', 4, [1, 2, 3, 4]))
      ..addFile(ArchiveFile('pkg/decoder.onnx', 4, [5, 6, 7, 8]));
    zipBytes = ZipEncoder().encode(a);
    tokBytes = utf8.encode('{"model":{}}');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.add(req.uri.path == '/m.zip' ? zipBytes : tokBytes);
      await req.response.close();
    });
  });
  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  String manifest({bool badSha = false}) => jsonEncode({
        'models': [
          {'id': 'whisper-small-sm8850', 'name': 'Whisper Small', 'kind': 'asr', 'url': 'http://127.0.0.1:${server.port}/m.zip', 'sha256': badSha ? 'ab' * 32 : sha256.convert(zipBytes).toString(), 'size_bytes': zipBytes.length, 'soc_models': ['SM8850'], 'extract': true},
          {'id': 'whisper-tokenizer', 'name': 'Tokenizer', 'kind': 'asr', 'url': 'http://127.0.0.1:${server.port}/t.json', 'sha256': sha256.convert(tokBytes).toString(), 'size_bytes': tokBytes.length, 'soc_models': ['SM8850']},
        ]
      });

  Future<TranslateCubit> make(FakePipeline p, FakeNpu npu, {String soc = 'SM8850', String? bundled, bool badSha = false}) async {
    final models = ModelManager(rootDir: dir.path, extractor: npu.unzip);
    final c = TranslateCubit(
      pipeline: p,
      models: models,
      npu: npu,
      device: DeviceInfo(model: 'I2501', socManufacturer: 'QTI', socModel: soc, sdk: 36),
      store: SecureStore(),
      bundledManifest: bundled ?? manifest(badSha: badSha),
    );
    await c.init();
    return c;
  }

  test('one tap downloads packs and the NPU model, verifies, unpacks and loads it on the NPU', () async {
    final npu = FakeNpu();
    final c = await make(FakePipeline(), npu);
    expect(c.state.npuLoaded, isFalse);
    expect(c.state.qairt!.available, isFalse);
    await c.enableOnDeviceAi();
    final s = c.state;
    expect(s.aiSteps.every((e) => e.done && e.error == null), isTrue, reason: s.aiSteps.map((e) => '${e.label}:${e.error}').join('; '));
    expect(File('${dir.path}/models/runtime/whisper-small-sm8850/pkg/encoder.onnx').existsSync(), isTrue);
    expect(File('${dir.path}/models/whisper-tokenizer.bin').existsSync(), isTrue);
    expect(npu.loaded, isTrue);
    expect(s.npuLoaded, isTrue);
    expect(s.aiPhase, AiSetupPhase.ready);
    expect(s.aiSummary, contains('NPU ready'));
    await c.close();
  });

  test('a restart with models already installed brings the NPU engine up by itself', () async {
    final first = await make(FakePipeline(), FakeNpu());
    await first.enableOnDeviceAi();
    await first.close();
    final npu = FakeNpu();
    final again = await make(FakePipeline()..ready.addAll(['hi', 'en']), npu);
    expect(npu.loaded, isTrue);
    expect(again.state.npuLoaded, isTrue);
    await again.close();
  });

  test('NPU speech path: Hindi to English is a single Whisper translate pass', () async {
    final p = FakePipeline();
    final npu = FakeNpu()..heard = 'Go to the highway';
    final c = await make(p, npu);
    await c.enableOnDeviceAi();
    await c.toggleListening(); // src Hindi -> tgt English
    expect(npu.lastListen, (lang: 'hi', translate: true));
    expect(c.state.history.first.translated, 'Go to the highway', reason: 'no second translation step');
    expect(p.spoken.single, 'en:Go to the highway');
    expect(c.state.lastTiming, contains('encoder 230 ms'));
    // English -> Hindi: transcribe in English, then ML Kit.
    c.setSource(langByCode('en'));
    c.setTarget(langByCode('hi'));
    npu.heard = 'hello';
    await c.toggleListening();
    expect(npu.lastListen, (lang: 'en', translate: false));
    expect(c.state.history.first.translated, '[en>hi] hello');
    await c.close();
  });

  test('without bundled QNN libraries the NPU is reported unavailable and Android recognizer remains', () async {
    final npu = FakeNpu()..bundled = false;
    final c = await make(FakePipeline(), npu);
    await c.enableOnDeviceAi();
    expect(c.state.npuLoaded, isFalse);
    expect(c.state.aiPhase, AiSetupPhase.partial);
    expect(c.state.aiSummary, contains('NPU engine not active'));
    expect(c.state.qairt!.reasons.join(' '), contains('QNN runtime libraries'));
    await c.close();
  });

  test('NPU load failure is surfaced on the step, not hidden', () async {
    final npu = FakeNpu()..loadFails = true;
    final c = await make(FakePipeline(), npu);
    await c.enableOnDeviceAi();
    expect(c.state.aiSteps.last.error, contains('HTP device creation failed'));
    expect(c.state.npuLoaded, isFalse);
    await c.close();
  });

  test('a corrupted model download is rejected and never loaded', () async {
    final npu = FakeNpu();
    final c = await make(FakePipeline(), npu, badSha: true);
    await c.enableOnDeviceAi();
    expect(c.state.aiSteps.firstWhere((e) => e.label.contains('Whisper Small')).error, contains('Checksum'));
    expect(npu.loaded, isFalse);
    expect(Directory('${dir.path}/models/runtime/whisper-small-sm8850').existsSync(), isFalse);
    await c.close();
  });

  test('another SoC downloads nothing from an SM8850 manifest', () async {
    final c = await make(FakePipeline(), FakeNpu(), soc: 'SM8750');
    await c.enableOnDeviceAi();
    expect(c.state.aiSteps.where((e) => e.label.startsWith('Download')), isEmpty);
    expect(c.state.qairt!.reasons.join(' '), contains('No NPU speech model'));
    await c.close();
  });

  test('network failure for language packs is reported as incomplete', () async {
    final c = await make(FakePipeline()..failDownloads = true, FakeNpu());
    await c.enableOnDeviceAi();
    expect(c.state.aiSteps.first.error, isNotNull);
    await c.close();
  });

  test('French is available: language list, ML Kit pack, and NPU recognition with Whisper\'s French token', () async {
    expect(kLanguages.map((l) => l.code), contains('fr'));
    final fr = langByCode('fr');
    expect(fr.name, 'French');
    expect(fr.locale, 'fr_FR');
    final p = FakePipeline();
    final npu = FakeNpu()..heard = 'Bonjour, où allez-vous ?';
    final c = await make(p, npu);
    await c.enableOnDeviceAi();
    c.setSource(fr);
    c.setTarget(langByCode('hi'));
    await c.toggleListening();
    expect(npu.lastListen, (lang: 'fr', translate: false));
    expect(c.state.history.first.translated, '[fr>hi] Bonjour, où allez-vous ?');
    expect(p.spoken.single, startsWith('hi:'));
    // French -> English uses Whisper's single-pass translate task
    c.setTarget(langByCode('en'));
    await c.toggleListening();
    expect(npu.lastListen, (lang: 'fr', translate: true));
    await c.close();
  });

  test('removeDownloads deletes the model and releases the NPU', () async {
    final npu = FakeNpu();
    final c = await make(FakePipeline(), npu);
    await c.enableOnDeviceAi();
    await c.removeDownloads();
    expect(npu.loaded, isFalse);
    expect(Directory('${dir.path}/models/runtime/whisper-small-sm8850').existsSync(), isFalse);
    expect(c.state.npuLoaded, isFalse);
    await c.close();
  });
}
