import 'package:flutter/material.dart';

import 'screen_shell.dart';

class ProfileScreen extends StatelessWidget {
  final bool isLoggedIn;
  final String userName;
  final String userEmail;
  final VoidCallback onLoginTap;
  final VoidCallback onLogoutTap;

  const ProfileScreen({
    super.key,
    required this.isLoggedIn,
    required this.userName,
    required this.userEmail,
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
      subtitle: '$userName • $userEmail',
      content: [
        const PreviewCard(
          title: 'Biletlerim',
          subtitle: 'Katıldığınız etkinlik biletleri',
          icon: Icons.confirmation_num,
        ),
        const PreviewCard(
          title: 'Fotoğraflarım',
          subtitle: 'Eşleşen ve satın aldığınız fotoğraflar',
          icon: Icons.photo_library,
        ),
        const PreviewCard(
          title: 'Mesajlarım',
          subtitle: 'Organizatör ve destek konuşmaları',
          icon: Icons.mark_chat_unread,
        ),
        const PreviewCard(
          title: 'Ayarlar',
          subtitle: 'Bildirim, gizlilik, dil',
          icon: Icons.settings,
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
