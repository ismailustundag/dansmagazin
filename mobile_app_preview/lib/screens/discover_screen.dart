import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'screen_shell.dart';

class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _discoverUrl =
      'https://api2.dansmagazin.net/discover?news_limit=20&events_limit=10&albums_limit=6';

  late Future<List<_NewsItem>> _newsFuture;

  @override
  void initState() {
    super.initState();
    _newsFuture = _fetchNews();
  }

  Future<List<_NewsItem>> _fetchNews() async {
    final resp = await http.get(Uri.parse(_discoverUrl));
    if (resp.statusCode != 200) {
      throw Exception('Discover endpoint hata: ${resp.statusCode}');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raw = (body['news'] as List<dynamic>? ?? []);
    return raw
        .map((e) => _NewsItem.fromJson(e as Map<String, dynamic>))
        .where((e) => e.title.trim().isNotEmpty)
        .toList();
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
            onPressed: () => setState(() => _newsFuture = _fetchNews()),
            child: const Text('Yenile'),
          ),
        ),
        FutureBuilder<List<_NewsItem>>(
          future: _newsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 190,
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorCard(
                text: 'Haberler alınamadı. Lütfen tekrar deneyin.',
                onRetry: () => setState(() => _newsFuture = _fetchNews()),
              );
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return const _InfoCard(text: 'Henüz haber bulunamadı.');
            }
            return SizedBox(
              height: 210,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, i) => _NewsCard(item: items[i]),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        const _SectionTitle(title: 'Yaklaşan Etkinlikler'),
        const _InfoCard(text: 'Bu bölüm bir sonraki adımda etkinlik verisiyle bağlanacak.'),
        const SizedBox(height: 16),
        const _SectionTitle(title: 'Son Yüklenen Albümler'),
        const _InfoCard(text: 'Bu bölüm bir sonraki adımda albüm verisiyle bağlanacak.'),
      ],
    );
  }
}

class _NewsItem {
  final int id;
  final String title;
  final String excerpt;
  final String image;
  final String link;

  _NewsItem({
    required this.id,
    required this.title,
    required this.excerpt,
    required this.image,
    required this.link,
  });

  factory _NewsItem.fromJson(Map<String, dynamic> json) {
    return _NewsItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      excerpt: (json['excerpt'] ?? '').toString(),
      image: (json['image'] ?? '').toString(),
      link: (json['link'] ?? '').toString(),
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

  const _NewsCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
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
