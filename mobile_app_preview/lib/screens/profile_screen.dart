import 'package:flutter/material.dart';

import 'my_photos_screen.dart';
import 'screen_shell.dart';
import 'tickets_screen.dart';
import 'editor_event_management_screen.dart';
import 'settings_screen.dart';

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
    if (!isLoggedIn) {
      return ScreenShell(
        title: 'Profil',
        icon: Icons.person,
        subtitle: 'Kişisel alanınıza erişmek için giriş yapın.',
        content: [
          PreviewCard(
            title: 'Giriş Yap',
            subtitle: 'Biletler, mesajlar ve satın alınan fotoğraflar',
            icon: Icons.login,
            onTap: onLoginTap,
          ),
        ],
      );
    }
    return ScreenShell(
      title: 'Profil',
      icon: Icons.person,
      subtitle: '$userName • $userEmail${wpRoles.isNotEmpty ? ' • ${wpRoles.join(",")}' : ''}',
      content: [
        PreviewCard(
          title: 'Biletlerim',
          subtitle: 'Katıldığınız etkinlik biletleri',
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
          title: 'Fotoğraflarım',
          subtitle: 'Favorilediğiniz ve kaydettiğiniz fotoğraflar',
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
            title: 'Etkinlik Yönetimi',
            subtitle: 'Etkinlik oluştur, yönet ve bilet kontrol et',
            icon: Icons.event_note,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => EditorEventManagementScreen(sessionToken: sessionToken),
              ),
            ),
          ),
        PreviewCard(
          title: 'Ayarlar',
          subtitle: 'Bildirim, dil ve profil fotoğrafı',
          icon: Icons.settings,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
              builder: (_) => SettingsScreen(sessionToken: sessionToken),
              ),
            ),
          ),
        PreviewCard(
          title: 'Çıkış Yap',
          subtitle: 'Bu cihazdaki oturumu kapat',
          icon: Icons.logout,
          onTap: onLogoutTap,
        ),
      ],
    );
  }
}
