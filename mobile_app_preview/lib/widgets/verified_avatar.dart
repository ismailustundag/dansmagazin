import 'package:characters/characters.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class VerifiedBadge extends StatelessWidget {
  final double size;
  final double emojiScale;

  const VerifiedBadge({
    super.key,
    this.size = 18,
    this.emojiScale = 0.72,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: AppTheme.bgPrimary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withOpacity(0.14), width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        '💫',
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: size * emojiScale,
          height: 1,
        ),
      ),
    );
  }
}

class VerifiedAvatar extends StatelessWidget {
  final String imageUrl;
  final String label;
  final bool isVerified;
  final double radius;
  final Color backgroundColor;
  final TextStyle? fallbackStyle;

  const VerifiedAvatar({
    super.key,
    required this.imageUrl,
    required this.label,
    required this.isVerified,
    this.radius = 20,
    this.backgroundColor = AppTheme.surfaceElevated,
    this.fallbackStyle,
  });

  @override
  Widget build(BuildContext context) {
    final resolvedUrl = imageUrl.trim();
    final fallbackLabel = label.trim().isNotEmpty ? label.trim().characters.first.toUpperCase() : '?';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: radius,
          backgroundColor: backgroundColor,
          backgroundImage: resolvedUrl.isNotEmpty ? NetworkImage(resolvedUrl) : null,
          child: resolvedUrl.isNotEmpty
              ? null
              : Text(
                  fallbackLabel,
                  style: fallbackStyle ??
                      TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: radius * 0.8,
                      ),
                ),
        ),
        if (isVerified)
          Positioned(
            right: -1,
            bottom: -1,
            child: VerifiedBadge(size: radius * 0.9),
          ),
      ],
    );
  }
}
