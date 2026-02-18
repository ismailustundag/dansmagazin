import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'app_webview_screen.dart';
import 'placeholder_detail_screen.dart';
import 'screen_shell.dart';

class PhotosScreen extends StatefulWidget {
  const PhotosScreen({super.key});

  @override
  State<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends State<PhotosScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<_PhotosData> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchData();
  }

  Future<_PhotosData> _fetchData() async {
    final resp = await http.get(Uri.parse('$_base/photos?albums_limit=30&latest_limit=80'));
    if (resp.statusCode != 200) {
      throw Exception('Fotoğraflar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return _PhotosData.fromJson(body);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_PhotosData>(
      future: _future,
      builder: (context, snapshot) {
        final data = snapshot.data;
        final albums = data?.albums.length ?? 0;
        final latest = data?.latest.length ?? 0;
        return ScreenShell(
          title: 'Fotoğraflar',
          icon: Icons.photo_library,
          subtitle: 'Etkinlik galerileriniz ve satın alınan fotoğraflar.',
          content: [
            PreviewCard(
              title: 'Tüm Etkinlikler',
              subtitle: '$albums albüm',
              icon: Icons.collections,
              onTap: () {
                if (snapshot.hasError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Önce veri yüklenmeli.')),
                  );
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => _AlbumsScreen(albums: data?.albums ?? const []),
                  ),
                );
              },
            ),
            PreviewCard(
              title: 'Son Yüklenenler',
              subtitle: '$latest fotoğraf',
              icon: Icons.new_releases,
              onTap: () {
                if (snapshot.hasError) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Önce veri yüklenmeli.')),
                  );
                  return;
                }
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => _LatestPhotosScreen(items: data?.latest ?? const []),
                  ),
                );
              },
            ),
            PreviewCard(
              title: 'Favoriler',
              subtitle: 'Yakında aktif olacak',
              icon: Icons.favorite,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PlaceholderDetailScreen(
                    title: 'Favoriler',
                    description: 'Favoriler özelliği bir sonraki adımda bağlanacak.',
                    icon: Icons.favorite,
                  ),
                ),
              ),
            ),
            if (snapshot.connectionState == ConnectionState.waiting)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (snapshot.hasError)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: TextButton(
                  onPressed: () => setState(() => _future = _fetchData()),
                  child: const Text('Fotoğraf verisi alınamadı, tekrar dene'),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _PhotosData {
  final List<_AlbumItem> albums;
  final List<_PhotoItem> latest;

  _PhotosData({required this.albums, required this.latest});

  factory _PhotosData.fromJson(Map<String, dynamic> json) {
    final rawAlbums = (json['albums'] as List<dynamic>? ?? []);
    final rawLatest = (json['latest'] as List<dynamic>? ?? []);
    return _PhotosData(
      albums: rawAlbums.map((e) => _AlbumItem.fromJson(e as Map<String, dynamic>)).toList(),
      latest: rawLatest.map((e) => _PhotoItem.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }
}

class _AlbumItem {
  final String slug;
  final String name;
  final String cover;
  final int photoCount;
  final String link;

  _AlbumItem({
    required this.slug,
    required this.name,
    required this.cover,
    required this.photoCount,
    required this.link,
  });

  factory _AlbumItem.fromJson(Map<String, dynamic> json) {
    return _AlbumItem(
      slug: (json['slug'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      photoCount: (json['photo_count'] as num?)?.toInt() ?? 0,
      link: (json['link'] ?? '').toString(),
    );
  }
}

class _PhotoItem {
  final String image;
  final String eventName;

  _PhotoItem({required this.image, required this.eventName});

  factory _PhotoItem.fromJson(Map<String, dynamic> json) {
    return _PhotoItem(
      image: (json['image'] ?? '').toString(),
      eventName: (json['event_name'] ?? json['slug'] ?? '').toString(),
    );
  }
}

class _AlbumsScreen extends StatelessWidget {
  final List<_AlbumItem> albums;

  const _AlbumsScreen({required this.albums});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tüm Etkinlikler')),
      body: albums.isEmpty
          ? const Center(child: Text('Henüz albüm yok.'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: albums.length,
              itemBuilder: (_, i) {
                final a = albums[i];
                return Card(
                  child: ListTile(
                    leading: a.cover.isEmpty
                        ? const SizedBox(width: 56, height: 56)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Image.network(
                              a.cover,
                              width: 56,
                              height: 56,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const SizedBox(width: 56, height: 56),
                            ),
                          ),
                    title: Text(a.name.isEmpty ? a.slug : a.name),
                    subtitle: Text('${a.photoCount} fotoğraf'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      if (a.link.isNotEmpty) {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => AppWebViewScreen(url: a.link, title: a.name),
                          ),
                        );
                      }
                    },
                  ),
                );
              },
            ),
    );
  }
}

class _LatestPhotosScreen extends StatelessWidget {
  final List<_PhotoItem> items;

  const _LatestPhotosScreen({required this.items});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Son Yüklenenler')),
      body: items.isEmpty
          ? const Center(child: Text('Fotoğraf bulunamadı.'))
          : GridView.builder(
              padding: const EdgeInsets.all(10),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
              ),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final p = items[i];
                return ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.network(
                        p.image,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(color: Colors.black26),
                      ),
                      Positioned(
                        left: 4,
                        right: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          color: Colors.black54,
                          child: Text(
                            p.eventName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 10),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
