import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/store/local_db.dart';
import '../utils/theme.dart';
import 'avatar.dart';

class ConversationTile extends StatelessWidget {
  final LocalConversation conversation;
  final String me;
  final bool online;
  final bool typing;
  final VoidCallback onTap;

  const ConversationTile({
    super.key,
    required this.conversation,
    required this.me,
    required this.online,
    required this.typing,
    required this.onTap,
  });

  static String formatTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return DateFormat('HH:mm').format(local);
    }
    if (now.difference(local).inDays < 7) return DateFormat('EEE').format(local);
    return DateFormat('dd/MM/yy').format(local);
  }

  String _subtitle() {
    if (typing) return 'typing...';
    if (conversation.state == GroupState.left) return 'You are no longer in this chat';
    final preview = conversation.lastPreview;
    if (preview == null || preview.isEmpty) {
      return conversation.state == GroupState.waiting ? 'Setting up encryption' : 'No messages yet';
    }
    if (conversation.isGroup && conversation.lastSenderId != null) {
      final who = conversation.lastSenderId == me
          ? 'You'
          : conversation.member(conversation.lastSenderId!)?.user.displayName;
      if (who != null) return '$who: $preview';
    }
    return conversation.lastSenderId == me ? 'You: $preview' : preview;
  }

  @override
  Widget build(BuildContext context) {
    final name = conversation.displayName(me);
    final hasUnread = conversation.unread > 0;
    final time = conversation.lastAt ?? conversation.lastActivityAt;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            InitialAvatar(name: name, radius: 26, online: online, group: conversation.isGroup),
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
                      Text(
                        formatTime(time),
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
                          _subtitle(),
                          style: TextStyle(
                            fontSize: 13,
                            color: typing
                                ? AppTheme.primary
                                : hasUnread
                                    ? AppTheme.onSurface
                                    : AppTheme.onSurfaceMuted,
                            fontWeight: hasUnread ? FontWeight.w500 : FontWeight.normal,
                          ),
                          maxLines: 1,
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
                            conversation.unread > 99 ? '99+' : '${conversation.unread}',
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
