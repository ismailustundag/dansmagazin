import 'package:flutter/material.dart';

import 'screen_shell.dart';

class EventsScreen extends StatelessWidget {
  const EventsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScreenShell(
      title: 'Etkinlikler',
      icon: Icons.event,
      subtitle: 'Katılabileceğiniz etkinlikler ve detayları.',
      content: [
        PreviewCard(
          title: 'Latin Weekend',
          subtitle: '5-7 Temmuz • Ankara',
          icon: Icons.music_note,
        ),
        PreviewCard(
          title: 'Salsa Night',
          subtitle: '27 Mayıs • Ankara',
          icon: Icons.nightlife,
        ),
        PreviewCard(
          title: 'Bachata Fest',
          subtitle: '30 Mayıs • İstanbul',
          icon: Icons.celebration,
        ),
      ],
    );
  }
}
