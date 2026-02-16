import 'package:flutter/material.dart';

import 'screen_shell.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScreenShell(
      title: 'Keşfet',
      icon: Icons.explore,
      subtitle: 'Öne çıkan etkinlikleri ve albümleri keşfedin.',
      content: [
        PreviewCard(
          title: 'Bu Hafta Öne Çıkan',
          subtitle: 'Yeni duyurular ve popüler etkinlikler',
          icon: Icons.local_fire_department,
        ),
        PreviewCard(
          title: 'Yaklaşan Etkinlikler',
          subtitle: 'Tarih yaklaşan etkinlik önerileri',
          icon: Icons.event,
        ),
        PreviewCard(
          title: 'Yeni Fotoğraf Albümleri',
          subtitle: 'Son eklenen galeriler',
          icon: Icons.photo_library,
        ),
      ],
    );
  }
}
