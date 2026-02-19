import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NewsDetailScreen extends StatefulWidget {
  final int postId;

  const NewsDetailScreen({super.key, required this.postId});

  @override
  State<NewsDetailScreen> createState() => _NewsDetailScreenState();
}

class _NewsDetailScreenState extends State<NewsDetailScreen> {
  static const _kLikeCountPrefix = 'news_like_count_';
  static const _kLikedPrefix = 'news_liked_';

  late Future<_NewsDetail> _future;
  int _likeCount = 0;
  bool _liked = false;

  @override
  void initState() {
    super.initState();
    _future = _fetchDetail();
    _loadLikeState();
  }

  Future<void> _loadLikeState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _likeCount = prefs.getInt('$_kLikeCountPrefix${widget.postId}') ?? 0;
      _liked = prefs.getBool('$_kLikedPrefix${widget.postId}') ?? false;
    });
  }

  Future<void> _toggleLike() async {
    final nextLiked = !_liked;
    final nextCount = nextLiked
        ? _likeCount + 1
        : (_likeCount > 0 ? _likeCount - 1 : 0);
    setState(() {
      _liked = nextLiked;
      _likeCount = nextCount;
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('$_kLikedPrefix${widget.postId}', nextLiked);
    await prefs.setInt('$_kLikeCountPrefix${widget.postId}', nextCount);
  }

  Future<_NewsDetail> _fetchDetail() async {
    final url = 'https://api2.dansmagazin.net/discover/news/${widget.postId}';
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Haber detayı alınamadı (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return _NewsDetail.fromJson(body);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('Haber'),
      ),
      body: FutureBuilder<_NewsDetail>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Haber yüklenemedi'),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _future = _fetchDetail()),
                    child: const Text('Tekrar Dene'),
                  ),
                ],
              ),
            );
          }
          final item = snapshot.data!;
          final normalizedHtml = _normalizeWpHtml(item.contentHtml);
          return ListView(
            padding: const EdgeInsets.all(12),
            children: [
              if (item.image.isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: Image.network(
                    item.image,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              const SizedBox(height: 12),
              Text(
                item.title,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                item.date,
                style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 13),
              ),
              const SizedBox(height: 12),
              Html(data: normalizedHtml),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _toggleLike,
                      icon: Icon(
                        _liked ? Icons.favorite : Icons.favorite_border,
                        color: _liked ? Colors.redAccent : null,
                      ),
                      label: Text('Beğen ($_likeCount)'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final shareText = item.link.isNotEmpty
                            ? '${item.title}\n${item.link}'
                            : item.title;
                        Share.share(shareText, subject: item.title);
                      },
                      icon: const Icon(Icons.share),
                      label: const Text('Paylaş'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Paylaş seçeneğinde WhatsApp / Instagram / Facebook gibi uygulamalar listelenir.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.55),
                  fontSize: 12,
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _normalizeWpHtml(String html) {
    var out = html;

    // Resimleri ekran genişliğine zorla, taşmayı engelle.
    out = out.replaceAllMapped(RegExp(r'<img([^>]*)>', caseSensitive: false), (m) {
      final attrs = m.group(1) ?? '';
      final clean = attrs
          .replaceAll(RegExp(r'\swidth="[^"]*"', caseSensitive: false), '')
          .replaceAll(RegExp(r'\sheight="[^"]*"', caseSensitive: false), '');
      return '<img$clean style="max-width:100%;height:auto;display:block;border-radius:10px;" />';
    });

    // iframe videoları da taşmasın.
    out = out.replaceAllMapped(RegExp(r'<iframe([^>]*)>', caseSensitive: false), (m) {
      final attrs = m.group(1) ?? '';
      final clean = attrs
          .replaceAll(RegExp(r'\swidth="[^"]*"', caseSensitive: false), '')
          .replaceAll(RegExp(r'\sheight="[^"]*"', caseSensitive: false), '');
      return '<iframe$clean style="width:100%;max-width:100%;aspect-ratio:16/9;border:0;border-radius:10px;"></iframe>';
    });

    // Çok uzun satırların taşmasını engelle.
    return '<div style="word-break:break-word;overflow-wrap:anywhere;">$out</div>';
  }
}

class _NewsDetail {
  final String title;
  final String date;
  final String image;
  final String link;
  final String contentHtml;

  _NewsDetail({
    required this.title,
    required this.date,
    required this.image,
    required this.link,
    required this.contentHtml,
  });

  factory _NewsDetail.fromJson(Map<String, dynamic> json) {
    return _NewsDetail(
      title: (json['title'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      image: (json['image'] ?? '').toString(),
      link: (json['link'] ?? '').toString(),
      contentHtml: (json['content_html'] ?? '').toString(),
    );
  }
}
