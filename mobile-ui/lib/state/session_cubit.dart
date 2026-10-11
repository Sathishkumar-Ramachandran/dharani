import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dharani_protocol/dharani_protocol.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../core/secure_storage.dart';
import '../net/dharani_client.dart';
import '../net/discovery.dart';

/// Stored in place of a server address: find the server on the local Wi-Fi by itself.
const kAutoServer = 'auto';

class SessionState {
  const SessionState({this.loaded = false, this.profile, this.serverUrl = '', this.demo = false, this.conn = ConnState.disconnected, this.error, this.resolvedUrl = ''});
  final bool loaded;
  final Profile? profile;
  final String serverUrl;

  /// The address actually in use (equals [serverUrl] unless that is [kAutoServer]; empty while searching).
  final String resolvedUrl;
  bool get autoServer => serverUrl == kAutoServer;
  bool get searching => autoServer && resolvedUrl.isEmpty && !demo;
  final bool demo; // rider without a server: simulated driver
  final ConnState conn;
  final String? error;

  bool get configured => profile != null;
  bool get connected => conn == ConnState.connected;
  Role? get role => profile?.role;

  SessionState copyWith({bool? loaded, Profile? profile, String? serverUrl, bool? demo, ConnState? conn, String? error, String? resolvedUrl, bool clearError = false, bool clearProfile = false}) => SessionState(
        resolvedUrl: resolvedUrl ?? this.resolvedUrl,
        loaded: loaded ?? this.loaded,
        profile: clearProfile ? null : (profile ?? this.profile),
        serverUrl: serverUrl ?? this.serverUrl,
        demo: demo ?? this.demo,
        conn: conn ?? this.conn,
        error: clearError ? null : (error ?? this.error),
      );
}

/// Who this phone is (rider or driver), where the server is, and the live connection.
class SessionCubit extends Cubit<SessionState> {
  SessionCubit({SecureStore? store, DharaniClient Function(String url, Profile p)? clientFactory, Future<String?> Function()? discover})
      : _store = store ?? SecureStore(),
        _factory = clientFactory,
        _discover = discover ?? discoverServer,
        super(const SessionState());

  final SecureStore _store;
  final DharaniClient Function(String url, Profile p)? _factory;
  final Future<String?> Function() _discover;
  DharaniClient? _client;
  int _gen = 0; // bumps on every connect/teardown so stale discovery loops stop
  Timer? _rediscover;
  StreamSubscription<Json>? _msgSub;
  StreamSubscription<ConnState>? _stateSub;
  final _messages = StreamController<Json>.broadcast();
  final _audio = StreamController<Uint8List>.broadcast();
  StreamSubscription<Uint8List>? _audioSub;

  /// Frames from the server, across reconnects and client replacements.
  Stream<Json> get messages => _messages.stream;

  void send(Json m) => _client?.send(m);

  /// Voice frames from the other party, across reconnects.
  Stream<Uint8List> get audio => _audio.stream;
  void sendAudio(Uint8List frame) => _client?.sendAudio(frame);

  /// Applies a one-shot provisioning file (fleet setup / MDM / adb): {"role","name","lang","vehicle":{...},"server","demo"}.
  /// The file is deleted once read.
  Future<bool> _provision(File f) async {
    try {
      if (!await f.exists()) return false;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      await f.delete();
      final profile = Profile.fromJson({
        'role': j['role'],
        'name': j['name'],
        'lang': j['lang'],
        if (j['vehicle'] != null) 'vehicle': j['vehicle'],
      });
      await configure(profile: profile, serverUrl: (j['server'] as String?) ?? '', demo: j['demo'] == true);
      return true;
    } catch (e) {
      emit(state.copyWith(error: 'Provisioning file is invalid: $e'));
      return false;
    }
  }

  Future<void> load({File? provisionFile}) async {
    if (provisionFile != null && await _provision(provisionFile)) {
      emit(state.copyWith(loaded: true));
      return;
    }
    final raw = await _store.read('profile');
    final url = await _store.read('server_url') ?? '';
    final demo = (await _store.read('demo')) == '1';
    Profile? p;
    if (raw != null) {
      try {
        p = Profile.fromJson(jsonDecode(raw) as Json);
      } catch (_) {}
    }
    emit(state.copyWith(loaded: true, profile: p, serverUrl: url, demo: demo));
    if (p != null && !demo && url.isNotEmpty) await connect();
  }

