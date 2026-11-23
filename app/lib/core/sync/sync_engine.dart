import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';

import '../../src/rust/api/chat.dart';
import '../../src/rust/api/media.dart';
import '../api/api_client.dart';
import '../api/models.dart';
import '../config.dart';
import '../crypto/envelope.dart';
import '../store/local_db.dart';
import 'serial_lock.dart';

sealed class SyncEvent {
  const SyncEvent();
}

class ConversationsChanged extends SyncEvent {
  const ConversationsChanged();
}

class MessagesChanged extends SyncEvent {
  final String conversationId;
  const MessagesChanged(this.conversationId);
}

class PresenceChanged extends SyncEvent {
  final String userId;
  final bool online;
  const PresenceChanged(this.userId, this.online);
}

class TypingSignal extends SyncEvent {
  final String conversationId;
  final String userId;
  const TypingSignal(this.conversationId, this.userId);
}

class CallSignal extends SyncEvent {
  final String conversationId;
  final String userId;
  final String deviceId;
  final Map<String, dynamic> data;
  const CallSignal(this.conversationId, this.userId, this.deviceId, this.data);
}

class ConnectionChanged extends SyncEvent {
  final bool connected;
  const ConnectionChanged(this.connected);
}

class SendException implements Exception {
  final String message;
  const SendException(this.message);
  @override
  String toString() => message;
}

enum _Outcome { sent, retry, failed }

class _Handled {
  final bool touched;
  final bool joined;
  const _Handled({this.touched = false, this.joined = false});
  static const none = _Handled();
}

class SyncEngine {
  final ApiClient api;
  final ChatCore core;
  final LocalDb db;
  final String userId;
  final String deviceId;
  final Uri wsUri;
  final String mediaDir;

  final _events = StreamController<SyncEvent>.broadcast();
  final _lock = SerialLock();
  final _random = Random.secure();
  final Map<String, bool> _online = {};
  final Map<String, DateTime> _reconciledAt = {};
  final Map<String, Timer> _updateTimers = {};
  final Map<String, DateTime> _typingSentAt = {};
  final Set<String> _delivering = {};
  final Set<String> _deliverAgain = {};
  final LinkedHashMap<String, Uint8List> _mediaCache = LinkedHashMap();
  int _mediaCacheBytes = 0;

  IOWebSocketChannel? _ws;
  StreamSubscription<dynamic>? _wsSub;
  Timer? _reconnectTimer;
  Timer? _keyTimer;
  int _backoffSeconds = 1;
  bool _running = false;
  bool _connected = false;
  bool _syncing = false;
  bool _syncAgain = false;

  String? activeConversationId;

  SyncEngine({
    required this.api,
    required this.core,
    required this.db,
    required this.userId,
    required this.deviceId,
    required this.wsUri,
    required this.mediaDir,
  });

  Stream<SyncEvent> get events => _events.stream;
  bool get connected => _connected;
  bool isOnline(String id) => _online[id] ?? false;

