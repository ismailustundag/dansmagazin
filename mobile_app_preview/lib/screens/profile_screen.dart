import 'package:flutter/material.dart';

import '../services/i18n.dart';
import 'my_photos_screen.dart';
import 'screen_shell.dart';
import 'tickets_screen.dart';
import 'editor_event_management_screen.dart';
import 'settings_screen.dart';
import 'notifications_screen.dart';

class ProfileScreen extends StatelessWidget {
  final bool isLoggedIn;
  final String userName;
  final String userEmail;
  final String sessionToken;
  final int accountId;
  final int? wpUserId;
  final List<String> wpRoles;
  final bool canCreateMobileEvent;
  final VoidCallback onLoginTap;
  final VoidCallback onLogoutTap;

  const ProfileScreen({
    super.key,
    required this.isLoggedIn,
    required this.userName,
    required this.userEmail,
    required this.sessionToken,
    required this.accountId,
    required this.wpUserId,
    required this.wpRoles,
    required this.canCreateMobileEvent,
    required this.onLoginTap,
    required this.onLogoutTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    if (!isLoggedIn) {
      return ScreenShell(
        title: t('profile'),
        icon: Icons.person,
        subtitle: t('profile_subtitle_guest'),
        content: [
          PreviewCard(
            title: t('login'),
            subtitle: t('login_subtitle'),
            icon: Icons.login,
            onTap: onLoginTap,
          ),
        ],
      );
    }
    return ScreenShell(
      title: t('profile'),
      icon: Icons.person,
      subtitle: '$userName • $userEmail${wpRoles.isNotEmpty ? ' • ${wpRoles.join(",")}' : ''}',
      content: [
        PreviewCard(
          title: t('my_tickets'),
          subtitle: t('my_tickets_subtitle'),
          icon: Icons.confirmation_num,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TicketsScreen(
                sessionToken: sessionToken,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: t('my_photos'),
          subtitle: t('my_photos_subtitle'),
          icon: Icons.photo_library,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MyPhotosScreen(
                accountId: accountId,
              ),
            ),
          ),
        ),
        if (canCreateMobileEvent || wpRoles.contains('administrator') || wpRoles.contains('editor'))
          PreviewCard(
            title: t('event_management'),
            subtitle: t('event_management_subtitle'),
            icon: Icons.event_note,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => EditorEventManagementScreen(sessionToken: sessionToken),
              ),
            ),
          ),
        PreviewCard(
          title: t('notifications'),
          subtitle: t('notifications_subtitle'),
          icon: Icons.notifications,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NotificationsScreen(sessionToken: sessionToken),
            ),
          ),
        ),
        PreviewCard(
          title: t('settings'),
          subtitle: t('settings_subtitle'),
          icon: Icons.settings,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
              builder: (_) => SettingsScreen(sessionToken: sessionToken),
              ),
            ),
          ),
        PreviewCard(
          title: t('logout'),
          subtitle: t('logout_subtitle'),
          icon: Icons.logout,
          onTap: onLogoutTap,
        ),
      ],
    );
  }
}