  Future<void> configure({required Profile profile, required String serverUrl, bool demo = false}) async {
    await _teardown();
    var url = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (!demo && url.isEmpty) url = kAutoServer;
    if (!demo && url != kAutoServer) {
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
        emit(state.copyWith(error: 'Enter the server as http://<ip>:8080 or https://<host>.'));
        return;
      }
    }
    await _store.write('profile', jsonEncode(profile.toJson()));
    await _store.write('server_url', url);
    await _store.write('demo', demo ? '1' : '0');
    emit(state.copyWith(profile: profile, serverUrl: url, demo: demo, clearError: true));
    if (!demo) await connect();
  }

  /// Changes the language this phone speaks and hears; applies to the live ride and call immediately.
  Future<void> setLanguage(String lang) async {
    final p = state.profile;
    if (p == null || p.lang == lang) return;
    final np = p.withLang(lang);
    await _store.write('profile', jsonEncode(np.toJson()));
    _client?.setLanguage(lang);
    emit(state.copyWith(profile: np));
  }

  Future<void> connect() async {
    final p = state.profile;
    if (p == null || state.serverUrl.isEmpty) return;
    await _teardown(keepProfile: true);
    final gen = ++_gen;
    if (state.autoServer) {
      // Searching can take as long as it takes to start the server: never block app start-up on it.
      emit(state.copyWith(conn: ConnState.connecting, resolvedUrl: '', clearError: true));
      unawaited(_connectAuto(gen, p));
      return;
    }
    emit(state.copyWith(resolvedUrl: state.serverUrl));
    await _open(state.serverUrl, p, gen);
  }

  Future<void> _connectAuto(int gen, Profile p) async {
    final found = await _findServer(gen);
    if (found == null || gen != _gen) return; // superseded by another connect/teardown
    emit(state.copyWith(resolvedUrl: found));
    await _open(found, p, gen);
  }

  Future<void> _open(String url, Profile p, int gen) async {
    // A newer connect()/teardown superseded this one while it was searching: never leave a second
    // socket behind (two sockets for one user make the server kick each other forever).
    if (gen != _gen || isClosed) return;
    final stale = _client;
    _client = null;
    await _msgSub?.cancel();
    await _audioSub?.cancel();
    await _stateSub?.cancel();
    await stale?.dispose();
    if (gen != _gen || isClosed) return;
    final client = (_factory ?? (u, pr) => DharaniClient(baseUrl: u, profile: pr, store: _store))(url, p);
    _client = client;
    _msgSub = client.messages.listen((m) {
      if (m['t'] == 'client.error') emit(state.copyWith(error: m['message'] as String?));
      if (!_messages.isClosed) _messages.add(m);
    });
    _audioSub = client.audio.listen((f) {
      if (!_audio.isClosed) _audio.add(f);
    });
    _stateSub = client.states.listen((s) {
      emit(state.copyWith(conn: s, clearError: s == ConnState.connected));
      _rediscover?.cancel();
      // The server's IP can change (DHCP, hotspot restarted): after 20 s offline, look again.
      if (state.autoServer && s != ConnState.connected) {
        _rediscover = Timer(const Duration(seconds: 20), () {
          if (_gen == gen && !state.connected) unawaited(connect());
        });
      }
    });
    await client.connect();
  }

  /// Keeps probing the Wi-Fi until a server answers (every ~4 s). Null when superseded.
  Future<String?> _findServer(int gen) async {
    while (gen == _gen && !isClosed) {
      final found = await _discover();
      if (gen != _gen || isClosed) return null;
      if (found != null) return found;
      emit(state.copyWith(error: 'Looking for a Dharani server on this Wi-Fi… start the server on the same network.'));
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    return null;
  }

  Future<void> signOut() async {
    await _teardown();
    await _store.delete('profile');
    await _store.delete('demo');
    emit(const SessionState(loaded: true));
  }

  Future<void> _teardown({bool keepProfile = false}) async {
    _gen++;
    _rediscover?.cancel();
    await _msgSub?.cancel();
    await _audioSub?.cancel();
    await _stateSub?.cancel();
    _msgSub = _stateSub = _audioSub = null;
    final c = _client;
    _client = null;
    await c?.dispose();
    if (!keepProfile) emit(state.copyWith(conn: ConnState.disconnected));
  }

  @override
  Future<void> close() async {
    await _teardown(keepProfile: true);
    await _messages.close();
    await _audio.close();
    return super.close();
  }
}
