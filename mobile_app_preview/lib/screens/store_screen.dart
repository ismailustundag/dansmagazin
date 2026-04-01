import 'dart:async';

import 'package:flutter/material.dart';

import '../services/content_share_service.dart';
import '../services/i18n.dart';
import '../services/store_api.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';
import 'chat_thread_screen.dart';
import 'screen_shell.dart';

class StoreScreen extends StatefulWidget {
  final String sessionToken;
  final bool canAddToFeed;

  const StoreScreen({
    super.key,
    required this.sessionToken,
    required this.canAddToFeed,
  });

  @override
  State<StoreScreen> createState() => _StoreScreenState();
}

class _StoreScreenState extends State<StoreScreen> {
  late Future<List<StoreSellerItem>> _featuredFuture;
  late Future<List<StoreSellerItem>> _sellersFuture;

  @override
  void initState() {
    super.initState();
    _featuredFuture = StoreApi.featuredSellers();
    _sellersFuture = StoreApi.sellers();
  }

  Future<void> _refresh() async {
    setState(() {
      _featuredFuture = StoreApi.featuredSellers();
      _sellersFuture = StoreApi.sellers();
    });
    await Future.wait([_featuredFuture, _sellersFuture]);
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Mağaza',
      icon: Icons.storefront_rounded,
      subtitle: '',
      showHeader: false,
      tone: AppTone.profile,
      onRefresh: _refresh,
      content: [
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 10),
          child: Text(
            'Kostüm, ayakkabı ve aklına gelen daha fazlası. Onaylı kullanıcıların ürünlerine göz at, beğendiğin ürün için doğrudan iletişime geç.',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10.5,
              height: 1.35,
            ),
          ),
        ),
        FutureBuilder<List<StoreSellerItem>>(
          future: _featuredFuture,
          builder: (context, snapshot) {
            final items = snapshot.data ?? const <StoreSellerItem>[];
            if (items.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Öne Çıkan Mağazalar',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 15),
                  ),
                  const SizedBox(height: 10),
                  _FeaturedStoresCarousel(
                    items: items,
                    onTap: (seller) => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => SellerStoreScreen(
                            sessionToken: widget.sessionToken,
                            sellerAccountId: seller.accountId,
                            canAddToFeed: widget.canAddToFeed,
                          ),
                        ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
        Text(
          'Tüm Mağazalar',
          style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 15),
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<StoreSellerItem>>(
          future: _sellersFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.only(top: 48),
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
                          canAddToFeed: widget.canAddToFeed,
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
  final bool canAddToFeed;

  const SellerStoreScreen({
    super.key,
    required this.sessionToken,
    required this.sellerAccountId,
    required this.canAddToFeed,
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
                            canAddToFeed: widget.canAddToFeed,
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
  final bool canAddToFeed;

  const StoreProductDetailScreen({
    super.key,
    required this.sessionToken,
    required this.productId,
    required this.canAddToFeed,
  });

  @override
  State<StoreProductDetailScreen> createState() => _StoreProductDetailScreenState();
}

class _StoreProductDetailScreenState extends State<StoreProductDetailScreen> {
  late Future<StoreProductItem> _future;
  bool _sharingBusy = false;

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

  ContentSharePayload _sharePayload(StoreProductItem product) {
    final desc = product.description.trim();
    final trimmedDesc = desc.length > 180 ? '${desc.substring(0, 180).trim()}...' : desc;
    return ContentSharePayload(
      categoryLabel: 'Mağaza Ürünü',
      title: product.title.trim(),
      subtitle: '${product.formattedPrice} · ${product.seller.name}',
      description: trimmedDesc,
      imageUrl: product.imageUrl.trim(),
      feedText: '',
      shareUrl: 'https://www.dansmagazin.net/?route=/store/products/${product.id}',
      targetRoute: '/store/products/${product.id}',
      accentColor: AppTheme.cyan,
    );
  }

  Future<void> _shareProduct(StoreProductItem product) async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.shareAsImage(
        context,
        payload: _sharePayload(product),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('visual_share_failed'))),
      );
    } finally {
      if (mounted) setState(() => _sharingBusy = false);
    }
  }

  Future<void> _shareProductLink(StoreProductItem product) async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.shareLink(
        context,
        payload: _sharePayload(product),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('link_share_failed'))),
      );
    } finally {
      if (mounted) setState(() => _sharingBusy = false);
    }
  }

  Future<void> _addProductToFeed(StoreProductItem product) async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.addToFeed(
        sessionToken: widget.sessionToken,
        payload: _sharePayload(product),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('added_to_feed'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('feed_add_failed')} ${e.toString()}')),
      );
    } finally {
      if (mounted) setState(() => _sharingBusy = false);
    }
  }

  Future<void> _openShareActions(StoreProductItem product) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined, color: Colors.white),
              title: Text(I18n.t('share_as_visual')),
              onTap: () => Navigator.of(context).pop('share'),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, color: Colors.white),
              title: Text(I18n.t('share_as_link')),
              onTap: () => Navigator.of(context).pop('link'),
            ),
            if (widget.canAddToFeed)
              ListTile(
                leading: const Icon(Icons.dynamic_feed_rounded, color: Colors.white),
                title: Text(I18n.t('add_to_feed')),
                onTap: () => Navigator.of(context).pop('feed'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'link') {
      await _shareProductLink(product);
      return;
    }
    if (action == 'feed') {
      await _addProductToFeed(product);
      return;
    }
    await _shareProduct(product);
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
                decoration: AppTheme.panel(tone: AppTone.profile, radius: 20, elevated: true),
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
                          EmojiText(
                            product.seller.name,
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
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _sharingBusy ? null : () => _openShareActions(product),
                      icon: _sharingBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.ios_share_rounded),
                      label: Text(I18n.t('share')),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        foregroundColor: Colors.white,
                        side: BorderSide(color: AppTheme.borderStrong.withOpacity(0.8)),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
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
                  ),
                ],
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
    final imageUrl = seller.storeLogoUrl.trim().isNotEmpty
        ? seller.storeLogoUrl.trim()
        : seller.coverImageUrl.trim();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: AppTheme.panel(tone: AppTone.profile, radius: 20, elevated: true),
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  width: 82,
                  height: 82,
                  child: imageUrl.isNotEmpty
                      ? Image.network(imageUrl, fit: BoxFit.cover)
                      : Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF14203A), Color(0xFF0C1426)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.storefront_rounded, size: 34, color: Colors.white54),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    EmojiText(
                      seller.storeTitle,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right_rounded, color: AppTheme.textTertiary),
            ],
          ),
        ),
      ),
    );
  }
}

