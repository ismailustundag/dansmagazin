import 'package:flutter/material.dart';

import '../services/i18n.dart';
import '../services/profile_api.dart';
import 'admin_notifications_screen.dart';
import 'editor_event_management_screen.dart';
import 'my_photos_screen.dart';
import 'notifications_screen.dart';
import 'screen_shell.dart';
import 'settings_screen.dart';
import 'tickets_screen.dart';

class ProfileScreen extends StatefulWidget {
  final bool isLoggedIn;
  final String userName;
  final String userEmail;
  final String sessionToken;
  final int accountId;
  final int? wpUserId;
  final List<String> wpRoles;
  final String appRole;
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
    required this.appRole,
    required this.canCreateMobileEvent,
    required this.onLoginTap,
    required this.onLogoutTap,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  String _displayName = '';
  String _avatarUrl = '';

  @override
  void initState() {
    super.initState();
    _displayName = widget.userName;
    _loadProfileVisuals();
  }

  Future<void> _loadProfileVisuals() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty || !widget.isLoggedIn) return;
    try {
      final s = await ProfileApi.settings(token);
      if (!mounted) return;
      setState(() {
        _displayName = s.username.trim().isEmpty ? widget.userName : s.username.trim();
        _avatarUrl = s.avatarUrl.trim();
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    if (!widget.isLoggedIn) {
      return ScreenShell(
        title: t('profile'),
        icon: Icons.person,
        subtitle: t('profile_subtitle_guest'),
        content: [
          PreviewCard(
            title: t('login'),
            subtitle: t('login_subtitle'),
            icon: Icons.login,
            onTap: widget.onLoginTap,
          ),
        ],
      );
    }

    final greetingName = _displayName.trim().isEmpty ? widget.userName : _displayName;
    final initials = greetingName.trim().isNotEmpty ? greetingName.trim().substring(0, 1).toUpperCase() : 'U';

    return ScreenShell(
      title: t('profile'),
      icon: Icons.person,
      subtitle: widget.userEmail,
      content: [
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFF121826),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              _avatarUrl.isNotEmpty
                  ? CircleAvatar(radius: 28, backgroundImage: NetworkImage(_avatarUrl))
                  : CircleAvatar(
                      radius: 28,
                      backgroundColor: const Color(0xFFE53935),
                      child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                    ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Merhaba $greetingName',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ),
        PreviewCard(
          title: t('my_tickets'),
          subtitle: t('my_tickets_subtitle'),
          icon: Icons.confirmation_num,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TicketsScreen(
                sessionToken: widget.sessionToken,
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
                accountId: widget.accountId,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: t('notifications'),
          subtitle: t('notifications_subtitle'),
          icon: Icons.notifications,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => NotificationsScreen(sessionToken: widget.sessionToken),
            ),
          ),
        ),
        if (widget.appRole == 'super_admin')
          PreviewCard(
            title: 'Bildirim Gönder',
            subtitle: 'Kullanıcılara mobil bildirim gönder',
            icon: Icons.campaign,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => AdminNotificationsScreen(sessionToken: widget.sessionToken),
              ),
            ),
          ),
        if (widget.canCreateMobileEvent || widget.wpRoles.contains('administrator') || widget.wpRoles.contains('editor'))
          PreviewCard(
            title: t('event_management'),
            subtitle: t('event_management_subtitle'),
            icon: Icons.event_note,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => EditorEventManagementScreen(sessionToken: widget.sessionToken),
              ),
            ),
          ),
        PreviewCard(
          title: t('settings'),
          subtitle: t('settings_subtitle'),
          icon: Icons.settings,
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => SettingsScreen(sessionToken: widget.sessionToken),
              ),
            );
            await _loadProfileVisuals();
          },
        ),
        PreviewCard(
          title: t('logout'),
          subtitle: t('logout_subtitle'),
          icon: Icons.logout,
          onTap: widget.onLogoutTap,
        ),
      ],
    );
  }
}
