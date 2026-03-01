import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class MyPhotosScreen extends StatefulWidget {
  final int accountId;

  const MyPhotosScreen({super.key, required this.accountId});

  @override
  State<MyPhotosScreen> createState() => _MyPhotosScreenState();
}

class _MyPhotosScreenState extends State<MyPhotosScreen> {
  List<_FavoritePhoto> _photos = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loaded = await _FavoriteStore.load(widget.accountId);
    if (!mounted) return;
    setState(() => _photos = loaded..sort((a, b) => b.createdAt.compareTo(a.createdAt)));
  }

  Future<void> _remove(String url) async {
    await _FavoriteStore.removeByUrl(widget.accountId, url);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('Fotoğraflarım'),
      ),
      body: SafeArea(
        top: false,
        child: _photos.isEmpty
            ? Center(
                child: Text(
                  'Henüz favori fotoğraf yok.',
                  style: TextStyle(color: Colors.white.withOpacity(0.8)),
                ),
              )
            : GridView.builder(
                padding: const EdgeInsets.all(10),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  childAspectRatio: 0.8,
                ),
                itemCount: _photos.length,
                itemBuilder: (context, i) {
                  final p = _photos[i];
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => _MyPhotoViewerScreen(
                                  photos: _photos,
                                  initialIndex: i,
                                  accountId: widget.accountId,
                                ),
                              ),
                            );
                            await _load();
                          },
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.network(
                              p.thumbUrl.isNotEmpty ? p.thumbUrl : p.url,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        top: 6,
                        right: 6,
                        child: InkWell(
                          onTap: () => _remove(p.url),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Icon(Icons.favorite, color: Colors.redAccent, size: 18),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}

class _MyPhotoViewerScreen extends StatefulWidget {
  final List<_FavoritePhoto> photos;
  final int initialIndex;
  final int accountId;

  const _MyPhotoViewerScreen({
    required this.photos,
    required this.initialIndex,
    required this.accountId,
  });

  @override
  State<_MyPhotoViewerScreen> createState() => _MyPhotoViewerScreenState();
}

class _MyPhotoViewerScreenState extends State<_MyPhotoViewerScreen> {
  late final PageController _controller;
  late int _index;
  List<_FavoritePhoto> _favorites = const [];

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _controller = PageController(initialPage: widget.initialIndex);
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final loaded = await _FavoriteStore.load(widget.accountId);
    if (!mounted) return;
    setState(() => _favorites = loaded);
  }

  bool _isFavorite(String url) => _favorites.any((f) => f.url == url);

  Future<void> _toggleFavorite(_FavoritePhoto photo) async {
    if (_isFavorite(photo.url)) {
      await _FavoriteStore.removeByUrl(widget.accountId, photo.url);
    } else {
      await _FavoriteStore.add(widget.accountId, photo);
    }
    await _loadFavorites();
  }

  Future<void> _download(String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('İndirme açılamadı')));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    final fav = _isFavorite(photo.url);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text('${_index + 1}/${widget.photos.length}'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: widget.photos.length,
                onPageChanged: (v) => setState(() => _index = v),
                itemBuilder: (context, i) {
                  final p = widget.photos[i];
                  return InteractiveViewer(
                    child: Center(
                      child: Image.network(
                        p.url,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              color: const Color(0xFF0B1020),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _toggleFavorite(photo),
                      icon: Icon(
                        fav ? Icons.favorite : Icons.favorite_border,
                        color: fav ? Colors.redAccent : Colors.white,
                      ),
                      label: Text(fav ? 'Beğenildi' : 'Beğen'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => Share.share(photo.url),
                      icon: const Icon(Icons.share),
                      label: const Text('Paylaş'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _download(photo.url),
                      icon: const Icon(Icons.download),
                      label: const Text('İndir'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoritePhoto {
  final String url;
  final String thumbUrl;
  final String albumSlug;
  final String albumName;
  final String createdAt;

  const _FavoritePhoto({
    required this.url,
    required this.thumbUrl,
    required this.albumSlug,
    required this.albumName,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'thumb_url': thumbUrl,
        'album_slug': albumSlug,
        'album_name': albumName,
        'created_at': createdAt,
      };

  factory _FavoritePhoto.fromJson(Map<String, dynamic> json) {
    return _FavoritePhoto(
      url: (json['url'] ?? '').toString(),
      thumbUrl: (json['thumb_url'] ?? '').toString(),
      albumSlug: (json['album_slug'] ?? '').toString(),
      albumName: (json['album_name'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class _FavoriteStore {
  static String _key(int accountId) => 'favorite_photos_v2_user_$accountId';

  static Future<List<_FavoritePhoto>> load(int accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(_key(accountId)) ?? const [];
    return rows
        .map((e) {
          try {
            return _FavoritePhoto.fromJson(jsonDecode(e) as Map<String, dynamic>);
          } catch (_) {
            return null;
          }
        })
        .whereType<_FavoritePhoto>()
        .toList();
  }

  static Future<void> add(int accountId, _FavoritePhoto photo) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await load(accountId);
    final exists = current.any((p) => p.url == photo.url);
    if (!exists) {
      current.add(photo);
    }
    final rows = current.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_key(accountId), rows);
  }

  static Future<void> removeByUrl(int accountId, String url) async {
    final prefs = await SharedPreferences.getInstance();
    final current = await load(accountId);
    current.removeWhere((p) => p.url == url);
    final rows = current.map((p) => jsonEncode(p.toJson())).toList();
    await prefs.setStringList(_key(accountId), rows);
  }
}
