import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dharani_mobile/translate/model_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late Directory dir;
  final payload = List<int>.generate(300000, (i) => (i * 31 + 7) & 0xFF);
  var rangeRequests = 0;
  var abortAfter = -1;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('models_');
    rangeRequests = 0;
    abortAfter = -1;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final range = req.headers.value('range');
      var start = 0;
      if (range != null) {
        rangeRequests++;
        start = int.parse(range.substring(6, range.indexOf('-')));
        req.response.statusCode = 206;
      }
      final body = payload.sublist(start);
      if (abortAfter >= 0 && range == null) {
        // Send the first bytes, then drop the connection mid-body.
        final socket = await req.response.detachSocket(writeHeaders: false);
        socket.write('HTTP/1.1 200 OK\r\ncontent-length: ${body.length}\r\n\r\n');
        socket.add(body.sublist(0, abortAfter));
        await socket.flush();
        socket.destroy();
        return;
      }
      req.response.add(body);
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  ModelSpec spec({String? sha}) => ModelSpec(
        id: 'whisper-small',
        name: 'ASR',
        kind: 'asr',
        url: 'http://127.0.0.1:${server.port}/m.bin',
        sha256: sha ?? sha256.convert(payload).toString(),
        sizeBytes: payload.length,
      );

  test('downloads, verifies and installs', () async {
    final m = ModelManager(rootDir: dir.path);
    final s = spec();
    expect(await m.isInstalled(s), isFalse);
    final events = await m.download(s).toList();
    expect(events.last.done, isTrue);
    expect(await m.isInstalled(s), isTrue);
    expect(await m.fileFor(s).readAsBytes(), payload);
    await m.delete(s);
    expect(await m.isInstalled(s), isFalse);
  });

  test('resumes an interrupted download with a Range request', () async {
    final m = ModelManager(rootDir: dir.path);
    final s = spec();
    abortAfter = 100000;
    await expectLater(m.download(s).drain<void>(), throwsA(anything));
    final part = File('${m.fileFor(s).path}.part');
    expect(await part.length(), inInclusiveRange(1, 299999));
    abortAfter = -1;
    final events = await m.download(s).toList();
    expect(events.last.done, isTrue);
    expect(rangeRequests, 1);
    expect(await m.fileFor(s).readAsBytes(), payload);
  });

  test('rejects a corrupted model and leaves nothing installed', () async {
    final m = ModelManager(rootDir: dir.path);
    final s = spec(sha: 'ab' * 32);
    await expectLater(m.download(s).drain<void>(), throwsA(isA<ModelException>().having((e) => e.message, 'm', contains('Checksum'))));
    expect(await m.isInstalled(s), isFalse);
    expect(await File('${m.fileFor(s).path}.part').exists(), isFalse);
  });

  test('manifest validation', () async {
    final m = ModelManager(rootDir: dir.path);
    expect(await m.loadManifest(), isEmpty);
    await m.saveManifestText(jsonEncode({
      'models': [
        {'id': 'a', 'kind': 'asr', 'url': 'https://x/a', 'sha256': 'AB', 'size_bytes': 5, 'soc_models': ['SM8850']}
      ]
    }));
    final list = await m.loadManifest();
    expect(list.single.sha256, 'ab');
    expect(list.single.socModels, ['SM8850']);
    await expectLater(m.saveManifestText('{"models":[{"id":"x"}]}'), throwsA(anything));
    expect((await m.loadManifest()).length, 1, reason: 'bad manifest must not replace the good one');
  });
}
