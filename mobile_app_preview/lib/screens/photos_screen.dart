import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screen_shell.dart';

class PhotosScreen extends StatefulWidget {
  final int accountId;

  const PhotosScreen({super.key, required this.accountId});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  static const String _albumsUrl = 'https://api2.dansmagazin.net/photos';

  late Future<List<_Album>> _albumsFuture;
  int _tab = 0; // 0: Tum albumler, 1: Son yuklenenler, 2: Favoriler
  List<_FavoritePhoto> _favorites = [];

  @override
  void initState() {
    super.initState();
    _albumsFuture = _fetchAlbums();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final loaded = await _FavoriteStore.load(widget.accountId);
    if (!mounted) return;
    setState(() => _favorites = loaded);
  }

  Future<List<_Album>> _fetchAlbums() async {
    final resp = await http.get(Uri.parse(_albumsUrl));
    if (resp.statusCode != 200) {
      throw Exception('Album endpoint hata: ${resp.statusCode}');
    }

    final dynamic raw = jsonDecode(resp.body);
    List<dynamic> rows;
    if (raw is List) {
      rows = raw;
    } else if (raw is Map<String, dynamic>) {
      rows = (raw['albums'] as List<dynamic>?) ??
          (raw['items'] as List<dynamic>?) ??
          (raw['results'] as List<dynamic>?) ??
          <dynamic>[];
    } else {
      rows = <dynamic>[];
    }

    final albums = rows
        .whereType<Map<String, dynamic>>()
        .map(_Album.fromJson)
        .where((a) => a.slug.isNotEmpty)
        .toList();

    albums.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return albums;
  }

  Future<void> _refresh() async {
    setState(() {
      _albumsFuture = _fetchAlbums();
    });
    await _albumsFuture;
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Fotoğraflar',
      icon: Icons.photo_library,
      subtitle: 'Albüm bazlı liste. En yeni albümler üstte gösterilir.',
      content: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tabChip(0, 'Tüm Albümler'),
            _tabChip(1, 'Son Yüklenenler'),
            _tabChip(2, 'Favoriler'),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<_Album>>(
          future: _albumsFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorCard(
                text: 'Fotoğraf albümleri yüklenemedi.',
                onRetry: _refresh,
              );
            }

            final albums = snapshot.data ?? const <_Album>[];
            if (_tab == 2) {
              return _FavoriteGrid(
                photos: _favorites,
                accountId: widget.accountId,
                onUnfavorite: (url) async {
                  await _FavoriteStore.removeByUrl(widget.accountId, url);
                  await _loadFavorites();
                },
              );
            }

            final list = _tab == 1 ? albums.take(20).toList() : albums;
            if (list.isEmpty) {
              return const _InfoCard(text: 'Albüm bulunamadı.');
            }

            return Column(
              children: list
                  .map(
                    (album) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _AlbumCard(
                        album: album,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => AlbumPhotosScreen(album: album, accountId: widget.accountId),
                            ),
                          );
                          await _loadFavorites();
                        },
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _tabChip(int value, String label) {
    final selected = _tab == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _tab = value),
      selectedColor: const Color(0xFFE53935),
      backgroundColor: const Color(0xFF121826),
      labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
      side: BorderSide(color: selected ? Colors.transparent : Colors.white24),
    );
  }
}

class AlbumPhotosScreen extends StatefulWidget {
  final _Album album;
  final int accountId;

  const AlbumPhotosScreen({super.key, required this.album, required this.accountId});

  @override
  State<AlbumPhotosScreen> createState() => _AlbumPhotosScreenState();
}

class _AlbumPhotosScreenState extends State<AlbumPhotosScreen> {
  late Future<List<_Photo>> _photosFuture;
  List<_FavoritePhoto> _favorites = [];

  @override
  void initState() {
    super.initState();
    _photosFuture = _fetchPhotos();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final loaded = await _FavoriteStore.load(widget.accountId);
    if (!mounted) return;
    setState(() => _favorites = loaded);
  }

