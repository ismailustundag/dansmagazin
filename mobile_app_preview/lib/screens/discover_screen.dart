import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_webview_screen.dart';
import 'news_detail_screen.dart';
import 'screen_shell.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _discoverUrl =
      'https://api2.dansmagazin.net/discover?news_limit=20&events_limit=12&albums_limit=6';

  late Future<_DiscoverData> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchDiscover();
  }

  Future<_DiscoverData> _fetchDiscover() async {
    final resp = await http.get(Uri.parse(_discoverUrl));
    if (resp.statusCode != 200) {
      throw Exception('Discover endpoint hata: ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return _DiscoverData.fromJson(body);
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Keşfet',
      icon: Icons.explore,
      subtitle: 'Öne çıkan içerikler, yaklaşan etkinlikler ve yeni albümler.',
      content: [
        _SectionTitle(
          title: 'Bu Hafta Öne Çıkan',
          trailing: TextButton(
            onPressed: () => setState(() => _future = _fetchDiscover()),
            child: const Text('Yenile'),
          ),
        ),
        FutureBuilder<_DiscoverData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 190,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorCard(
                text: 'Keşfet verisi alınamadı. Lütfen tekrar deneyin.',
                onRetry: () => setState(() => _future = _fetchDiscover()),
              );
            }
            final data = snapshot.data ?? _DiscoverData.empty();
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _NewsCarousel(items: data.news),
                const SizedBox(height: 16),
                const _SectionTitle(title: 'Yaklaşan Etkinlikler'),
                _SimpleCarousel(
                  items: data.events,
                  emptyText: 'Etkinlik bulunamadı.',
                  onTap: (item) {
                    if (item.id > 0) {
                      if (!mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => NewsDetailScreen(postId: item.id),
                        ),
                      );
                      return;
                    }
                    if (item.link.isNotEmpty) {
                      if (!mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AppWebViewScreen(
                            url: item.link,
                            title: item.name,
                          ),
                        ),
                      );
                    }
                  },
                ),
                const SizedBox(height: 16),
                const _SectionTitle(title: 'Son Yüklenen Albümler'),
                _SimpleCarousel(
                  items: data.albums,
                  emptyText: 'Albüm bulunamadı.',
                  onTap: (item) {
                    if (item.link.isNotEmpty) {
                      if (!mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => AppWebViewScreen(
                            url: item.link,
                            title: item.name,
                          ),
                        ),
                      );
                    }
                  },
                  subtitleBuilder: (item) {
                    final cnt = item.photoCount;
                    if (cnt > 0) return '$cnt fotoğraf';
                    return item.date;
                  },
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _DiscoverData {
  final List<_NewsItem> news;
  final List<_CardItem> events;
  final List<_CardItem> albums;

  _DiscoverData({
    required this.news,
    required this.events,
    required this.albums,
  });

  factory _DiscoverData.empty() => _DiscoverData(news: [], events: [], albums: []);

  factory _DiscoverData.fromJson(Map<String, dynamic> json) {
    final rawNews = (json['news'] as List<dynamic>? ?? []);
    final rawEvents = (json['upcoming_events'] as List<dynamic>? ?? []);
    final rawAlbums = (json['latest_albums'] as List<dynamic>? ?? []);
    return _DiscoverData(
      news: rawNews
          .map((e) => _NewsItem.fromJson(e as Map<String, dynamic>))
          .where((e) => e.title.trim().isNotEmpty)
          .toList(),
      events: rawEvents.map((e) => _CardItem.fromJson(e as Map<String, dynamic>)).toList(),
      albums: rawAlbums.map((e) => _CardItem.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class _NewsItem {
  final int id;
  final String title;
  final String excerpt;
  final String image;
  final String link;
  final String date;

  _NewsItem({
    required this.id,
    required this.title,
    required this.excerpt,
    required this.image,
    required this.link,
    required this.date,
  });

  factory _NewsItem.fromJson(Map<String, dynamic> json) {
    return _NewsItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      excerpt: (json['excerpt'] ?? '').toString(),
      image: (json['image'] ?? '').toString(),
      link: (json['link'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
    );
  }
}

class _CardItem {
  final int id;
  final String name;
  final String cover;
  final String date;
  final String link;
  final int photoCount;

  _CardItem({
    required this.id,
    required this.name,
    required this.cover,
    required this.date,
    required this.link,
    required this.photoCount,
  });

  factory _CardItem.fromJson(Map<String, dynamic> json) {
    return _CardItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? json['title'] ?? '').toString(),
      cover: (json['cover'] ?? json['image'] ?? '').toString(),
      date: (json['date'] ?? json['created_at'] ?? '').toString(),
      link: (json['link'] ?? '').toString(),
      photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class _NewsCarousel extends StatelessWidget {
  final List<_NewsItem> items;

  const _NewsCarousel({required this.items});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _InfoCard(text: 'Henüz haber bulunamadı.');
    }
    return SizedBox(
      height: 220,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) {
          final item = items[i];
          return _NewsCard(
            item: item,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => NewsDetailScreen(postId: item.id),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _SimpleCarousel extends StatelessWidget {
  final List<_CardItem> items;
  final String emptyText;
  final void Function(_CardItem item)? onTap;
  final String Function(_CardItem item)? subtitleBuilder;

  const _SimpleCarousel({
    required this.items,
    required this.emptyText,
    this.onTap,
    this.subtitleBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return _InfoCard(text: emptyText);
    }
    return SizedBox(
      height: 185,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (context, i) => _SmallCard(
          item: items[i],
          subtitle: subtitleBuilder != null ? subtitleBuilder!(items[i]) : items[i].date,
          onTap: onTap == null
              ? null
              : () {
                  onTap!(items[i]);
                },
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final Widget? trailing;

  const _SectionTitle({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _NewsCard extends StatelessWidget {
  final _NewsItem item;
  final VoidCallback onTap;

  const _NewsCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 300,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF121826),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 130,
              width: double.infinity,
              child: item.image.isNotEmpty
                  ? Image.network(
                      item.image,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _imageFallback(),
                    )
                  : _imageFallback(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                item.excerpt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _imageFallback() {
    return Container(
      color: const Color(0xFF1F2937),
      child: const Center(
        child: Icon(Icons.image_not_supported_outlined, color: Colors.white54),
      ),
    );
  }
}

class _SmallCard extends StatelessWidget {
  final _CardItem item;
  final String subtitle;
  final VoidCallback? onTap;

  const _SmallCard({required this.item, required this.subtitle, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 230,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: const Color(0xFF121826),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: item.cover.isNotEmpty
                  ? Image.network(
                      item.cover,
                      width: double.infinity,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                    )
                  : Container(color: const Color(0xFF1F2937)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Colors.white.withOpacity(0.65)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String text;

  const _InfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(text, style: TextStyle(color: Colors.white.withOpacity(0.8))),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String text;
  final VoidCallback onRetry;

  const _ErrorCard({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1212),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF7F1D1D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(text),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
        ],
      ),
    );
  }
}
