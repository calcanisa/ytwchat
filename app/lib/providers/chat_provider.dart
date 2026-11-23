import 'dart:async';
import 'package:flutter/material.dart';
import '../models/conversation_model.dart';
import '../models/message_model.dart';
import '../models/user_model.dart';
import '../services/api_service.dart';
import '../services/websocket_service.dart';

class ChatProvider extends ChangeNotifier {
  final ApiService _api;
  final WebSocketService _ws;

  List<ConversationModel> _conversations = [];
  final Map<String, List<MessageModel>> _messages = {};
  final Map<String, bool> _typingUsers = {};
  final Map<String, bool> _onlineUsers = {};

  StreamSubscription? _wsSub;
  String? _error;

  List<ConversationModel> get conversations => _conversations;
  String? get error => _error;

  ChatProvider(this._api, this._ws);

  void init() {
    _wsSub = _ws.stream?.listen(_handleWsEvent);
  }

  void _handleWsEvent(WsMessage msg) {
    switch (msg.event) {
      case WsEvent.newMessage:
        final message = MessageModel.fromJson(msg.data);
        _addMessage(message);
        _updateConversationLastMessage(message);
        notifyListeners();
        break;

      case WsEvent.userOnline:
        _onlineUsers[msg.data['user_id'] as String] = true;
        _updateMemberOnlineStatus(msg.data['user_id'] as String, true);
        notifyListeners();
        break;

      case WsEvent.userOffline:
        _onlineUsers[msg.data['user_id'] as String] = false;
        _updateMemberOnlineStatus(msg.data['user_id'] as String, false);
        notifyListeners();
        break;

      case WsEvent.typingStart:
        _typingUsers[msg.data['user_id'] as String] = true;
        notifyListeners();
        break;

      case WsEvent.typingStop:
        _typingUsers.remove(msg.data['user_id'] as String);
        notifyListeners();
        break;

      case WsEvent.messageRead:
        final convId = msg.data['conversation_id'] as String;
        final idx = _conversations.indexWhere((c) => c.id == convId);
        if (idx != -1) {
          _conversations[idx] = _conversations[idx].copyWith(unreadCount: 0);
          notifyListeners();
        }
        break;

      default:
        break;
    }
  }

  Future<void> loadConversations() async {
    try {
      _conversations = await _api.getConversations();
      notifyListeners();
    } catch (e) {
      _error = 'Failed to load conversations';
      notifyListeners();
    }
  }

  Future<List<MessageModel>> loadMessages(String conversationId) async {
    try {
      final messages = await _api.getMessages(conversationId);
      _messages[conversationId] = messages.reversed.toList();
      notifyListeners();
      return _messages[conversationId]!;
    } catch (e) {
      _error = 'Failed to load messages';
      notifyListeners();
      return [];
    }
  }

  List<MessageModel> getMessages(String conversationId) {
    return _messages[conversationId] ?? [];
  }

  bool isTyping(String userId) => _typingUsers[userId] ?? false;
  bool isOnline(String userId) => _onlineUsers[userId] ?? false;

  Future<ConversationModel?> startDirectConversation(String otherUserId) async {
    try {
      final conv = await _api.createDirectConversation(otherUserId);
      final exists = _conversations.any((c) => c.id == conv.id);
      if (!exists) {
        _conversations.insert(0, conv);
        notifyListeners();
      }
      return conv;
    } catch (e) {
      _error = 'Failed to start conversation';
      notifyListeners();
      return null;
    }
  }

  Future<void> markRead(String conversationId) async {
    try {
      await _api.markRead(conversationId);
      final idx = _conversations.indexWhere((c) => c.id == conversationId);
      if (idx != -1) {
        _conversations[idx] = _conversations[idx].copyWith(unreadCount: 0);
        notifyListeners();
      }
    } catch (_) {}
  }

  void _addMessage(MessageModel message) {
    final list = _messages[message.conversationId] ?? [];
    list.add(message);
    _messages[message.conversationId] = list;
  }

  void _updateConversationLastMessage(MessageModel message) {
    final idx =
        _conversations.indexWhere((c) => c.id == message.conversationId);
    if (idx != -1) {
      final conv = _conversations[idx];
      _conversations[idx] = conv.copyWith(
        lastMessage: LastMessage(
          id: message.id,
          senderId: message.senderId,
          content: message.content,
          kind: message.kind.name,
          createdAt: message.createdAt,
        ),
        unreadCount: conv.unreadCount + 1,
      );
      _conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
  }

  void _updateMemberOnlineStatus(String userId, bool isOnline) {
    for (var i = 0; i < _conversations.length; i++) {
      final conv = _conversations[i];
      final memberIdx = conv.members.indexWhere((m) => m.id == userId);
      if (memberIdx != -1) {
        final updatedMembers = List<UserModel>.from(conv.members);
        updatedMembers[memberIdx] =
            updatedMembers[memberIdx].copyWith(isOnline: isOnline);
        _conversations[i] = ConversationModel(
          id: conv.id,
          kind: conv.kind,
          name: conv.name,
          avatarUrl: conv.avatarUrl,
          members: updatedMembers,
          lastMessage: conv.lastMessage,
          unreadCount: conv.unreadCount,
          updatedAt: conv.updatedAt,
        );
      }
    }
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }
}
