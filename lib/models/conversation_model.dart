import 'user_model.dart';

enum ConversationKind { direct, group }

class LastMessage {
  final String id;
  final String senderId;
  final String? content;
  final String kind;
  final DateTime createdAt;

  const LastMessage({
    required this.id,
    required this.senderId,
    this.content,
    required this.kind,
    required this.createdAt,
  });

  factory LastMessage.fromJson(Map<String, dynamic> json) {
    return LastMessage(
      id: json['id'] as String,
      senderId: json['sender_id'] as String,
      content: json['content'] as String?,
      kind: json['kind'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}

class ConversationModel {
  final String id;
  final ConversationKind kind;
  final String? name;
  final String? avatarUrl;
  final List<UserModel> members;
  final LastMessage? lastMessage;
  final int unreadCount;
  final DateTime updatedAt;

  const ConversationModel({
    required this.id,
    required this.kind,
    this.name,
    this.avatarUrl,
    required this.members,
    this.lastMessage,
    required this.unreadCount,
    required this.updatedAt,
  });

  factory ConversationModel.fromJson(Map<String, dynamic> json) {
    return ConversationModel(
      id: json['id'] as String,
      kind: json['kind'] == 'direct' ? ConversationKind.direct : ConversationKind.group,
      name: json['name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      members: (json['members'] as List).map((m) => UserModel.fromJson(m)).toList(),
      lastMessage: json['last_message'] != null
          ? LastMessage.fromJson(json['last_message'])
          : null,
      unreadCount: json['unread_count'] as int,
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  String displayName(String currentUserId) {
    if (kind == ConversationKind.group) return name ?? 'Group';
    final other = members.where((m) => m.id != currentUserId).firstOrNull;
    return other?.displayName ?? 'Unknown';
  }

  String? displayAvatar(String currentUserId) {
    if (kind == ConversationKind.group) return avatarUrl;
    final other = members.where((m) => m.id != currentUserId).firstOrNull;
    return other?.avatarUrl;
  }

  bool isOnline(String currentUserId) {
    if (kind == ConversationKind.group) return false;
    final other = members.where((m) => m.id != currentUserId).firstOrNull;
    return other?.isOnline ?? false;
  }

  ConversationModel copyWith({int? unreadCount, LastMessage? lastMessage}) {
    return ConversationModel(
      id: id,
      kind: kind,
      name: name,
      avatarUrl: avatarUrl,
      members: members,
      lastMessage: lastMessage ?? this.lastMessage,
      unreadCount: unreadCount ?? this.unreadCount,
      updatedAt: updatedAt,
    );
  }
}
