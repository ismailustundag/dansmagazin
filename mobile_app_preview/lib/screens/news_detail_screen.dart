import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:http/http.dart' as http;

import '../services/content_share_service.dart';
import '../services/i18n.dart';

class NewsDetailScreen extends StatefulWidget {
  final int postId;
  final String sessionToken;
  final bool canAddToFeed;

  const NewsDetailScreen({
    super.key,
    required this.postId,
    required this.sessionToken,
    required this.canAddToFeed,
  });

  @override
  State<NewsDetailScreen> createState() => _NewsDetailScreenState();
}

class _NewsDetailScreenState extends State<NewsDetailScreen> {
  late Future<_NewsDetail> _future;
  int _likeCount = 0;
  bool _liked = false;
  bool _sharingBusy = false;

  @override
  void initState() {
    super.initState();
    _future = _fetchDetail();
    _loadLikeState();
  }

  Map<String, String> _authHeaders() {
    final t = widget.sessionToken.trim();
    if (t.isEmpty) return const {};
    return {'Authorization': 'Bearer $t'};
  }

  Future<void> _loadLikeState() async {
    final r = await http.get(
      Uri.parse('https://api2.dansmagazin.net/discover/news/${widget.postId}/reactions'),
      headers: _authHeaders(),
    );
    if (!mounted) return;
    if (r.statusCode == 200) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      setState(() {
        _likeCount = (body['like_count'] as num?)?.toInt() ?? 0;
        _liked = (body['liked_by_me'] == true);
      });
    }
  }

  Future<void> _toggleLike() async {
    final nextLiked = !_liked;
    final endpoint = nextLiked ? 'like' : 'unlike';
    final r = await http.post(
      Uri.parse('https://api2.dansmagazin.net/discover/news/${widget.postId}/$endpoint'),
      headers: _authHeaders(),
    );
    if (!mounted) return;
    if (r.statusCode == 200) {
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      setState(() {
        _liked = (body['liked_by_me'] == true);
        _likeCount = (body['like_count'] as num?)?.toInt() ?? _likeCount;
      });
      return;
    }
    // başarısızsa mevcut durumu tekrar çek
    await _loadLikeState();
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

  ContentSharePayload _sharePayload(_NewsDetail item) {
    return ContentSharePayload(
      categoryLabel: 'Haber',
      title: item.title.trim(),
      subtitle: item.date.trim(),
      description: _plainSummary(item.contentHtml),
      imageUrl: item.image.trim(),
      feedText: '',
      accentColor: const Color(0xFFF97316),
    );
  }

  String _plainSummary(String html) {
    final noTags = html.replaceAll(RegExp(r'<[^>]+>'), ' ');
    final cleaned = noTags.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 180) return cleaned;
    return '${cleaned.substring(0, 180).trim()}...';
  }

  Future<void> _shareNews(_NewsDetail item) async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.shareAsImage(
        context,
        payload: _sharePayload(item),
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

  Future<void> _addNewsToFeed(_NewsDetail item) async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.addToFeed(
        sessionToken: widget.sessionToken,
        payload: _sharePayload(item),
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

  Future<void> _openShareActions(_NewsDetail item) async {
    if (!widget.canAddToFeed) {
      await _shareNews(item);
      return;
    }
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
              leading: const Icon(Icons.dynamic_feed_rounded, color: Colors.white),
              title: Text(I18n.t('add_to_feed')),
              onTap: () => Navigator.of(context).pop('feed'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'feed') {
      await _addNewsToFeed(item);
      return;
    }
    await _shareNews(item);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('Haber'),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<_NewsDetail>(
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
                      onPressed: _sharingBusy ? null : () => _openShareActions(item),
                      icon: _sharingBusy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.share),
                      label: Text(I18n.t('share')),
                    ),
                  ),
                ],
              ),
            ],
          );
          },
        ),
      ),
    );
  }

  String _normalizeWpHtml(String html) {
    var out = html;

    out = out.replaceAllMapped(RegExp(r'<img([^>]*)>', caseSensitive: false), (m) {
      final attrs = m.group(1) ?? '';
      final clean = attrs
          .replaceAll(RegExp(r'\swidth="[^"]*"', caseSensitive: false), '')
          .replaceAll(RegExp(r'\sheight="[^"]*"', caseSensitive: false), '');
      return '<img$clean style="max-width:100%;height:auto;display:block;border-radius:10px;" />';
    });

    out = out.replaceAllMapped(RegExp(r'<iframe([^>]*)>', caseSensitive: false), (m) {
      final attrs = m.group(1) ?? '';
      final clean = attrs
          .replaceAll(RegExp(r'\swidth="[^"]*"', caseSensitive: false), '')
          .replaceAll(RegExp(r'\sheight="[^"]*"', caseSensitive: false), '');
      return '<iframe$clean style="width:100%;max-width:100%;aspect-ratio:16/9;border:0;border-radius:10px;"></iframe>';
    });

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
