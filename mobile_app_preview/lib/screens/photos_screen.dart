import 'package:flutter/material.dart';

import 'placeholder_detail_screen.dart';
import 'screen_shell.dart';

class PhotosScreen extends StatelessWidget {
  const PhotosScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Fotoğraflar',
      icon: Icons.photo_library,
      subtitle: 'Etkinlik galerileriniz ve satın alınan fotoğraflar.',
      content: [
        PreviewCard(
          title: 'Tüm Etkinlikler',
          subtitle: 'Toplam 420 fotoğraf',
          icon: Icons.collections,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const PlaceholderDetailScreen(
                title: 'Tüm Etkinlikler',
                description: 'Etkinlik bazlı fotoğraf listesi bu ekranda olacak.',
                icon: Icons.collections,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: 'Son Yüklenenler',
          subtitle: 'Bu hafta eklenen fotoğraflar',
          icon: Icons.new_releases,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const PlaceholderDetailScreen(
                title: 'Son Yüklenenler',
                description: 'Son yüklenen fotoğraflar bu ekranda listelenecek.',
                icon: Icons.new_releases,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: 'Favoriler',
          subtitle: 'Beğendiğiniz fotoğraflar',
          icon: Icons.favorite,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const PlaceholderDetailScreen(
                title: 'Favoriler',
                description: 'Favori fotoğraflarınız bu ekranda olacak.',
                icon: Icons.favorite,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
