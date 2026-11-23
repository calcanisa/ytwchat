import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/models.dart';

abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureSecretStore implements SecretStore {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemorySecretStore implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;

  @override
  Future<void> delete(String key) async => _values.remove(key);
}

class Session {
  final String userId;
  final String deviceId;
  final String accessToken;
  final String refreshToken;
  final DateTime accessExpiresAt;

  const Session({
    required this.userId,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
    required this.accessExpiresAt,
  });

  bool get accessExpiringSoon => DateTime.now()
      .toUtc()
      .isAfter(accessExpiresAt.subtract(const Duration(seconds: 30)));

  Session withTokens(String access, String refresh, int expiresIn) => Session(
        userId: userId,
        deviceId: deviceId,
        accessToken: access,
        refreshToken: refresh,
        accessExpiresAt:
            DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
      );

  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'device_id': deviceId,
        'access_token': accessToken,
        'refresh_token': refreshToken,
        'access_expires_at': accessExpiresAt.toIso8601String(),
      };

  factory Session.fromJson(Map<String, dynamic> j) => Session(
        userId: j['user_id'] as String,
        deviceId: j['device_id'] as String,
        accessToken: j['access_token'] as String,
        refreshToken: j['refresh_token'] as String,
        accessExpiresAt: DateTime.parse(j['access_expires_at'] as String),
      );
}

class SessionStore {
  static const _sessionKey = 'ytwchat.session';
  static const _dbKey = 'ytwchat.db_key';
  static const _storageKey = 'ytwchat.storage_key';
  static const _profileKey = 'ytwchat.profile';

  final SecretStore _store;

  SessionStore(this._store);

  Future<Session?> load() async {
    final raw = await _store.read(_sessionKey);
    if (raw == null) return null;
    try {
      return Session.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      await _store.delete(_sessionKey);
      return null;
    }
  }

  Future<void> save(Session session) =>
      _store.write(_sessionKey, jsonEncode(session.toJson()));

  Future<String> _hexKey(String name, int bytes) async {
    final existing = await _store.read(name);
    if (existing != null && existing.length == bytes * 2) return existing;
    final random = Random.secure();
    final key = List.generate(bytes, (_) => random.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    await _store.write(name, key);
    return key;
  }

  Future<String> databaseKey() => _hexKey(_dbKey, 32);

  Future<Uint8List> storageKey() async {
    final hex = await _hexKey(_storageKey, 64);
    return Uint8List.fromList(List.generate(64, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
  }

  Future<void> saveProfile(Me me) => _store.write(_profileKey, jsonEncode(me.toJson()));

  Future<Me?> loadProfile() async {
    final raw = await _store.read(_profileKey);
    if (raw == null) return null;
    try {
      return Me.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() async {
    await _store.delete(_sessionKey);
    await _store.delete(_dbKey);
    await _store.delete(_storageKey);
    await _store.delete(_profileKey);
  }
}
