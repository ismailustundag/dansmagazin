import 'package:flutter/material.dart';

import 'screen_shell.dart';

class PhotosScreen extends StatelessWidget {
  const PhotosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScreenShell(
      title: 'Fotoğraflar',
      icon: Icons.photo_library,
      subtitle: 'Etkinlik galerileriniz ve satın alınan fotoğraflar.',
      content: [
        PreviewCard(
          title: 'Tüm Etkinlikler',
          subtitle: 'Toplam 420 fotoğraf',
          icon: Icons.collections,
        ),
        PreviewCard(
          title: 'Son Yüklenenler',
          subtitle: 'Bu hafta eklenen fotoğraflar',
          icon: Icons.new_releases,
        ),
        PreviewCard(
          title: 'Favoriler',
          subtitle: 'Beğendiğiniz fotoğraflar',
          icon: Icons.favorite,
        ),
      ],
    );
  }
}
