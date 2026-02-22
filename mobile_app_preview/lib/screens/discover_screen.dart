import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'news_detail_screen.dart';
import 'screen_shell.dart';

class DiscoverScreen extends StatefulWidget {
  final String sessionToken;

  const DiscoverScreen({super.key, required this.sessionToken});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _discoverUrl =
      'https://api2.dansmagazin.net/discover?news_limit=50&events_limit=1&albums_limit=1';

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
      title: 'Haberler',
      icon: Icons.article,
      subtitle: 'Dansmagazin haberleri (en yeni en üstte).',
      content: [
        _SectionTitle(
          title: 'Tüm Haberler',
          trailing: TextButton(
            onPressed: () => setState(() => _future = _fetchDiscover()),
            child: const Text('Yenile'),
          ),
        ),
        FutureBuilder<_DiscoverData>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorCard(
                text: 'Haberler alınamadı. Lütfen tekrar deneyin.',
                onRetry: () => setState(() => _future = _fetchDiscover()),
              );
            }
            final data = snapshot.data ?? _DiscoverData.empty();
            return _NewsList(items: data.news, sessionToken: widget.sessionToken);
          },
        ),
      ],
    );
  }
}

class _DiscoverData {
  final List<_NewsItem> news;

  _DiscoverData({
    required this.news,
  });

  factory _DiscoverData.empty() => _DiscoverData(news: []);

  factory _DiscoverData.fromJson(Map<String, dynamic> json) {
    final rawNews = (json['news'] as List<dynamic>? ?? []);
    final news = rawNews
        .map((e) => _NewsItem.fromJson(e as Map<String, dynamic>))
        .where((e) => e.title.trim().isNotEmpty)
        .toList();
    news.sort((a, b) => b.date.compareTo(a.date));
    return _DiscoverData(
      news: news,
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

class _NewsList extends StatelessWidget {
  final List<_NewsItem> items;
  final String sessionToken;

  const _NewsList({required this.items, required this.sessionToken});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return const _InfoCard(text: 'Henüz haber bulunamadı.');
    }
    return Column(
      children: items
          .map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _NewsCard(
                item: item,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => NewsDetailScreen(
                        postId: item.id,
                        sessionToken: sessionToken,
                      ),
                    ),
                  );
                },
              ),
            ),
          )
          .toList(),
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
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: const Color(0xFF121826),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
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
                item.date,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.6), fontSize: 12),
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
