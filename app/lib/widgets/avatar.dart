import 'package:flutter/material.dart';

import '../core/api/models.dart';
import '../utils/theme.dart';

class InitialAvatar extends StatelessWidget {
  final String name;
  final double radius;
  final bool online;
  final bool group;

  const InitialAvatar({
    super.key,
    required this.name,
    this.radius = 24,
    this.online = false,
    this.group = false,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: AppTheme.surfaceVariant,
          child: group
              ? Icon(Icons.group, size: radius, color: AppTheme.onSurface)
              : Text(
                  initialOf(name),
                  style: TextStyle(fontSize: radius * 0.7, color: AppTheme.onSurface),
                ),
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
