import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';

import '../services/i18n.dart';

Uri _encodedUri(String rawUrl) => Uri.parse(Uri.encodeFull(rawUrl.trim()));

Future<List<int>> _downloadImageBytes(String url) async {
  final resp = await http.get(
    _encodedUri(url),
    headers: const {
      'Accept': 'image/*,*/*;q=0.8',
      'User-Agent': 'DansmagazinApp/1.0',
    },
  );
  if (resp.statusCode >= 200 && resp.statusCode < 300 && resp.bodyBytes.isNotEmpty) {
    return resp.bodyBytes;
  }
  throw HttpException('image_download_failed_${resp.statusCode}');
}

String _galleryNameFromUrl(String url) {
  final lower = url.toLowerCase();
  final ext = lower.contains('.png')
      ? 'png'
      : lower.contains('.webp')
          ? 'webp'
          : 'jpg';
  return 'dansmagazin_${DateTime.now().millisecondsSinceEpoch}.$ext';
}

Future<bool> _saveToGallery(String url, List<int> bytes) async {
  final name = _galleryNameFromUrl(url);
  final result = await ImageGallerySaver.saveImage(
    bytes,
    quality: 100,
    name: name,
  );
  if (result is Map) {
    final success = result['isSuccess'] == true ||
        result['success'] == true ||
        result['filePath'] != null;
    return success;
  }
  return result != null;
}

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
    final t = I18n.t;
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(t('my_photos')),
      ),
      body: SafeArea(
        top: false,
        child: _photos.isEmpty
            ? Center(
                child: Text(
                  t('no_favorite_photo'),
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
                            child: const Icon(Icons.star, color: Colors.amber, size: 18),
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
    try {
      final bytes = await _downloadImageBytes(url);
      final saved = await _saveToGallery(url, bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(saved ? 'Fotoğraf albüme kaydedildi' : I18n.t('cannot_open_download')),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('cannot_open_download')} (${e.runtimeType})')),
      );
    }
  }

  Future<void> _share(String text) async {
    final payload = text.trim();
    if (payload.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paylaşılacak içerik bulunamadı')),
      );
      return;
    }
    try {
      await Share.share(payload, subject: 'Dansmagazin Fotoğraf');
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paylaşım açılamadı')),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
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
                        fav ? Icons.star : Icons.star_border,
                        color: fav ? Colors.amber : Colors.white,
                      ),
                      label: Text(fav ? t('saved') : t('favorite')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _share(photo.url),
                      icon: const Icon(Icons.share),
                      label: Text(t('share')),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _download(photo.url),
                      icon: const Icon(Icons.download),
                      label: Text(t('download')),
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
