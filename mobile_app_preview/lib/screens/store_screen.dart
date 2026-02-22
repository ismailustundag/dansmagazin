import 'package:flutter/material.dart';

import 'screen_shell.dart';

class StoreScreen extends StatelessWidget {
  const StoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ScreenShell(
      title: 'Mağaza',
      icon: Icons.storefront,
      subtitle: 'Çok yakında: ürünler, kampanyalar ve satın alma akışları.',
      content: [
        PreviewCard(
          title: 'Mağaza hazırlanıyor',
          subtitle: 'Bu alan bir sonraki sprintte açılacak.',
          icon: Icons.shopping_bag_outlined,
        ),
      ],
    );
  }
}
