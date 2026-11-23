import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import '../core/api/api_client.dart';
import '../core/api/models.dart';
import '../core/config.dart';
import '../core/session/session_store.dart';
import '../core/store/local_db.dart';
import '../core/sync/sync_engine.dart';
import '../src/rust/api/chat.dart';
import '../utils/temp_files.dart';

enum AuthStatus { loading, signedOut, signedIn }

class AppSession extends ChangeNotifier with WidgetsBindingObserver {
  final SessionStore store = SessionStore(SecureSecretStore());
  late final ApiClient api = ApiClient(
    baseUrl: AppConfig.apiBase(AppConfig.apiUrl),
    sessions: store,
  )..onSessionExpired = _onExpired;

  AuthStatus status = AuthStatus.loading;
  Me? me;
  SyncEngine? engine;
  LocalDb? _db;
  Directory? _accountDir;

  Directory? get accountDir => _accountDir;
  bool _wiping = false;

  AppSession() {
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) engine?.resume();
  }

  static DeviceDescriptor get device {
    if (Platform.isIOS) return const DeviceDescriptor(name: 'iPhone', platform: 'ios');
    if (Platform.isAndroid) return const DeviceDescriptor(name: 'Android phone', platform: 'android');
    return DeviceDescriptor(name: Platform.operatingSystem, platform: 'desktop');
  }

  Future<Directory> _dirFor(String deviceId) async {
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}/accounts/$deviceId');
  }

  Future<void> init() async {
    try {
      await clearTempFiles();
    } catch (_) {}
    final session = await store.load();
    if (session == null) {
      _set(AuthStatus.signedOut);
      return;
    }
    final dir = await _dirFor(session.deviceId);
    if (!await dir.exists()) {
      api.attach(session);
      try {
        await api.logout();
      } catch (_) {}
      await _wipe();
      return;
    }
    api.attach(session);
    me = await store.loadProfile();
    try {
      await _open(session);
    } catch (_) {
      await _wipe();
      return;
    }
    _set(AuthStatus.signedIn);
    unawaited(refreshProfile());
  }

  Future<void> refreshProfile() async {
    try {
      final fresh = await api.me();
      me = fresh;
      await store.saveProfile(fresh);
      notifyListeners();
    } on ApiException {
      return;
    }
  }

  Future<String?> login(String email, String password) => _authenticate(
        () => api.login(email: email.trim(), password: password, device: device),
      );

  Future<String?> register({
    required String username,
    required String displayName,
    required String email,
    required String password,
  }) =>
      _authenticate(() => api.register(
            username: username.trim().toLowerCase(),
            displayName: displayName.trim(),
            email: email.trim(),
            password: password,
            device: device,
          ));

  Future<String?> _authenticate(Future<AuthResult> Function() call) async {
    try {
      final result = await call();
      final session = Session(
        userId: result.me.id,
        deviceId: result.tokens.deviceId,
        accessToken: result.tokens.accessToken,
        refreshToken: result.tokens.refreshToken,
        accessExpiresAt: DateTime.now().toUtc().add(Duration(seconds: result.tokens.expiresIn)),
      );
      await store.save(session);
      await store.saveProfile(result.me);
      api.attach(session);
      me = result.me;
      await _open(session);
      _set(AuthStatus.signedIn);
      return null;
    } on ApiException catch (e) {
      return e.message;
    } catch (_) {
      await _wipe();
      return 'Something went wrong setting up this device. Try again.';
    }
  }

  Future<void> _open(Session session) async {
    final dir = await _dirFor(session.deviceId);
    await dir.create(recursive: true);
    _accountDir = dir;
    final database = await cipher.openDatabase(
      '${dir.path}/local.db',
      password: await store.databaseKey(),
      version: LocalDb.version,
      onConfigure: LocalDb.onConfigure,
      onCreate: LocalDb.onCreate,
    );
    final db = LocalDb(database);
    _db = db;
    final core = ChatCore.open(
      dbPath: '${dir.path}/mls.db',
      userId: session.userId,
      deviceId: session.deviceId,
      storageKey: await store.storageKey(),
    );
    final next = SyncEngine(
      api: api,
      core: core,
      db: db,
      userId: session.userId,
      deviceId: session.deviceId,
      wsUri: AppConfig.wsUri(AppConfig.apiUrl),
      mediaDir: '${dir.path}/media',
    );
    engine = next;
    await next.start();
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } catch (_) {}
    await _wipe();
  }

  Future<String?> deleteAccount(String? password) async {
    try {
      await api.deleteAccount(password);
    } on ApiException catch (e) {
      return e.message;
    }
    await _wipe();
    return null;
  }

  void _onExpired() {
    unawaited(_wipe());
  }

  Future<void> _wipe() async {
    if (_wiping) return;
    _wiping = true;
    try {
      final current = engine;
      engine = null;
      if (current != null) await current.stop();
      await _db?.close();
      _db = null;
      _accountDir = null;
      final base = await getApplicationSupportDirectory();
      final accounts = Directory('${base.path}/accounts');
      if (await accounts.exists()) await accounts.delete(recursive: true);
      try {
        await clearTempFiles();
      } catch (_) {}
      await store.clear();
      api.detach();
      me = null;
    } finally {
      _wiping = false;
      _set(AuthStatus.signedOut);
    }
  }

  void _set(AuthStatus next) {
    status = next;
    notifyListeners();
  }
}