  void _emit(SyncEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  Future<void> start() async {
    if (_running) return;
    _running = true;
    await Directory(mediaDir).create(recursive: true);
    await maintainKeyPackages();
    try {
      await _refreshAll();
    } on ApiException {
      _emit(const ConversationsChanged());
    }
    _keyTimer = Timer.periodic(const Duration(hours: 1), (_) => maintainKeyPackages());
    _connect();
  }

  Future<void> stop() async {
    _running = false;
    _reconnectTimer?.cancel();
    _keyTimer?.cancel();
    for (final t in _updateTimers.values) {
      t.cancel();
    }
    _updateTimers.clear();
    await _wsSub?.cancel();
    await _ws?.sink.close();
    _ws = null;
    _connected = false;
    await _lock.run(() async {});
    await _events.close();
  }

  void resume() {
    if (!_running) return;
    if (_ws == null) {
      _reconnectTimer?.cancel();
      _backoffSeconds = 1;
      _connect();
    } else {
      unawaited(syncNow());
    }
  }

  void seedPresence(Iterable<Contact> contacts) {
    for (final c in contacts) {
      _online[c.user.id] = c.online;
    }
  }

  Future<void> _connect() async {
    if (!_running || _ws != null) return;
    final token = await api.accessToken();
    if (!_running) return;
    if (token == null) {
      _scheduleReconnect();
      return;
    }
    try {
      final channel = IOWebSocketChannel.connect(
        wsUri,
        pingInterval: const Duration(seconds: 25),
        connectTimeout: const Duration(seconds: 15),
      );
      await channel.ready;
      if (!_running) {
        await channel.sink.close();
        return;
      }
      channel.sink.add(jsonEncode({'type': 'auth', 'token': token}));
      _ws = channel;
      _wsSub = channel.stream.listen(
        _onFrame,
        onDone: _onClosed,
        onError: (_) => _onClosed(),
        cancelOnError: true,
      );
    } catch (_) {
      _onClosed();
    }
  }

  void _onClosed() {
    _wsSub?.cancel();
    _wsSub = null;
    _ws = null;
    if (_connected) {
      _connected = false;
      _emit(const ConnectionChanged(false));
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_running) return;
    _reconnectTimer?.cancel();
    final jitter = _random.nextInt(1000);
    _reconnectTimer = Timer(
      Duration(milliseconds: _backoffSeconds * 1000 + jitter),
      _connect,
    );
    _backoffSeconds = min(_backoffSeconds * 2, 30);
  }

  void _onFrame(dynamic data) {
    if (data is! String || data.length > 400 * 1024) return;
    final Map<String, dynamic> m;
    try {
      m = jsonDecode(data) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    switch (m['type']) {
      case 'ready':
        _connected = true;
        _backoffSeconds = 1;
        _emit(const ConnectionChanged(true));
        unawaited(_afterConnect());
      case 'error':
        if (m['code'] == 'unauthorized') {
          unawaited(api.refresh().whenComplete(() => _ws?.sink.close()));
        }
      case 'message.new':
        unawaited(syncNow());
      case 'conversation.updated':
        final id = m['conversation_id'];
        if (id is String && isUuid(id)) _onConversationUpdated(id);
      case 'presence':
        final id = m['user_id'];
        final online = m['online'];
        if (id is String && online is bool) {
          _online[id] = online;
          _emit(PresenceChanged(id, online));
        }
      case 'signal':
        _onSignal(m);
    }
  }

  Future<void> _afterConnect() async {
    try {
      await _refreshAll();
    } on ApiException {
      return;
    }
    await syncNow();
    for (final id in await db.conversationsWithOutbox()) {
      unawaited(_deliver(id));
    }
  }

  Future<void> _refreshAll() async {
    final list = await api.conversations();
    await db.syncConversations(list);
    final present = list.map((c) => c.id).toSet();
    await _lock.run(() async {
      for (final c in await db.conversations()) {
        if (!present.contains(c.id)) {
          if (core.hasGroup(conversationId: c.id)) {
            await core.deleteGroup(conversationId: c.id);
          }
          continue;
        }
        final ready = core.hasGroup(conversationId: c.id);
        final next = ready ? GroupState.ready : GroupState.waiting;
        if (c.state != next) await db.setState(c.id, next);
      }
    });
    _emit(const ConversationsChanged());
  }

  Future<void> syncNow() async {
    if (_syncing) {
      _syncAgain = true;
      return;
    }
    _syncing = true;
    final touched = <String>{};
    final joined = <String>{};
    try {
      do {
        _syncAgain = false;
        while (_running) {
          final batch = await api.pending(limit: 100);
          if (batch.isEmpty) break;
          for (final m in batch) {
            final r = await _lock.run(() => _safeHandle(m));
            if (r.touched) touched.add(m.conversationId);
            if (r.joined) joined.add(m.conversationId);
          }
          await api.ack(batch.map((m) => m.id).toList());
          if (batch.length < 100) break;
        }
      } while (_syncAgain && _running);
    } on ApiException {
      _syncAgain = false;
    } finally {
      _syncing = false;
    }
    for (final id in touched) {
      _emit(MessagesChanged(id));
    }
    if (touched.isNotEmpty || joined.isNotEmpty) _emit(const ConversationsChanged());
    if (joined.isNotEmpty) unawaited(maintainKeyPackages());
    for (final id in joined) {
      unawaited(_deliver(id));
    }
  }

  Future<_Handled> _safeHandle(ServerMessage m) async {
    try {
      return await _handle(m);
    } catch (_) {
      return _Handled.none;
    }
  }

  Future<_Handled> _handle(ServerMessage m) async {
    if (m.senderDeviceId == deviceId) return _Handled.none;
    final cid = m.conversationId;
    switch (m.kind) {
      case 'welcome':
        try {
          await core.joinFromWelcome(welcome: m.payload, expectedConversationId: cid);
        } catch (_) {
          return _Handled.none;
        }
        _reconciledAt.remove(cid);
        await _ensureLocalConversation(cid);
        await db.setState(cid, GroupState.ready);
        return const _Handled(touched: true, joined: true);
      case 'commit':
        if (!core.hasGroup(conversationId: cid)) return _Handled.none;
        final Incoming inc;
        try {
          inc = await core.process(conversationId: cid, message: m.payload);
        } catch (_) {
          return _Handled.none;
        }
        if (inc.removedSelf) {
          await core.deleteGroup(conversationId: cid);
          await db.setState(cid, GroupState.waiting);
        }
        return const _Handled(touched: true);
      case 'proposal':
        if (core.hasGroup(conversationId: cid)) {
          try {
            await core.process(conversationId: cid, message: m.payload);
          } catch (_) {}
        }
        return _Handled.none;
      case 'application':
        final env = await _open(cid, m.payload, m.senderUserId, m.senderDeviceId);
        if (env == null) return _Handled.none;
        if (env.type == EnvelopeType.meta) {
          final conv = await db.conversation(cid);
          if (conv != null && conv.isGroup && env.title != null) {
            await db.setTitle(cid, env.title!);
            return const _Handled(touched: true);
          }
          return _Handled.none;
        }
        if (!storedTypes.contains(env.type)) return _Handled.none;
        await _ensureLocalConversation(cid);
        final mine = m.senderUserId == userId;
        final inserted = await db.insertMessage(
          envelope: env,
          conversationId: cid,
          senderUserId: m.senderUserId,
          senderDeviceId: m.senderDeviceId,
          status: mine ? MessageStatus.sent : MessageStatus.received,
          countUnread: !mine && activeConversationId != cid,
        );
        return _Handled(touched: inserted);
    }
    return _Handled.none;
  }

  Future<Envelope?> _open(String cid, Uint8List payload, String senderUser, String senderDevice) async {
    if (!core.hasGroup(conversationId: cid)) return null;
    final Incoming inc;
    try {
      inc = await core.process(conversationId: cid, message: payload);
    } catch (_) {
      return null;
    }
    if (inc.kind != IncomingKind.application || inc.plaintext == null) return null;
    if (inc.senderUserId != senderUser || inc.senderDeviceId != senderDevice) return null;
    try {
      return Envelope.decode(inc.plaintext!);
    } on EnvelopeException {
      return null;
    }
  }

  Future<void> _ensureLocalConversation(String cid) async {
    if (await db.conversation(cid) != null) return;
    try {
      await db.upsertConversation(await api.conversation(cid));
    } on ApiException {
      return;
    }
  }

  void _onSignal(Map<String, dynamic> m) {
    final cid = m['conversation_id'];
    final senderUser = m['sender_user_id'];
    final senderDevice = m['sender_device_id'];
    final payload = m['payload'];
    if (cid is! String || senderUser is! String || senderDevice is! String || payload is! String) return;
    if (senderDevice == deviceId) return;
    final Uint8List bytes;
    try {
      bytes = base64.decode(payload);
    } catch (_) {
      return;
    }
    unawaited(_lock.run(() async {
      final env = await _open(cid, bytes, senderUser, senderDevice);
      if (env == null) return;
      if (env.type == EnvelopeType.typing && senderUser != userId) {
        _emit(TypingSignal(cid, senderUser));
      } else if (env.type == EnvelopeType.call && env.call != null) {
        _emit(CallSignal(cid, senderUser, senderDevice, env.call!));
      }
    }));
  }

  void _onConversationUpdated(String cid) {
    _updateTimers[cid]?.cancel();
    _updateTimers[cid] = Timer(Duration(milliseconds: 300 + _random.nextInt(1500)), () async {
      _updateTimers.remove(cid);
      if (!_running) return;
      try {
        await db.upsertConversation(await api.conversation(cid));
      } on ApiException catch (e) {
        if (e.isNotFound) await _markLeft(cid);
        return;
      }
      _emit(const ConversationsChanged());
      try {
        await _lock.run(() async {
          if (core.hasGroup(conversationId: cid)) await _reconcile(cid);
        });
      } catch (_) {
        return;
      }
      unawaited(_deliver(cid));
    });
  }

  Future<void> _markLeft(String cid) async {
    await _lock.run(() async {
      if (core.hasGroup(conversationId: cid)) await core.deleteGroup(conversationId: cid);
    });
    await db.setState(cid, GroupState.left);
    _emit(const ConversationsChanged());
  }

  Future<List<DeviceKeyPackage>> _claim(Map<String, List<String>?> wanted) async {
    final out = <DeviceKeyPackage>[];
    for (final entry in wanted.entries) {
      try {
        final claimed = await api.claimKeyPackages(entry.key, deviceIds: entry.value);
        for (final c in claimed) {
          out.add(DeviceKeyPackage(userId: entry.key, deviceId: c.deviceId, keyPackage: c.keyPackage));
        }
      } on ApiException catch (e) {
        if (e.isNetwork) rethrow;
      }
    }
    return out;
  }

  Future<bool> _createGroup(String cid) async {
    final conv = await api.conversation(cid);
    await db.upsertConversation(conv);
    if (conv.epoch > 0) return false;
    final packages = await _claim({for (final m in conv.members) m.user.id: null});
    if (packages.isEmpty) return false;
    try {
      await core.createGroup(conversationId: cid);
    } catch (_) {
      return false;
    }
    final CommitBundle bundle;
    try {
      bundle = await core.addMembers(conversationId: cid, keyPackages: packages);
    } catch (_) {
      await core.deleteGroup(conversationId: cid);
      return false;
    }
    return _publishCommit(cid, bundle, fresh: true);
  }

  Future<bool> _publishCommit(String cid, CommitBundle bundle, {bool fresh = false}) async {
    final epoch = bundle.epoch.toInt();
    var applied = false;
    try {
      await api.sendMessage(cid, kind: 'commit', payload: bundle.commit, epoch: epoch);
      applied = true;
    } on ApiException catch (e) {
      if (e.isNetwork) applied = await _resolveAmbiguousCommit(cid, epoch);
      if (!applied) {
        await core.discardCommit(conversationId: cid);
        if (fresh) await core.deleteGroup(conversationId: cid);
        if (e.isConflict) unawaited(syncNow());
        return false;
      }
    }
    await core.confirmCommit(conversationId: cid);
    _reconciledAt[cid] = DateTime.now();
    final welcome = bundle.welcome;
    if (welcome != null && bundle.welcomeDeviceIds.isNotEmpty) {
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          await api.sendMessage(cid, kind: 'welcome', payload: welcome, recipientDeviceIds: bundle.welcomeDeviceIds);
          break;
        } on ApiException catch (e) {
          if (!e.isNetwork || attempt == 3) break;
          await Future<void>.delayed(Duration(seconds: 1 << attempt));
        }
      }
      await _sendTitle(cid);
    }
    await db.setState(cid, GroupState.ready);
    return true;
  }

