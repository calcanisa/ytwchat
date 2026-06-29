import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/conversation_model.dart';
import '../utils/theme.dart';
import 'avatar.dart';

class ConversationTile extends StatelessWidget {
  final ConversationModel conversation;
  final String currentUserId;
  final VoidCallback onTap;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.currentUserId,
    required this.onTap,
  });

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day && dt.month == now.month && dt.year == now.year) {
      return DateFormat('HH:mm').format(dt);
    }
    if (now.difference(dt).inDays < 7) {
      return DateFormat('EEE').format(dt);
    }
    return DateFormat('dd/MM/yy').format(dt);
  }

  String _lastMessagePreview() {
    final msg = conversation.lastMessage;
    if (msg == null) return '';
    switch (msg.kind) {
      case 'voice_note': return '🎤 Voice note';
      case 'image': return '📷 Photo';
      case 'video': return '🎥 Video';
      case 'file': return '📎 File';
      default: return msg.content ?? '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName(currentUserId);
    final preview = _lastMessagePreview();
    final hasUnread = conversation.unreadCount > 0;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            ConversationAvatar(
              conversation: conversation,
              currentUserId: currentUserId,
              radius: 26,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w500,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (conversation.lastMessage != null)
                        Text(
                          _formatTime(conversation.lastMessage!.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: hasUnread ? AppTheme.primary : AppTheme.onSurfaceMuted,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          preview,
                          style: TextStyle(
                            fontSize: 13,
                            color: hasUnread ? AppTheme.onSurface : AppTheme.onSurfaceMuted,
                            fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasUnread)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: const BoxDecoration(
                            color: AppTheme.primary,
                            borderRadius: BorderRadius.all(Radius.circular(10)),
                          ),
                          child: Text(
                            conversation.unreadCount > 99 ? '99+' : '${conversation.unreadCount}',
                            style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
