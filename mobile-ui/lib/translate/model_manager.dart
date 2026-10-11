import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// One downloadable model file (for example a QAIRT/QNN context binary compiled for an SoC).
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.name,
    required this.kind,
    required this.url,
    required this.sha256,
    required this.sizeBytes,
    this.socModels = const [],
    this.languages = const [],
    this.extract = false,
  });

  final String id, name;
  final String kind; // asr | mt | tts
  final String url;
  final String sha256; // lowercase hex
  final int sizeBytes;
  final List<String> socModels; // e.g. ["SM8750","SM8850"]; empty = any
  final List<String> languages;
  final bool extract; // zip archive unpacked into its own directory (runtime libraries)

  bool get isRuntime => kind == 'runtime';
  String get fileName => extract ? '$id.zip' : '$id.bin';

  factory ModelSpec.fromJson(Map<String, dynamic> j) => ModelSpec(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        kind: j['kind'] as String,
        url: j['url'] as String,
        sha256: (j['sha256'] as String).toLowerCase(),
        sizeBytes: (j['size_bytes'] as num).toInt(),
        socModels: [for (final s in (j['soc_models'] as List? ?? const [])) s as String],
        languages: [for (final s in (j['languages'] as List? ?? const [])) s as String],
        extract: j['extract'] as bool? ?? false,
      );
}

class DownloadProgress {
  const DownloadProgress(this.received, this.total, {this.done = false, this.verifying = false});
  final int received, total;
  final bool done, verifying;
  double get fraction => total == 0 ? 0 : received / total;
}

class ModelException implements Exception {
  ModelException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Downloads, verifies and stores models in app-private storage. Downloads resume (HTTP Range)
/// and a file only becomes visible after its SHA-256 matches the manifest.
class ModelManager {
  ModelManager({required this.rootDir, http.Client? client, this.extractor}) : _client = client ?? http.Client();

  /// Native unzip (streaming, fast). Falls back to the pure-Dart `archive` package when null.
  final Future<void> Function(String zipPath, String targetDir)? extractor;

  final String rootDir;
  final http.Client _client;

  Directory get _models => Directory('$rootDir/models');
  File get manifestFile => File('${_models.path}/manifest.json');

  Future<List<ModelSpec>> loadManifest() async {
    if (!await manifestFile.exists()) return const [];
    final j = jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    return [
      for (final m in (j['runtime'] as List? ?? const []))
        ModelSpec.fromJson({...(m as Map<String, dynamic>), 'kind': 'runtime'}),
      for (final m in (j['models'] as List? ?? const [])) ModelSpec.fromJson(m as Map<String, dynamic>),
    ];
  }

  /// Directory a runtime archive is unpacked into.
  Directory runtimeDir(ModelSpec s) => Directory('${_models.path}/runtime/${s.id}');

  Future<void> saveManifestText(String text) async {
    final j = jsonDecode(text) as Map<String, dynamic>;
    for (final m in (j['models'] as List? ?? const [])) {
      ModelSpec.fromJson(m as Map<String, dynamic>); // validates every entry before replacing the file
    }
    for (final m in (j['runtime'] as List? ?? const [])) {
      ModelSpec.fromJson({...(m as Map<String, dynamic>), 'kind': 'runtime'});
    }
    await _models.create(recursive: true);
    await manifestFile.writeAsString(text, flush: true);
  }

  Future<void> fetchManifest(String url) async {
    final res = await _client.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw ModelException('Manifest download failed (${res.statusCode}).');
    try {
      await saveManifestText(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw ModelException('The manifest is not valid JSON.');
    } catch (e) {
      throw ModelException('The manifest is malformed: $e');
    }
  }

  File fileFor(ModelSpec s) => File('${_models.path}/${s.fileName}');

  File _marker(ModelSpec s) => File('${runtimeDir(s).path}/.installed');

  Future<bool> isInstalled(ModelSpec s) async {
    if (s.extract) {
      final m = _marker(s);
      return await m.exists() && (await m.readAsString()).trim() == s.sha256;
    }
    final f = fileFor(s);
    return await f.exists() && await f.length() == s.sizeBytes;
  }

  Future<void> delete(ModelSpec s) async {
    for (final f in [fileFor(s), File('${fileFor(s).path}.part')]) {
      if (await f.exists()) await f.delete();
    }
    final d = runtimeDir(s);
    if (await d.exists()) await d.delete(recursive: true);
  }

  Stream<DownloadProgress> download(ModelSpec s) async* {
    await _models.create(recursive: true);
    final target = fileFor(s);
    if (await isInstalled(s)) {
      yield DownloadProgress(s.sizeBytes, s.sizeBytes, done: true);
      return;
    }
    if (s.extract && await target.exists() && !await File('${target.path}.part').exists()) {
      await target.rename('${target.path}.part'); // re-verify a previously downloaded archive
    }
    final part = File('${target.path}.part');
    var have = await part.exists() ? await part.length() : 0;
    if (have > s.sizeBytes) {
      await part.delete();
      have = 0;
    }

    if (have < s.sizeBytes) {
      final req = http.Request('GET', Uri.parse(s.url));
      if (have > 0) req.headers['Range'] = 'bytes=$have-';
      final http.StreamedResponse res;
      try {
        res = await _client.send(req).timeout(const Duration(seconds: 30));
      } on SocketException {
        throw ModelException('No internet connection.');
      }
      if (res.statusCode == 200 && have > 0) {
        have = 0; // server ignored Range; restart
        await part.writeAsBytes(const [], flush: true);
      } else if (res.statusCode != 200 && res.statusCode != 206) {
        throw ModelException('Server returned ${res.statusCode}.');
      }
      final sink = part.openWrite(mode: FileMode.append);
      var received = have;
      try {
        await for (final chunk in res.stream) {
          sink.add(chunk);
          received += chunk.length;
          yield DownloadProgress(received, s.sizeBytes);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    }

    yield DownloadProgress(s.sizeBytes, s.sizeBytes, verifying: true);
    if (await part.length() != s.sizeBytes) {
      throw ModelException('Download incomplete; try again to resume.');
    }
    final digest = await sha256.bind(part.openRead()).first;
    if (digest.toString() != s.sha256) {
      await part.delete();
      throw ModelException('Checksum mismatch: the file was corrupted or is not the expected model.');
    }
    await part.rename(target.path);
    if (s.extract) {
      final dir = runtimeDir(s);
      if (await dir.exists()) await dir.delete(recursive: true);
      await dir.create(recursive: true);
      try {
        await (extractor ?? (_, __) => extractFileToDisk(target.path, dir.path))(target.path, dir.path);
      } catch (e) {
        await dir.delete(recursive: true);
        throw ModelException('The runtime archive could not be unpacked: $e');
      }
      await _marker(s).writeAsString(s.sha256, flush: true);
      await target.delete();
    }
    yield DownloadProgress(s.sizeBytes, s.sizeBytes, done: true);
  }
}
