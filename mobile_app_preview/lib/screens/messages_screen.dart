import 'package:flutter/material.dart';

import 'screen_shell.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
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
      ],
    );
  }
}
