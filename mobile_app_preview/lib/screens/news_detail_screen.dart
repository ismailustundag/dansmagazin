import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

class NewsDetailScreen extends StatefulWidget {
  final int postId;

  const NewsDetailScreen({super.key, required this.postId});

  @override
  State<NewsDetailScreen> createState() => _NewsDetailScreenState();
}

class _NewsDetailScreenState extends State<NewsDetailScreen> {
  late Future<_NewsDetail> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchDetail();
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
              Html(data: item.contentHtml),
              const SizedBox(height: 12),
              if (item.link.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: () => _open(item.link),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Dansmagazin.net üzerinde aç'),
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
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