class _FeaturedStoresCarousel extends StatefulWidget {
  final List<StoreSellerItem> items;
  final ValueChanged<StoreSellerItem> onTap;

  const _FeaturedStoresCarousel({
    required this.items,
    required this.onTap,
  });

  @override
  State<_FeaturedStoresCarousel> createState() => _FeaturedStoresCarouselState();
}

class _FeaturedStoresCarouselState extends State<_FeaturedStoresCarousel> {
  late final PageController _controller;
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 1);
    _restartTimer();
  }

  @override
  void didUpdateWidget(covariant _FeaturedStoresCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      _index = 0;
      _restartTimer();
    }
  }

  void _restartTimer() {
    _timer?.cancel();
    if (widget.items.length < 2) return;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_controller.hasClients) return;
      final next = (_index + 1) % widget.items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 178,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (value) => setState(() => _index = value),
            itemBuilder: (context, index) {
              final seller = widget.items[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: _FeaturedStoreBanner(
                  seller: seller,
                  onTap: () => widget.onTap(seller),
                ),
              );
            },
          ),
        ),
        if (widget.items.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < widget.items.length; i++)
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _index ? 20 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _index ? AppTheme.cyan : Colors.white24,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class _FeaturedStoreBanner extends StatelessWidget {
  final StoreSellerItem seller;
  final VoidCallback onTap;

  const _FeaturedStoreBanner({
    required this.seller,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final imageUrl = seller.storeLogoUrl.trim().isNotEmpty
        ? seller.storeLogoUrl.trim()
        : seller.coverImageUrl.trim();
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Ink(
          height: 176,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              colors: [Color(0xFF16253F), Color(0xFF0A1222)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (imageUrl.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Image.network(imageUrl, fit: BoxFit.cover),
                ),
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withOpacity(0.12),
                      Colors.black.withOpacity(0.72),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.34),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        'Öne Çıkan',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            seller.storeTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              height: 1.15,
                            ),
                          ),
                        ),
                        const Icon(Icons.chevron_right_rounded, color: Colors.white70),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
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
    final heroImage = seller.storeLogoUrl.trim().isNotEmpty
        ? seller.storeLogoUrl.trim()
        : seller.avatarUrl;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.profile, radius: 24, elevated: true),
      child: Row(
        children: [
          VerifiedAvatar(
            imageUrl: heroImage,
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
