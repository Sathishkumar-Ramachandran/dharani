import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Small facade over the platform keystore (Android Keystore / iOS Keychain). Every call is
/// failure tolerant: if the keystore is unavailable the app keeps working with in-memory values.
class SecureStore {
  SecureStore([FlutterSecureStorage? backend]) : _backend = backend ?? const FlutterSecureStorage();

  final FlutterSecureStorage _backend;
  final Map<String, String> _memory = {};

  Future<String?> read(String key) async {
    try {
      return await _backend.read(key: key) ?? _memory[key];
    } catch (_) {
      return _memory[key];
    }
  }

  Future<void> write(String key, String value) async {
    _memory[key] = value;
    try {
      await _backend.write(key: key, value: value);
    } catch (_) {
      // Keystore unavailable (e.g. host tests); the in-memory copy remains valid.
    }
  }

  Future<void> delete(String key) async {
    _memory.remove(key);
    try {
      await _backend.delete(key: key);
    } catch (_) {}
  }
}
