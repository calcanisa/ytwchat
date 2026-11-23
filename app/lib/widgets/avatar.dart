import 'package:flutter/material.dart';
import '../models/conversation_model.dart';
import '../models/user_model.dart';
import '../utils/theme.dart';

class UserAvatar extends StatelessWidget {
  final UserModel user;
  final double radius;

  const UserAvatar({super.key, required this.user, this.radius = 24});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: AppTheme.surfaceVariant,
          backgroundImage:
              user.avatarUrl != null ? NetworkImage(user.avatarUrl!) : null,
          child: user.avatarUrl == null
              ? Text(user.displayName[0].toUpperCase(),
                  style: TextStyle(
                      fontSize: radius * 0.7, color: AppTheme.onSurface))
              : null,
        ),
        if (user.isOnline)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: radius * 0.55,
              height: radius * 0.55,
              decoration: BoxDecoration(
                color: AppTheme.online,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.background, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}

class ConversationAvatar extends StatelessWidget {
  final ConversationModel conversation;
  final String currentUserId;
  final double radius;

  const ConversationAvatar({
    super.key,
    required this.conversation,
    required this.currentUserId,
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    final avatarUrl = conversation.displayAvatar(currentUserId);
    final name = conversation.displayName(currentUserId);
    final online = conversation.isOnline(currentUserId);

    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: AppTheme.surfaceVariant,
          backgroundImage: avatarUrl != null ? NetworkImage(avatarUrl) : null,
          child: avatarUrl == null
              ? Text(name[0].toUpperCase(),
                  style: TextStyle(
                      fontSize: radius * 0.7, color: AppTheme.onSurface))
              : null,
        ),
        if (online)
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: radius * 0.55,
              height: radius * 0.55,
              decoration: BoxDecoration(
                color: AppTheme.online,
                shape: BoxShape.circle,
                border: Border.all(color: AppTheme.background, width: 1.5),
              ),
            ),
          ),
      ],
    );
  }
}
