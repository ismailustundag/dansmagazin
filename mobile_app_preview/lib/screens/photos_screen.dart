import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/date_time_format.dart';
import '../services/i18n.dart';
import 'screen_shell.dart';

Uri _encodedUri(String rawUrl) => Uri.parse(Uri.encodeFull(rawUrl.trim()));

Future<Uint8List> _downloadImageBytes(String url, {String? bearerToken}) async {
  final headers = <String, String>{
    'Accept': 'image/*,*/*;q=0.8',
    'User-Agent': 'DansmagazinApp/1.0',
  };
  final token = (bearerToken ?? '').trim();
  if (token.isNotEmpty) {
    headers['Authorization'] = 'Bearer $token';
  }
  final resp = await http.get(_encodedUri(url), headers: headers);
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

Future<bool> _saveToGallery(String url, Uint8List bytes) async {
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

class PhotosScreen extends StatefulWidget {
  final int accountId;
  final String sessionToken;
  final VoidCallback? onRequireLogin;

  const PhotosScreen({
    super.key,
    required this.accountId,
    required this.sessionToken,
    this.onRequireLogin,
  });

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  static const String _albumsUrl = 'https://api2.dansmagazin.net/photos';

  late Future<_PhotosFeed> _feedFuture;
  int _tab = 0; // 0: Fotograflar, 1: Videolar, 2: Favoriler
  List<_FavoritePhoto> _favorites = [];
  bool get _isLoggedIn => widget.sessionToken.trim().isNotEmpty;

  void _promptLogin([String message = 'Bu işlem için giriş yapmanız gerekiyor.']) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: widget.onRequireLogin == null
            ? null
            : SnackBarAction(
                label: 'Giriş Yap',
                onPressed: widget.onRequireLogin!,
              ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _feedFuture = _fetchFeed();
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    final loaded = await _FavoriteStore.load(widget.accountId);
    if (!mounted) return;
    setState(() => _favorites = loaded);
  }

  Future<void> _toggleAlbumLike(_Album album) async {
    if (!_isLoggedIn) {
      _promptLogin('Albüm beğenmek için giriş yapın.');
      return;
    }
    final endpoint = album.likedByMe ? 'unlike' : 'like';
    try {
      final resp = await http.post(
        Uri.parse('https://api2.dansmagazin.net/photos/albums/${album.slug}/$endpoint'),
        headers: {
          if (widget.sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${widget.sessionToken}',
        },
      );
      if (resp.statusCode != 200) {
        throw Exception('Beğeni güncellenemedi');
      }
      await _refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Albüm beğenisi güncellenemedi')),
      );
    }
  }

  Future<_PhotosFeed> _fetchFeed() async {
    final resp = await http.get(
      Uri.parse(_albumsUrl),
      headers: {
        if (widget.sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${widget.sessionToken}',
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('Album endpoint hata: ${resp.statusCode}');
    }

    final dynamic raw = jsonDecode(resp.body);
    final map = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    final albumRows = (map['albums'] as List<dynamic>?) ??
        (map['items'] as List<dynamic>?) ??
        (map['results'] as List<dynamic>?) ??
        <dynamic>[];
    final topLikedRows = (map['top_liked'] as List<dynamic>?) ?? <dynamic>[];

    final albums = albumRows
        .whereType<Map<String, dynamic>>()
        .map(_Album.fromJson)
        .where((a) => a.slug.isNotEmpty)
        .toList();
    final topLiked = topLikedRows
        .whereType<Map<String, dynamic>>()
        .map(_Photo.fromJson)
        .where((p) => p.url.isNotEmpty)
        .toList();

    return _PhotosFeed(
      albums: albums,
      topLiked: topLiked,
    );
  }

  Future<void> _refresh() async {
    setState(() {
      _feedFuture = _fetchFeed();
    });
    await _feedFuture;
  }

  Future<void> _openTopLikedViewer(List<_Photo> photos, int initialIndex) async {
    if (!_isLoggedIn) {
      _promptLogin('Fotoğraf detayını açmak için giriş yapın.');
      return;
    }
    final album = _Album(
      slug: 'top-liked',
      name: I18n.t('top_liked_photos'),
      coverUrl: '',
      coverThumbUrl: '',
      createdAt: '',
      photoCount: photos.length,
      likeCount: 0,
      likedByMe: false,
    );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PhotoViewerScreen(
          photos: photos,
          initialIndex: initialIndex,
          album: album,
          accountId: widget.accountId,
          sessionToken: widget.sessionToken,
          onRequireLogin: widget.onRequireLogin,
        ),
      ),
    );
    await _loadFavorites();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: I18n.t('photos'),
      icon: Icons.photo_library,
      subtitle: _isLoggedIn ? I18n.t('photos_subtitle_logged_in') : I18n.t('photos_subtitle_guest'),
      content: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0xFFE53935).withOpacity(0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFFE53935).withOpacity(0.28)),
          ),
          child: Text(
            I18n.t('photos_retention_notice'),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tabChip(0, I18n.t('photos')),
            _tabChip(1, I18n.t('videos')),
            _tabChip(2, I18n.t('favorites')),
          ],
        ),
        const SizedBox(height: 12),
        FutureBuilder<_PhotosFeed>(
          future: _feedFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _ErrorCard(
                text: I18n.t('photo_albums_load_error'),
                onRetry: _refresh,
              );
            }

            final feed = snapshot.data ?? const _PhotosFeed();
            final albums = feed.albums;
            final topLiked = feed.topLiked;
            if (_tab == 1) {
              return _InfoCard(
                text: I18n.t('videos_coming_soon'),
              );
            }

            if (_tab == 2) {
              if (!_isLoggedIn) {
                return _LoginRequiredCard(
                  text: I18n.t('favorites_login_required'),
                  onLoginTap: widget.onRequireLogin,
                );
              }
              return _FavoriteGrid(
                photos: _favorites,
                accountId: widget.accountId,
                onUnfavorite: (url) async {
                  await _FavoriteStore.removeByUrl(widget.accountId, url);
                  await _loadFavorites();
                },
              );
            }

            final list = albums;
            if (list.isEmpty && topLiked.isEmpty) {
              return _InfoCard(text: I18n.t('no_albums_found'));
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (topLiked.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      I18n.t('top_liked_photos'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  _TopLikedGrid(
                    photos: topLiked,
                    onTap: (index) => _openTopLikedViewer(topLiked, index),
                  ),
                  const SizedBox(height: 14),
                ],
                ...list.map(
                  (album) => Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _AlbumCard(
                      album: album,
                      liked: album.likedByMe,
                      onLikeTap: () => _toggleAlbumLike(album),
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AlbumPhotosScreen(
                              album: album,
                              accountId: widget.accountId,
                              sessionToken: widget.sessionToken,
                              onRequireLogin: widget.onRequireLogin,
                            ),
                          ),
                        );
                        await _loadFavorites();
                      },
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

class _PhotosFeed {
  final List<_Album> albums;
  final List<_Photo> topLiked;

  const _PhotosFeed({
    this.albums = const [],
    this.topLiked = const [],
  });
}

class AlbumPhotosScreen extends StatefulWidget {
  final _Album album;
  final int accountId;
  final String sessionToken;
  final VoidCallback? onRequireLogin;

  const AlbumPhotosScreen({
    super.key,
    required this.album,
    required this.accountId,
    required this.sessionToken,
    this.onRequireLogin,
  });

  @override
  State<AlbumPhotosScreen> createState() => _AlbumPhotosScreenState();
}

class _AlbumPhotosScreenState extends State<AlbumPhotosScreen> {
  late Future<List<_Photo>> _photosFuture;
  List<_FavoritePhoto> _favorites = [];
  bool _showFavoritesOnly = false;
  bool get _isLoggedIn => widget.sessionToken.trim().isNotEmpty;

  void _promptLogin([String message = 'Bu işlem için giriş yapmanız gerekiyor.']) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: widget.onRequireLogin == null
            ? null
            : SnackBarAction(
                label: 'Giriş Yap',
                onPressed: widget.onRequireLogin!,
              ),
      ),
    );
  }

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
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        if (widget.sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${widget.sessionToken}',
      },
    );
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

  Future<void> _togglePhotoLike(_Photo photo) async {
    if (!_isLoggedIn) {
      _promptLogin('Fotoğraf beğenmek için giriş yapın.');
      return;
    }
    final endpoint = photo.likedByMe ? 'unlike' : 'like';
    try {
      final resp = await http.post(
        Uri.parse('https://api2.dansmagazin.net/photos/items/${photo.id}/$endpoint'),
        headers: {
          if (widget.sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${widget.sessionToken}',
        },
      );
      if (resp.statusCode != 200) {
        throw Exception('like failed');
      }
      if (!mounted) return;
      setState(() {
        _photosFuture = _fetchPhotos();
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fotoğraf beğenisi güncellenemedi')),
      );
    }
  }

  Future<void> _toggleFavorite(_Photo photo) async {
    if (!_isLoggedIn) {
      _promptLogin('Favorilere eklemek için giriş yapın.');
      return;
    }
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
    if (!_isLoggedIn) {
      _promptLogin('Fotoğraf detayını açmak için giriş yapın.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _PhotoViewerScreen(
          photos: photos,
          initialIndex: initialIndex,
          album: widget.album,
          accountId: widget.accountId,
          sessionToken: widget.sessionToken,
          onRequireLogin: widget.onRequireLogin,
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
        actions: [
          TextButton.icon(
            onPressed: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
            icon: Icon(
              _showFavoritesOnly ? Icons.star : Icons.star_border,
              color: _showFavoritesOnly ? const Color(0xFFFFC107) : Colors.white,
            ),
            label: Text(
              'Favorilerim',
              style: TextStyle(
                color: _showFavoritesOnly ? const Color(0xFFFFC107) : Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<List<_Photo>>(
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
          final shown = _showFavoritesOnly
              ? photos.where((p) => _isFavorite(p.url)).toList()
              : photos;
          if (shown.isEmpty) {
            return Center(
              child: Text(
                _showFavoritesOnly
                    ? 'Bu albümde favori fotoğraf yok.'
                    : 'Bu albümde fotoğraf yok.',
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
            itemCount: shown.length,
            itemBuilder: (context, i) {
              final p = shown[i];
              final fav = _isFavorite(p.url);
              return Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: GestureDetector(
                      onTap: () => _openViewer(shown, i),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(
                          p.thumbUrl.isNotEmpty ? p.thumbUrl : p.url,
                          fit: BoxFit.cover,
                          cacheWidth: 420,
                          filterQuality: FilterQuality.low,
                          errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 6,
                    left: 6,
                    child: InkWell(
                      onTap: () => _togglePhotoLike(p),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              p.likedByMe ? Icons.favorite : Icons.favorite_border,
                              color: p.likedByMe ? Colors.redAccent : Colors.white,
                              size: 16,
                            ),
                            const SizedBox(width: 4),
                            Text('${p.likeCount}', style: const TextStyle(fontSize: 11)),
                          ],
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
                          fav ? Icons.star : Icons.star_border,
                          color: fav ? const Color(0xFFFFC107) : Colors.white,
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
      ),
    );
  }
}

class _PhotoViewerScreen extends StatefulWidget {
  final List<_Photo> photos;
  final int initialIndex;
  final _Album album;
  final int accountId;
  final String sessionToken;
  final VoidCallback? onRequireLogin;

  const _PhotoViewerScreen({
    required this.photos,
    required this.initialIndex,
    required this.album,
    required this.accountId,
    required this.sessionToken,
    this.onRequireLogin,
  });

  @override
  State<_PhotoViewerScreen> createState() => _PhotoViewerScreenState();
}

class _PhotoViewerScreenState extends State<_PhotoViewerScreen> {
  late final PageController _controller;
  int _index = 0;
  List<_FavoritePhoto> _favorites = [];
  late List<_Photo> _photos;
  bool get _isLoggedIn => widget.sessionToken.trim().isNotEmpty;

  void _promptLogin([String message = 'Bu işlem için giriş yapmanız gerekiyor.']) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: widget.onRequireLogin == null
            ? null
            : SnackBarAction(
                label: 'Giriş Yap',
                onPressed: widget.onRequireLogin!,
              ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _photos = List<_Photo>.from(widget.photos);
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
    if (!_isLoggedIn) {
      _promptLogin('Favorilere eklemek için giriş yapın.');
      return;
    }
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

  Future<void> _download(String url) async {
    if (!_isLoggedIn) {
      _promptLogin('Fotoğraf indirmek için giriş yapın.');
      return;
    }
    try {
      final bytes = await _downloadImageBytes(url, bearerToken: widget.sessionToken);
      final saved = await _saveToGallery(url, bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(saved ? 'Fotoğraf albüme kaydedildi' : 'İndirme açılamadı')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('İndirme açılamadı (${e.runtimeType})')),
      );
    }
  }

  Future<void> _togglePhotoLike(_Photo photo) async {
    if (!_isLoggedIn) {
      _promptLogin('Fotoğraf beğenmek için giriş yapın.');
      return;
    }
    final endpoint = photo.likedByMe ? 'unlike' : 'like';
    try {
      final resp = await http.post(
        Uri.parse('https://api2.dansmagazin.net/photos/items/${photo.id}/$endpoint'),
        headers: {
          if (widget.sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${widget.sessionToken}',
        },
      );
      if (resp.statusCode != 200) {
        throw Exception('like failed');
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final likeCount = (body['like_count'] as num?)?.toInt() ?? photo.likeCount;
      final likedByMe = body['liked_by_me'] == true;
      if (!mounted) return;
      setState(() {
        _photos[_index] = photo.copyWith(
          likeCount: likeCount,
          likedByMe: likedByMe,
        );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fotoğraf beğenisi güncellenemedi')),
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
    final photo = _photos[_index];
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
                itemCount: _photos.length,
                onPageChanged: (v) => setState(() => _index = v),
                itemBuilder: (context, i) {
                  final p = _photos[i];
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
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _iconAction(
                    onTap: () => _togglePhotoLike(photo),
                    tooltip: 'Beğen (${photo.likeCount})',
                    icon: photo.likedByMe ? Icons.favorite : Icons.favorite_border,
                    color: photo.likedByMe ? Colors.redAccent : Colors.white,
                  ),
                  _iconAction(
                    onTap: () => _toggleFavorite(photo),
                    tooltip: fav ? 'Favoriden Çıkar' : 'Favorile',
                    icon: fav ? Icons.star : Icons.star_border,
                    color: fav ? const Color(0xFFFFC107) : Colors.white,
                  ),
                  _iconAction(
                    onTap: () => _download(photo.url),
                    tooltip: 'İndir',
                    icon: Icons.download,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconAction({
    required VoidCallback onTap,
    required String tooltip,
    required IconData icon,
    required Color color,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white10,
            border: Border.all(color: Colors.white24),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
      ),
    );
  }
}

class _AlbumCard extends StatelessWidget {
  final _Album album;
  final bool liked;
  final VoidCallback onLikeTap;
  final VoidCallback onTap;

  const _AlbumCard({
    required this.album,
    required this.liked,
    required this.onLikeTap,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final previewUrl = album.coverThumbUrl.isNotEmpty ? album.coverThumbUrl : album.coverUrl;
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
              child: previewUrl.isNotEmpty
                  ? Image.network(
                      previewUrl,
                      fit: BoxFit.cover,
                      cacheWidth: 960,
                      filterQuality: FilterQuality.low,
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
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onLikeTap,
                      icon: Icon(
                        liked ? Icons.favorite : Icons.favorite_border,
                        color: liked ? Colors.redAccent : Colors.white,
                        size: 18,
                      ),
                      label: Text('Beğen (${album.likeCount})'),
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

class _TopLikedGrid extends StatelessWidget {
  final List<_Photo> photos;
  final ValueChanged<int> onTap;

  const _TopLikedGrid({
    required this.photos,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.8,
      ),
      itemCount: photos.length,
      itemBuilder: (context, i) {
        final photo = photos[i];
        return GestureDetector(
          onTap: () => onTap(i),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.network(
                  photo.thumbUrl.isNotEmpty ? photo.thumbUrl : photo.url,
                  fit: BoxFit.cover,
                  cacheWidth: 420,
                  filterQuality: FilterQuality.low,
                  errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                ),
              ),
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.62),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.favorite, size: 14, color: Colors.redAccent),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${photo.likeCount}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
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
                    cacheWidth: 420,
                    filterQuality: FilterQuality.low,
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
  final String coverThumbUrl;
  final String createdAt;
  final int photoCount;
  final int likeCount;
  final bool likedByMe;

  const _Album({
    required this.slug,
    required this.name,
    required this.coverUrl,
    required this.coverThumbUrl,
    required this.createdAt,
    required this.photoCount,
    required this.likeCount,
    required this.likedByMe,
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
      coverThumbUrl: _absUrl(
        json['cover_thumb_url'] ??
            json['thumb_url'] ??
            json['thumbnail_url'] ??
            json['preview_url'] ??
            json['cover_url'] ??
            json['cover'] ??
            '',
      ),
      createdAt: _fmtDate(
        (json['created_at'] ?? json['date'] ?? json['latest_uploaded_at'] ?? '').toString(),
      ),
      photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      likedByMe: json['liked_by_me'] == true,
    );
  }
}

class _Photo {
  final int id;
  final String url;
  final String thumbUrl;
  final String createdAt;
  final int likeCount;
  final bool likedByMe;

  const _Photo({
    required this.id,
    required this.url,
    required this.thumbUrl,
    required this.createdAt,
    required this.likeCount,
    required this.likedByMe,
  });

  factory _Photo.fromJson(Map<String, dynamic> json) {
    final url = _absUrl(
      json['url'] ?? json['file_url'] ?? json['file_path'] ?? json['image'] ?? json['photo_url'] ?? '',
    );
    final thumb = _absUrl(
      json['thumb_url'] ?? json['thumbnail_url'] ?? json['preview_url'] ?? url,
    );
    return _Photo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      url: url,
      thumbUrl: thumb,
      createdAt: _fmtDate((json['created_at'] ?? json['date'] ?? '').toString()),
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      likedByMe: json['liked_by_me'] == true,
    );
  }

  _Photo copyWith({
    int? id,
    String? url,
    String? thumbUrl,
    String? createdAt,
    int? likeCount,
    bool? likedByMe,
  }) {
    return _Photo(
      id: id ?? this.id,
      url: url ?? this.url,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      createdAt: createdAt ?? this.createdAt,
      likeCount: likeCount ?? this.likeCount,
      likedByMe: likedByMe ?? this.likedByMe,
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

class _AlbumLikeStore {
  static String _key(int accountId) => 'liked_albums_v1_user_$accountId';

  static Future<Set<String>> load(int accountId) async {
    final prefs = await SharedPreferences.getInstance();
    final rows = prefs.getStringList(_key(accountId)) ?? const <String>[];
    return rows.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
  }

  static Future<void> add(int accountId, String slug) async {
    final prefs = await SharedPreferences.getInstance();
    final set = await load(accountId);
    set.add(slug);
    await prefs.setStringList(_key(accountId), set.toList()..sort());
  }

  static Future<void> remove(int accountId, String slug) async {
    final prefs = await SharedPreferences.getInstance();
    final set = await load(accountId);
    set.remove(slug);
    await prefs.setStringList(_key(accountId), set.toList()..sort());
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
    try {
      final bytes = await _downloadImageBytes(url);
      final saved = await _saveToGallery(url, bytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(saved ? 'Fotoğraf albüme kaydedildi' : 'İndirme açılamadı')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('İndirme açılamadı (${e.runtimeType})')),
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

String _absUrl(dynamic raw) {
  final v = (raw ?? '').toString().trim();
  if (v.isEmpty) return '';
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (v.startsWith('/')) return 'https://api2.dansmagazin.net$v';
  return 'https://api2.dansmagazin.net/$v';
}

String _fmtDate(String raw) {
  return formatDateTimeDdMmYyyyHmDot(raw);
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

class _LoginRequiredCard extends StatelessWidget {
  final String text;
  final VoidCallback? onLoginTap;

  const _LoginRequiredCard({required this.text, this.onLoginTap});

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(color: Colors.white.withOpacity(0.9))),
          if (onLoginTap != null) ...[
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: ElevatedButton.icon(
                onPressed: onLoginTap,
                icon: const Icon(Icons.login),
                label: const Text('Giriş Yap'),
              ),
            ),
          ],
        ],
      ),
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
