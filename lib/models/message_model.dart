enum MessageKind { text, voiceNote, image, video, file, system }

MessageKind messageKindFromString(String s) {
  switch (s) {
    case 'voice_note': return MessageKind.voiceNote;
    case 'image': return MessageKind.image;
    case 'video': return MessageKind.video;
    case 'file': return MessageKind.file;
    case 'system': return MessageKind.system;
    default: return MessageKind.text;
  }
}

class MessageModel {
  final String id;
  final String conversationId;
  final String senderId;
  final String senderDisplayName;
  final String? senderAvatarUrl;
  final MessageKind kind;
  final String? content;
  final String? mediaUrl;
  final int? mediaDurationSecs;
  final String? replyToId;
  final bool isDeleted;
  final DateTime createdAt;

  const MessageModel({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderDisplayName,
    this.senderAvatarUrl,
    required this.kind,
    this.content,
    this.mediaUrl,
    this.mediaDurationSecs,
    this.replyToId,
    required this.isDeleted,
    required this.createdAt,
  });

  factory MessageModel.fromJson(Map<String, dynamic> json) {
    return MessageModel(
      id: json['id'] as String,
      conversationId: json['conversation_id'] as String,
      senderId: json['sender_id'] as String,
      senderDisplayName: json['sender_display_name'] as String,
      senderAvatarUrl: json['sender_avatar_url'] as String?,
      kind: messageKindFromString(json['kind'] as String),
      content: json['content'] as String?,
      mediaUrl: json['media_url'] as String?,
      mediaDurationSecs: json['media_duration_secs'] as int?,
      replyToId: json['reply_to_id'] as String?,
      isDeleted: json['is_deleted'] as bool,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
