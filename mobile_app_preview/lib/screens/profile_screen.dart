import 'package:flutter/material.dart';

import 'screen_shell.dart';

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScreenShell(
      title: 'Profil',
      icon: Icons.person,
      subtitle: 'Hesap bilgileri ve uygulama ayarları.',
      content: [
        PreviewCard(
          title: 'Biletlerim',
          subtitle: 'Katıldığınız etkinlik biletleri',
          icon: Icons.confirmation_num,
        ),
        PreviewCard(
          title: 'Satın Aldığım Fotoğraflar',
          subtitle: 'Ödeme yapılmış fotoğraflar',
          icon: Icons.shopping_bag,
        ),
        PreviewCard(
          title: 'Ayarlar',
          subtitle: 'Bildirim, gizlilik, dil',
          icon: Icons.settings,
        ),
      ],
    );
  }
}