  Future<bool> _resolveAmbiguousCommit(String cid, int epoch) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      await Future<void>.delayed(Duration(seconds: 1 << attempt));
      try {
        final conv = await api.conversation(cid);
        if (conv.epoch <= epoch) return false;
        final pending = await api.pending(limit: 500);
        final rival = pending.any((m) => m.conversationId == cid && m.kind == 'commit' && m.epoch == epoch);
        return !rival;
      } on ApiException catch (e) {
        if (!e.isNetwork) return false;
      }
    }
    return false;
  }

  Future<void> _sendTitle(String cid) async {
    final conv = await db.conversation(cid);
    final title = conv?.title;
    if (conv == null || !conv.isGroup || title == null || title.isEmpty) return;
    try {
      final ct = await core.encrypt(conversationId: cid, plaintext: Envelope.meta(title).encode());
      await api.sendMessage(cid, kind: 'application', payload: ct);
    } catch (_) {}
  }

  Future<void> _reconcile(String cid) async {
    final Conversation conv;
    try {
      conv = await api.conversation(cid);
    } on ApiException catch (e) {
      if (e.isNotFound) {
        await core.deleteGroup(conversationId: cid);
        await db.setState(cid, GroupState.left);
      }
      return;
    }
    await db.upsertConversation(conv);
    if (conv.epoch != core.groupEpoch(conversationId: cid).toInt()) return;
    final devices = await api.conversationDevices(cid);
    final wanted = {for (final d in devices) d.key};
    final current = {for (final m in core.members(conversationId: cid)) '${m.userId}:${m.deviceId}': m};
    final own = '$userId:$deviceId';
    final remove = current.entries
        .where((e) => e.key != own && !wanted.contains(e.key))
        .map((e) => DeviceRef(userId: e.value.userId, deviceId: e.value.deviceId))
        .toList();
    if (remove.isNotEmpty) {
      final CommitBundle bundle;
      try {
        bundle = await core.removeMembers(conversationId: cid, devices: remove);
      } catch (_) {
        return;
      }
      if (!await _publishCommit(cid, bundle)) return;
    }
    final missing = <String, List<String>>{};
    for (final d in devices) {
      if (!current.containsKey(d.key) && d.key != own) {
        (missing[d.userId] ??= []).add(d.deviceId);
      }
    }
    if (missing.isNotEmpty) {
      final packages = await _claim(missing);
      if (packages.isNotEmpty) {
        final CommitBundle bundle;
        try {
          bundle = await core.addMembers(conversationId: cid, keyPackages: packages);
        } catch (_) {
          return;
        }
        if (!await _publishCommit(cid, bundle)) return;
      }
    }
    _reconciledAt[cid] = DateTime.now();
  }

  Future<bool> _prepare(String cid) async {
    if (!core.hasGroup(conversationId: cid)) {
      if (!await _createGroup(cid)) {
        await db.setState(cid, GroupState.waiting);
        return false;
      }
      return true;
    }
    final last = _reconciledAt[cid];
    if (last == null || DateTime.now().difference(last) > const Duration(minutes: 10)) {
      await _reconcile(cid);
    }
    return core.hasGroup(conversationId: cid);
  }

  Future<void> _deliver(String cid) async {
    if (!_running) return;
    if (_delivering.contains(cid)) {
      _deliverAgain.add(cid);
      return;
    }
    _delivering.add(cid);
    try {
      do {
        _deliverAgain.remove(cid);
        final outbox = await db.outbox(cid);
        if (outbox.isEmpty) break;
        final bool ready;
        try {
          ready = await _lock.run(() => _prepare(cid));
        } catch (_) {
          break;
        }
        if (!ready) {
          _emit(const ConversationsChanged());
          break;
        }
        for (final (id, env) in outbox) {
          final outcome = await _lock.run(() => _sendEnvelope(cid, env));
          if (outcome == _Outcome.retry) break;
          await db.setStatus(id, outcome == _Outcome.sent ? MessageStatus.sent : MessageStatus.failed);
          _emit(MessagesChanged(cid));
        }
      } while (_deliverAgain.contains(cid) && _running);
    } finally {
      _delivering.remove(cid);
    }
  }

  Future<_Outcome> _sendEnvelope(String cid, Envelope env) async {
    if (!core.hasGroup(conversationId: cid)) return _Outcome.retry;
    final Uint8List ct;
    try {
      ct = await core.encrypt(conversationId: cid, plaintext: env.encode());
    } catch (_) {
      return _Outcome.failed;
    }
    try {
      await api.sendMessage(cid, kind: 'application', payload: ct);
      return _Outcome.sent;
    } on ApiException catch (e) {
      if (e.isNetwork || e.status == 429 || (e.status ?? 0) >= 500) return _Outcome.retry;
      return _Outcome.failed;
    }
  }

  Future<LocalMessage> _queue(String cid, Envelope env) async {
    await db.insertMessage(
      envelope: env,
      conversationId: cid,
      senderUserId: userId,
      senderDeviceId: deviceId,
      status: MessageStatus.pending,
      countUnread: false,
    );
    _emit(MessagesChanged(cid));
    _emit(const ConversationsChanged());
    unawaited(_deliver(cid));
    return (await db.message(env.id))!;
  }

  Future<LocalMessage> sendText(String cid, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const SendException('Type a message first.');
    if (trimmed.length > AppConfig.maxTextLength) {
      throw const SendException('That message is too long.');
    }
    return _queue(cid, Envelope.text(trimmed));
  }

  Future<LocalMessage> sendMedia(
    String cid, {
    required EnvelopeType type,
    required Uint8List bytes,
    required String mime,
    String? name,
    int? durationMs,
  }) async {
    if (bytes.isEmpty) throw const SendException('That file is empty.');
    if (bytes.length > AppConfig.maxMediaBytes) {
      throw const SendException('Files can be up to 60 MB.');
    }
    final enc = await encryptMedia(data: bytes);
    final String mediaId;
    try {
      mediaId = await api.uploadMedia(enc.ciphertext);
    } on ApiException catch (e) {
      throw SendException(e.message);
    }
    await File('$mediaDir/$mediaId').writeAsBytes(enc.ciphertext, flush: true);
    _remember(mediaId, bytes);
    final ref = MediaRef(
      id: mediaId,
      key: enc.key,
      nonce: enc.nonce,
      sha256: enc.sha256,
      mime: mime,
      size: bytes.length,
      name: name == null ? null : sanitizeFileName(name),
      durationMs: durationMs,
    );
    return _queue(cid, Envelope.media(type, ref));
  }

  Future<void> retry(String messageId) async {
    final m = await db.message(messageId);
    if (m == null || m.status != MessageStatus.failed || m.senderDeviceId != deviceId) return;
    await db.setStatus(messageId, MessageStatus.pending);
    _emit(MessagesChanged(m.conversationId));
    unawaited(_deliver(m.conversationId));
  }

  void _remember(String id, Uint8List bytes) {
    if (bytes.length > 8 * 1024 * 1024) return;
    final old = _mediaCache.remove(id);
    if (old != null) _mediaCacheBytes -= old.length;
    _mediaCache[id] = bytes;
    _mediaCacheBytes += bytes.length;
    while (_mediaCacheBytes > 48 * 1024 * 1024 && _mediaCache.isNotEmpty) {
      final first = _mediaCache.keys.first;
      _mediaCacheBytes -= _mediaCache.remove(first)!.length;
    }
  }

  Future<Uint8List> mediaBytes(MediaRef ref) async {
    final cached = _mediaCache.remove(ref.id);
    if (cached != null) {
      _mediaCache[ref.id] = cached;
      return cached;
    }
    final file = File('$mediaDir/${ref.id}');
    Uint8List ciphertext;
    if (await file.exists()) {
      ciphertext = await file.readAsBytes();
    } else {
      ciphertext = await api.downloadMedia(ref.id);
      await file.writeAsBytes(ciphertext, flush: true);
    }
    final Uint8List plain;
    try {
      plain = await decryptMedia(ciphertext: ciphertext, key: ref.key, nonce: ref.nonce, sha256: ref.sha256);
    } catch (_) {
      if (await file.exists()) await file.delete();
      throw const SendException('This file could not be opened. It may have been changed.');
    }
    _remember(ref.id, plain);
    return plain;
  }

  Future<List<LocalConversation>> conversations() => db.conversations();

  Future<LocalConversation?> conversation(String id) => db.conversation(id);

  Future<List<LocalMessage>> messages(String cid, {int limit = 200, int? beforeSentAt}) =>
      db.messages(cid, limit: limit, beforeSentAt: beforeSentAt);

  Future<void> markRead(String cid) async {
    await db.markRead(cid);
    _emit(const ConversationsChanged());
  }

  Future<String> openDirect(String otherUserId) async {
    final conv = await api.createConversation('direct', [otherUserId]);
    await db.upsertConversation(conv);
    if (core.hasGroup(conversationId: conv.id)) await db.setState(conv.id, GroupState.ready);
    _emit(const ConversationsChanged());
    return conv.id;
  }

  static String? validateTitle(String title) {
    final t = title.trim();
    if (t.isEmpty) return 'Give the group a name.';
    if (t.length > 60) return 'Group names can be up to 60 characters.';
    return null;
  }

  Future<String> createGroup(String title, List<String> memberIds) async {
    final problem = validateTitle(title);
    if (problem != null) throw SendException(problem);
    final conv = await api.createConversation('group', memberIds);
    await db.upsertConversation(conv);
    await db.setTitle(conv.id, title.trim());
    _emit(const ConversationsChanged());
    unawaited(_lock.run(() async {
      try {
        if (!core.hasGroup(conversationId: conv.id)) await _createGroup(conv.id);
      } catch (_) {
        return;
      }
      _emit(const ConversationsChanged());
    }));
    return conv.id;
  }

  Future<void> renameGroup(String cid, String title) async {
    final problem = validateTitle(title);
    if (problem != null) throw SendException(problem);
    await db.setTitle(cid, title.trim());
    _emit(const ConversationsChanged());
    await _lock.run(() async {
      if (core.hasGroup(conversationId: cid)) await _sendTitle(cid);
    });
  }

  Future<void> addToGroup(String cid, List<String> userIds) async {
    await db.upsertConversation(await api.addMembers(cid, userIds));
    _emit(const ConversationsChanged());
    await _reconcileNow(cid);
  }

  Future<void> removeFromGroup(String cid, String memberId) async {
    await api.removeMember(cid, memberId);
    try {
      await db.upsertConversation(await api.conversation(cid));
    } on ApiException {
      return;
    }
    _emit(const ConversationsChanged());
    await _reconcileNow(cid);
  }

  Future<void> _reconcileNow(String cid) async {
    try {
      await _lock.run(() async {
        if (core.hasGroup(conversationId: cid)) await _reconcile(cid);
      });
    } catch (_) {
      return;
    }
    _emit(const ConversationsChanged());
  }

  Future<void> leaveGroup(String cid) async {
    await api.removeMember(cid, userId);
    await _markLeft(cid);
  }

  Future<void> deleteLocalConversation(String cid) async {
    await _lock.run(() async {
      if (core.hasGroup(conversationId: cid)) await core.deleteGroup(conversationId: cid);
    });
    await db.deleteConversation(cid);
    _emit(const ConversationsChanged());
  }

  List<MemberInfo> securityMembers(String cid) =>
      core.hasGroup(conversationId: cid) ? core.members(conversationId: cid) : const [];

  String ownFingerprint() => core.fingerprint();

  Future<void> typing(String cid) async {
    final last = _typingSentAt[cid];
    if (last != null && DateTime.now().difference(last) < const Duration(seconds: 4)) return;
    _typingSentAt[cid] = DateTime.now();
    await _signal(cid, Envelope.typing());
  }

  Future<bool> sendCallSignal(String cid, Map<String, dynamic> data, {List<String>? toDeviceIds}) =>
      _signal(cid, Envelope.call(data), toDeviceIds: toDeviceIds);

  Future<bool> _signal(String cid, Envelope env, {List<String>? toDeviceIds}) async {
    final ws = _ws;
    if (ws == null || !_connected) return false;
    final ct = await _lock.run(() async {
      if (!core.hasGroup(conversationId: cid)) return null;
      return core.encrypt(conversationId: cid, plaintext: env.encode());
    });
    if (ct == null || _ws != ws) return false;
    ws.sink.add(jsonEncode({
      'type': 'signal',
      'conversation_id': cid,
      'payload': base64.encode(ct),
      'to_device_ids': ?toDeviceIds,
    }));
    return true;
  }

  Future<void> maintainKeyPackages() async {
    try {
      final count = await api.keyPackageCount();
      final lastResort = count.hasLastResort ? null : await core.lastResortKeyPackage();
      final need = count.available < AppConfig.keyPackageLowWater
          ? min(AppConfig.keyPackageTarget - count.available, 100)
          : 0;
      if (need <= 0 && lastResort == null) return;
      final packages = need > 0 ? await core.generateKeyPackages(count: need) : <Uint8List>[];
      await api.uploadKeyPackages(packages, lastResort: lastResort);
    } on ApiException {
      return;
    }
  }
}
