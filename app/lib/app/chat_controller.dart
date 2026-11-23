import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/api/api_client.dart';
import '../core/api/models.dart';
import '../core/store/local_db.dart';
import '../core/sync/sync_engine.dart';

class ChatController extends ChangeNotifier {
  final SyncEngine engine;
  StreamSubscription<SyncEvent>? _sub;
  Timer? _reloadTimer;
  final _messageUpdates = StreamController<String>.broadcast();
  final Map<String, Map<String, DateTime>> _typing = {};
  Timer? _typingSweep;

  List<LocalConversation> conversations = [];
  List<Contact> contacts = [];
  bool connected = false;
  bool loaded = false;

  ChatController(this.engine) {
    connected = engine.connected;
    _sub = engine.events.listen(_onEvent);
    unawaited(_reload());
    unawaited(loadContacts());
    _typingSweep = Timer.periodic(const Duration(seconds: 2), (_) => _sweepTyping());
  }

  String get me => engine.userId;

  Stream<String> get messageUpdates => _messageUpdates.stream;

  void _onEvent(SyncEvent e) {
    switch (e) {
      case ConversationsChanged():
        _scheduleReload();
      case MessagesChanged(:final conversationId):
        _typing[conversationId]?.clear();
        if (!_messageUpdates.isClosed) _messageUpdates.add(conversationId);
      case PresenceChanged():
        notifyListeners();
      case TypingSignal(:final conversationId, :final userId):
        (_typing[conversationId] ??= {})[userId] = DateTime.now().add(const Duration(seconds: 6));
        notifyListeners();
      case ConnectionChanged(connected: final c):
        connected = c;
        notifyListeners();
      case CallSignal():
        break;
    }
  }

  void _sweepTyping() {
    var changed = false;
    final now = DateTime.now();
    for (final entry in _typing.values) {
      final before = entry.length;
      entry.removeWhere((_, until) => until.isBefore(now));
      if (entry.length != before) changed = true;
    }
    if (changed) notifyListeners();
  }

  List<String> typingIn(String cid) => _typing[cid]?.keys.toList() ?? const [];

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(const Duration(milliseconds: 120), _reload);
  }

  Future<void> _reload() async {
    try {
      conversations = await engine.conversations();
    } catch (_) {
      return;
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> loadContacts() async {
    try {
      contacts = await engine.api.contacts();
      engine.seedPresence(contacts);
      notifyListeners();
    } on ApiException {
      return;
    }
  }

  bool isContact(String userId) => contacts.any((c) => c.user.id == userId);

  Future<void> addContact(PublicUser user) async {
    await engine.api.addContact(user.id);
    await loadContacts();
  }

  Future<void> removeContact(String userId) async {
    await engine.api.removeContact(userId);
    await loadContacts();
  }

  bool isOnline(String userId) => engine.isOnline(userId);

  LocalConversation? byId(String id) => conversations.where((c) => c.id == id).firstOrNull;

  int get unreadTotal => conversations.fold(0, (sum, c) => sum + c.unread);

  @override
  void dispose() {
    _sub?.cancel();
    _reloadTimer?.cancel();
    _typingSweep?.cancel();
    _messageUpdates.close();
    super.dispose();
  }
}
