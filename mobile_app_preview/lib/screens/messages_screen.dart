import 'package:flutter/material.dart';

import 'screen_shell.dart';

class MessagesScreen extends StatelessWidget {
  final bool isLoggedIn;
  final VoidCallback onLoginTap;

  const MessagesScreen({
    super.key,
    required this.isLoggedIn,
    required this.onLoginTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn) {
      return ScreenShell(
        title: 'Mesajlar',
        icon: Icons.chat_bubble,
        subtitle: 'Mesajları görmek için giriş yapın.',
        content: [
          PreviewCard(
            title: 'Giriş Yap',
            subtitle: 'Mesajlarınızı ve destek yanıtlarını görmek için',
            icon: Icons.login,
            onTap: onLoginTap,
          ),
        ],
      );
    }
    return const ScreenShell(
        title: 'Mesajlar',
        icon: Icons.chat_bubble,
        subtitle: 'Organizatör ve destek ekibi mesajları.',
        content: [
          PreviewCard(
            title: 'Organizatör Burak',
            subtitle: 'Etkinlik saat kaçta başlıyor?',
            icon: Icons.person,
          ),
          PreviewCard(
            title: 'Dansmagazin Destek',
            subtitle: 'Fotoğraflar yüklenince bildirim gelecek.',
            icon: Icons.support_agent,
          ),
          PreviewCard(
            title: 'Ayşe',
            subtitle: 'Albüm linkini gönderdim.',
            icon: Icons.person_2,
          ),
        ]);
  }
}
