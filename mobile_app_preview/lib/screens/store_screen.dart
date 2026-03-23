import 'package:flutter/material.dart';

import '../services/store_api.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';
import 'chat_thread_screen.dart';
import 'screen_shell.dart';

class StoreScreen extends StatefulWidget {
  final String sessionToken;

  const StoreScreen({super.key, required this.sessionToken});

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  late Future<List<StoreSellerItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = StoreApi.sellers();
  }

  Future<void> _refresh() async {
    setState(() => _future = StoreApi.sellers());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Mağaza',
      icon: Icons.storefront_rounded,
      subtitle: 'Onaylı kullanıcıların mağazalarını keşfet.',
      tone: AppTone.info,
      onRefresh: _refresh,
      content: [
        FutureBuilder<List<StoreSellerItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.only(top: 60),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _StoreFeedbackCard(
                icon: Icons.wifi_tethering_error_rounded,
                title: 'Mağazalar yüklenemedi',
                subtitle: snapshot.error.toString(),
              );
            }
            final items = snapshot.data ?? const [];
            if (items.isEmpty) {
              return const _StoreFeedbackCard(
                icon: Icons.store_mall_directory_outlined,
                title: 'Henüz mağaza yok',
                subtitle: 'İlk ürünler eklendiğinde mağazalar burada görünecek.',
              );
            }
            return Column(
              children: [
                for (final seller in items)
                  _SellerStoreCard(
                    seller: seller,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SellerStoreScreen(
                          sessionToken: widget.sessionToken,
                          sellerAccountId: seller.accountId,
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class SellerStoreScreen extends StatefulWidget {
  final String sessionToken;
  final int sellerAccountId;

  const SellerStoreScreen({
    super.key,
    required this.sessionToken,
    required this.sellerAccountId,
  });

  @override
  State<SellerStoreScreen> createState() => _SellerStoreScreenState();
}

class _SellerStoreScreenState extends State<SellerStoreScreen> {
  late Future<SellerStoreDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = StoreApi.sellerStore(widget.sellerAccountId);
  }

  Future<void> _refresh() async {
    setState(() => _future = StoreApi.sellerStore(widget.sellerAccountId));
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        title: const Text('Mağaza'),
        backgroundColor: const Color(0xFF0F172A),
      ),
      body: FutureBuilder<SellerStoreDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  snapshot.error.toString(),
                  style: const TextStyle(color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(
              child: Text('Mağaza bulunamadı', style: TextStyle(color: AppTheme.textSecondary)),
            );
          }
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              children: [
                _SellerHeroCard(seller: data.seller),
                const SizedBox(height: 16),
                const Text(
                  'Ürünler',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                if (data.products.isEmpty)
                  const _StoreFeedbackCard(
                    icon: Icons.shopping_bag_outlined,
                    title: 'Henüz ürün eklenmemiş',
                    subtitle: 'Bu mağazada aktif ürün bulunmuyor.',
                  )
                else
                  for (final product in data.products)
                    _StoreProductCard(
                      product: product,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => StoreProductDetailScreen(
                            sessionToken: widget.sessionToken,
                            productId: product.id,
                          ),
                        ),
                      ),
                    ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class StoreProductDetailScreen extends StatefulWidget {
  final String sessionToken;
  final int productId;

  const StoreProductDetailScreen({
    super.key,
    required this.sessionToken,
    required this.productId,
  });

  @override
  State<StoreProductDetailScreen> createState() => _StoreProductDetailScreenState();
}

class _StoreProductDetailScreenState extends State<StoreProductDetailScreen> {
  late Future<StoreProductItem> _future;

  @override
  void initState() {
    super.initState();
    _future = StoreApi.product(widget.productId);
  }

  Future<void> _openChat(StoreProductItem product) async {
    if (widget.sessionToken.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mesajlaşmak için giriş yapmalısın.')),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          sessionToken: widget.sessionToken,
          peerAccountId: product.seller.accountId,
          peerName: product.seller.name,
          peerAvatarUrl: product.seller.avatarUrl,
          peerIsVerified: product.seller.isVerified,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        title: const Text('Ürün Detayı'),
        backgroundColor: const Color(0xFF0F172A),
      ),
      body: FutureBuilder<StoreProductItem>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  snapshot.error.toString(),
                  style: const TextStyle(color: AppTheme.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          final product = snapshot.data;
          if (product == null) {
            return const Center(
              child: Text('Ürün bulunamadı', style: TextStyle(color: AppTheme.textSecondary)),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: product.imageUrl.trim().isNotEmpty
                      ? Image.network(product.imageUrl.trim(), fit: BoxFit.cover)
                      : Container(
                          color: const Color(0xFF13203A),
                          alignment: Alignment.center,
                          child: const Icon(Icons.shopping_bag_outlined, size: 52, color: Colors.white54),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              VerifiedNameText(
                product.title,
                isVerified: false,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                product.formattedPrice,
                style: const TextStyle(
                  color: AppTheme.cyan,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: AppTheme.panel(tone: AppTone.info, radius: 20, elevated: true),
                child: Row(
                  children: [
                    VerifiedAvatar(
                      imageUrl: product.seller.avatarUrl,
                      label: product.seller.name,
                      isVerified: product.seller.isVerified,
                      radius: 22,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          VerifiedNameText(
                            product.seller.name,
                            isVerified: product.seller.isVerified,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            'Satıcı',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: AppTheme.panel(tone: AppTone.neutral, radius: 22, elevated: true),
                child: EmojiText(
                  product.description,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              ElevatedButton.icon(
                onPressed: () => _openChat(product),
                icon: const Icon(Icons.chat_bubble_outline_rounded),
                label: const Text('İletişime Geç'),
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(54),
                  backgroundColor: AppTheme.cyan,
                  foregroundColor: const Color(0xFF06111F),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                  textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SellerStoreCard extends StatelessWidget {
  final StoreSellerItem seller;
  final VoidCallback onTap;

  const _SellerStoreCard({required this.seller, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: AppTheme.panel(tone: AppTone.info, radius: 24, elevated: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: AspectRatio(
                aspectRatio: 2.2,
                child: seller.coverImageUrl.trim().isNotEmpty
                    ? Image.network(seller.coverImageUrl.trim(), fit: BoxFit.cover)
                    : Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [Color(0xFF14203A), Color(0xFF0C1426)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Icon(Icons.storefront_rounded, size: 42, color: Colors.white54),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  VerifiedAvatar(
                    imageUrl: seller.avatarUrl,
                    label: seller.name,
                    isVerified: seller.isVerified,
                    radius: 24,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        VerifiedNameText(
                          seller.storeTitle,
                          isVerified: false,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${seller.productCount} ürün',
                          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded, color: AppTheme.textTertiary),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SellerHeroCard extends StatelessWidget {
  final StoreSellerItem seller;

  const _SellerHeroCard({required this.seller});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.info, radius: 24, elevated: true),
      child: Row(
        children: [
          VerifiedAvatar(
            imageUrl: seller.avatarUrl,
            label: seller.name,
            isVerified: seller.isVerified,
            radius: 30,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VerifiedNameText(
                  seller.storeTitle,
                  isVerified: false,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${seller.productCount} aktif ürün',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StoreProductCard extends StatelessWidget {
  final StoreProductItem product;
  final VoidCallback onTap;

  const _StoreProductCard({required this.product, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: AppTheme.panel(tone: AppTone.neutral, radius: 22, elevated: true),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                width: 84,
                height: 84,
                child: product.imageUrl.trim().isNotEmpty
                    ? Image.network(product.imageUrl.trim(), fit: BoxFit.cover)
                    : Container(
                        color: const Color(0xFF112038),
                        alignment: Alignment.center,
                        child: const Icon(Icons.shopping_bag_outlined, color: Colors.white38),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  EmojiText(
                    product.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    product.formattedPrice,
                    style: const TextStyle(
                      color: AppTheme.cyan,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    product.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12, height: 1.35),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right_rounded, color: AppTheme.textTertiary),
          ],
        ),
      ),
    );
  }
}

class _StoreFeedbackCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;

  const _StoreFeedbackCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: AppTheme.panel(tone: AppTone.neutral, radius: 22, elevated: true),
      child: Column(
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 34),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.4),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