  bool _isFavorite(String url) {
    return _favorites.any((f) => f.url == url);
  }

  Future<List<_Photo>> _fetchPhotos() async {
    final url = 'https://api2.dansmagazin.net/photos/albums/${widget.album.slug}';
    final resp = await http.get(Uri.parse(url));
    if (resp.statusCode != 200) {
      throw Exception('Albüm fotoğrafları alınamadı (${resp.statusCode})');
    }

    final dynamic raw = jsonDecode(resp.body);
    List<dynamic> rows;
    if (raw is List) {
      rows = raw;
    } else if (raw is Map<String, dynamic>) {
      rows = (raw['photos'] as List<dynamic>?) ??
          (raw['items'] as List<dynamic>?) ??
          (raw['results'] as List<dynamic>?) ??
          <dynamic>[];
    } else {
      rows = <dynamic>[];
    }

    final out = rows
        .whereType<Map<String, dynamic>>()
        .map(_Photo.fromJson)
        .where((p) => p.url.isNotEmpty)
        .toList();
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> _toggleFavorite(_Photo photo) async {
    final isFav = _isFavorite(photo.url);
    if (isFav) {
      await _FavoriteStore.removeByUrl(widget.accountId, photo.url);
    } else {
      await _FavoriteStore.add(
        widget.accountId,
        _FavoritePhoto(
          url: photo.url,
          thumbUrl: photo.thumbUrl,
          albumSlug: widget.album.slug,
          albumName: widget.album.name,
          createdAt: photo.createdAt,
        ),
      );
    }
    await _loadFavorites();
  }

  Future<void> _openViewer(List<_Photo> photos, int initialIndex) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PhotoViewerScreen(
          photos: photos,
          initialIndex: initialIndex,
          album: widget.album,
          accountId: widget.accountId,
        ),
      ),
    );
    await _loadFavorites();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(widget.album.name),
      ),
      body: FutureBuilder<List<_Photo>>(
        future: _photosFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                'Albüm yüklenemedi',
                style: TextStyle(color: Colors.white.withOpacity(0.8)),
              ),
            );
          }

          final photos = snapshot.data ?? const <_Photo>[];
          if (photos.isEmpty) {
            return Center(
              child: Text(
                'Bu albümde fotoğraf yok.',
                style: TextStyle(color: Colors.white.withOpacity(0.8)),
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(10),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 0.8,
            ),
            itemCount: photos.length,
            itemBuilder: (context, i) {
              final p = photos[i];
              final fav = _isFavorite(p.url);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => _openViewer(photos, i),
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
                      onTap: () => _toggleFavorite(p),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          fav ? Icons.favorite : Icons.favorite_border,
                          color: fav ? Colors.redAccent : Colors.white,
                          size: 18,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _PhotoViewerScreen extends StatefulWidget {
  final List<_Photo> photos;
  final int initialIndex;
  final _Album album;
  final int accountId;

  const _PhotoViewerScreen({
    required this.photos,
    required this.initialIndex,
    required this.album,
    required this.accountId,
  });

  @override
  State<_PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<_PhotoViewerScreen> {
  late final PageController _controller;
  int _index = 0;
  List<_FavoritePhoto> _favorites = [];

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

  Future<void> _toggleFavorite(_Photo photo) async {
    final isFav = _isFavorite(photo.url);
    if (isFav) {
      await _FavoriteStore.removeByUrl(widget.accountId, photo.url);
    } else {
      await _FavoriteStore.add(
        widget.accountId,
        _FavoritePhoto(
          url: photo.url,
          thumbUrl: photo.thumbUrl,
          albumSlug: widget.album.slug,
          albumName: widget.album.name,
          createdAt: photo.createdAt,
        ),
      );
    }
    await _loadFavorites();
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
      body: Column(
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final _Album album;
  final VoidCallback onTap;

  const _AlbumCard({required this.album, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: const Color(0xFF121826),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: album.coverUrl.isNotEmpty
                  ? Image.network(
                      album.coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                    )
                  : Container(color: const Color(0xFF1F2937)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
              child: Text(
                album.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Text(
                '${album.photoCount} fotoğraf  ·  ${album.createdAt}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FavoriteGrid extends StatelessWidget {
  final List<_FavoritePhoto> photos;
  final int accountId;
  final Future<void> Function(String url) onUnfavorite;

  const _FavoriteGrid({required this.photos, required this.accountId, required this.onUnfavorite});

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) {
      return const _InfoCard(text: 'Henüz favori fotoğraf yok.');
    }

    final sorted = [...photos]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.8,
      ),
      itemCount: sorted.length,
      itemBuilder: (context, i) {
        final p = sorted[i];
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _FavoriteViewerScreen(
                        photos: sorted,
                        initialIndex: i,
                        accountId: accountId,
                      ),
                    ),
                  );
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
                onTap: () => onUnfavorite(p.url),
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
    );
  }
}

class _Album {
  final String slug;
  final String name;
  final String coverUrl;
  final String createdAt;
  final int photoCount;

  const _Album({
    required this.slug,
    required this.name,
    required this.coverUrl,
    required this.createdAt,
    required this.photoCount,
  });

  factory _Album.fromJson(Map<String, dynamic> json) {
    final slug = (json['slug'] ?? json['event_slug'] ?? '').toString();
    return _Album(
      slug: slug,
      name: (json['name'] ?? json['event_name'] ?? slug).toString(),
      coverUrl: _absUrl(
        json['cover_url'] ??
            json['cover'] ??
            json['cover_path'] ??
            json['album_cover'] ??
            json['latest_photo'] ??
            '',
      ),
      createdAt: _fmtDate(
        (json['created_at'] ?? json['date'] ?? json['latest_uploaded_at'] ?? '').toString(),
      ),
      photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class _Photo {
  final String url;
  final String thumbUrl;
  final String createdAt;

  const _Photo({
    required this.url,
    required this.thumbUrl,
    required this.createdAt,
  });

  factory _Photo.fromJson(Map<String, dynamic> json) {
    final url = _absUrl(
      json['url'] ?? json['file_url'] ?? json['file_path'] ?? json['image'] ?? json['photo_url'] ?? '',
    );
    final thumb = _absUrl(
      json['thumb_url'] ?? json['thumbnail_url'] ?? json['preview_url'] ?? url,
    );
    return _Photo(
      url: url,
      thumbUrl: thumb,
      createdAt: _fmtDate((json['created_at'] ?? json['date'] ?? '').toString()),
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

class _FavoriteViewerScreen extends StatefulWidget {
  final List<_FavoritePhoto> photos;
  final int initialIndex;
  final int accountId;

  const _FavoriteViewerScreen({
    required this.photos,
    required this.initialIndex,
    required this.accountId,
  });

  @override
  State<_FavoriteViewerScreen> createState() => _FavoriteViewerScreenState();
}

class _FavoriteViewerScreenState extends State<_FavoriteViewerScreen> {
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
      body: Column(
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
    );
  }
}

String _absUrl(dynamic raw) {
  final v = (raw ?? '').toString().trim();
  if (v.isEmpty) return '';
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (v.startsWith('/')) return 'https://api2.dansmagazin.net$v';
  return 'https://api2.dansmagazin.net/$v';
}

String _fmtDate(String raw) {
  if (raw.isEmpty) return '-';
  final cleaned = raw.replaceAll('T', ' ');
  if (cleaned.length >= 16) {
    return cleaned.substring(0, 16);
  }
  return cleaned;
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
  final Future<void> Function() onRetry;

  const _ErrorCard({required this.text, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF2A1212),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF7F1D1D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text),
          const SizedBox(height: 8),
          TextButton(onPressed: onRetry, child: const Text('Tekrar Dene')),
        ],
      ),
    );
  }
}
