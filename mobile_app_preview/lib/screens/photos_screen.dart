import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/date_time_format.dart';
import '../services/i18n.dart';
import '../services/photo_flow_api.dart';
import '../theme/app_theme.dart';
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
  late Future<List<PhotoFlowPost>> _communityFeedFuture;
  int _tab = 0; // 0: Akis, 1: Albumler, 2: Videolar
  List<_FavoritePhoto> _favorites = [];
  final ImagePicker _picker = ImagePicker();
  final TextEditingController _postCtrl = TextEditingController();
  XFile? _selectedPostImage;
  bool _sendingPost = false;
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
    _communityFeedFuture = _fetchCommunityFeed();
    _loadFavorites();
  }

  @override
  void dispose() {
    _postCtrl.dispose();
    super.dispose();
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

  Future<List<PhotoFlowPost>> _fetchCommunityFeed() {
    return PhotoFlowApi.fetch(sessionToken: widget.sessionToken);
  }

  Future<void> _refresh() async {
    setState(() {
      _feedFuture = _fetchFeed();
      _communityFeedFuture = _fetchCommunityFeed();
    });
    await _feedFuture;
  }

  Future<void> _pickPostImage() async {
    try {
      final img = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 82,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (!mounted || img == null) return;
      setState(() => _selectedPostImage = img);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Fotoğraf seçilemedi')),
      );
    }
  }

  void _clearPostImage() {
    setState(() => _selectedPostImage = null);
  }

  Future<void> _sharePost() async {
    if (!_isLoggedIn) {
      _promptLogin('Akışta paylaşım yapmak için giriş yapın.');
      return;
    }
    final text = _postCtrl.text.trim();
    final imagePath = _selectedPostImage?.path.trim() ?? '';
    if (text.isEmpty && imagePath.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Metin veya fotoğraf ekleyin')),
      );
      return;
    }
    setState(() => _sendingPost = true);
    try {
      await PhotoFlowApi.createPost(
        widget.sessionToken,
        text: text,
        imagePath: imagePath.isEmpty ? null : imagePath,
      );
      _postCtrl.clear();
      if (mounted) {
        setState(() {
          _selectedPostImage = null;
          _communityFeedFuture = _fetchCommunityFeed();
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _sendingPost = false);
    }
  }

  Future<void> _toggleFeedLike(PhotoFlowPost post) async {
    if (!_isLoggedIn) {
      _promptLogin('Gönderi beğenmek için giriş yapın.');
      return;
    }
    try {
      await PhotoFlowApi.setLike(
        widget.sessionToken,
        postId: post.id,
        like: !post.likedByMe,
      );
      if (!mounted) return;
      setState(() => _communityFeedFuture = _fetchCommunityFeed());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    }
  }

  Future<void> _openRepliesSheet(PhotoFlowPost post) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _RepliesSheet(
        post: post,
        sessionToken: widget.sessionToken,
        onRequireLogin: widget.onRequireLogin,
      ),
    );
    if (!mounted) return;
    setState(() => _communityFeedFuture = _fetchCommunityFeed());
  }

  Future<void> _openTopLikedViewer(List<_Photo> photos, int initialIndex) async {
    if (!_isLoggedIn) {
      _promptLogin('Fotoğraf detayını açmak için giriş yapın.');
      return;
    }
    final album = _Album(
      slug: 'top-liked',
      name: I18n.t('top_liked_photos'),
      albumType: 'top_liked',
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
      showHeader: false,
      tone: AppTone.photos,
      content: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tabChip(0, 'Akış'),
            _tabChip(1, 'Albümler'),
            _tabChip(2, I18n.t('videos')),
          ],
        ),
        const SizedBox(height: 12),
        if (_tab == 0)
          _FlowComposerCard(
            controller: _postCtrl,
            selectedImagePath: _selectedPostImage?.path,
            sending: _sendingPost,
            onPickImage: _pickPostImage,
            onClearImage: _clearPostImage,
            onSubmit: _sharePost,
          ),
        if (_tab == 0) const SizedBox(height: 12),
        if (_tab == 0)
          FutureBuilder<List<PhotoFlowPost>>(
            future: _communityFeedFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _ErrorCard(
                  text: 'Akış yüklenemedi.',
                  onRetry: () async {
                    setState(() => _communityFeedFuture = _fetchCommunityFeed());
                  },
                );
              }
              final posts = snapshot.data ?? const <PhotoFlowPost>[];
              if (posts.isEmpty) {
                return const _InfoCard(text: 'Henüz paylaşım yok. İlk anıyı sen paylaş.');
              }
              return Column(
                children: posts
                    .map(
                      (post) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _FeedPostCard(
                          post: post,
                          onLikeTap: () => _toggleFeedLike(post),
                          onReplyTap: () => _openRepliesSheet(post),
                        ),
                      ),
                    )
                    .toList(),
              );
            },
          ),
        if (_tab != 0)
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
              if (_tab == 2) {
                return _InfoCard(
                  text: I18n.t('videos_coming_soon'),
                );
              }

              final list = albums;
              if (list.isEmpty && topLiked.isEmpty) {
                return _InfoCard(text: I18n.t('no_albums_found'));
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                  if (topLiked.isNotEmpty) ...[
                    const SizedBox(height: 8),
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
      selectedColor: AppTheme.cyan.withOpacity(0.28),
      backgroundColor: AppTheme.surfaceSecondary,
      labelStyle: TextStyle(color: selected ? AppTheme.textPrimary : AppTheme.textSecondary),
      side: BorderSide(color: selected ? Colors.transparent : AppTheme.borderSoft),
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

class _FlowComposerCard extends StatelessWidget {
  final TextEditingController controller;
  final String? selectedImagePath;
  final bool sending;
  final VoidCallback onPickImage;
  final VoidCallback onClearImage;
  final VoidCallback onSubmit;

  const _FlowComposerCard({
    required this.controller,
    required this.selectedImagePath,
    required this.sending,
    required this.onPickImage,
    required this.onClearImage,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: AppTheme.panel(tone: AppTone.photos, radius: 22, elevated: true),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              hintText: 'Haydi Sende bir Dans fotoğrafı yada anını paylaş',
              filled: true,
              fillColor: AppTheme.surfacePrimary,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: AppTheme.borderSoft),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: AppTheme.borderSoft),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(18),
                borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
              ),
            ),
          ),
          if ((selectedImagePath ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(
                children: [
                  Image.file(
                    File(selectedImagePath!),
                    width: double.infinity,
                    height: 220,
                    fit: BoxFit.cover,
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: InkWell(
                      onTap: onClearImage,
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: AppTheme.surfacePrimary.withOpacity(0.86),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: sending ? null : onPickImage,
                icon: const Icon(Icons.add_photo_alternate_outlined),
                label: const Text('Fotoğraf Ekle'),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: sending ? null : onSubmit,
                icon: sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
                label: Text(sending ? 'Gönderiliyor' : I18n.t('share')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedPostCard extends StatelessWidget {
  final PhotoFlowPost post;
  final VoidCallback onLikeTap;
  final VoidCallback onReplyTap;

  const _FeedPostCard({
    required this.post,
    required this.onLikeTap,
    required this.onReplyTap,
  });

  @override
  Widget build(BuildContext context) {
    final imageUrl = post.imageThumbUrl.isNotEmpty ? post.imageThumbUrl : post.imageUrl;
    return Container(
      decoration: AppTheme.panel(tone: AppTone.photos, radius: 22, elevated: true),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppTheme.surfacePrimary,
                backgroundImage: post.authorAvatarUrl.trim().isNotEmpty
                    ? CachedNetworkImageProvider(post.authorAvatarUrl)
                    : null,
                child: post.authorAvatarUrl.trim().isEmpty
                    ? Text(
                        post.authorName.isNotEmpty ? post.authorName.substring(0, 1).toUpperCase() : '?',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      post.authorName,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatDateTimeDdMmYyyyHmDot(post.createdAt, fallback: '-'),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (post.body.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              post.body,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
          ],
          if (imageUrl.trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: CachedNetworkImage(
                imageUrl: imageUrl,
                width: double.infinity,
                height: 260,
                fit: BoxFit.cover,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              InkWell(
                onTap: onLikeTap,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                  child: Row(
                    children: [
                      Icon(
                        post.likedByMe ? Icons.favorite : Icons.favorite_border,
                        color: post.likedByMe ? AppTheme.pink : AppTheme.textSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: 6),
                      Text('${post.likeCount}'),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 18),
              InkWell(
                onTap: onReplyTap,
                borderRadius: BorderRadius.circular(999),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
                  child: Row(
                    children: [
                      const Icon(Icons.chat_bubble_outline_rounded, size: 19, color: AppTheme.textSecondary),
                      const SizedBox(width: 6),
                      Text('${post.replyCount} yanıt'),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (post.replies.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...post.replies.take(2).map(
              (reply) => Padding(
                padding: const EdgeInsets.only(top: 6),
                child: RichText(
                  text: TextSpan(
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                    children: [
                      TextSpan(
                        text: '${reply.authorName}: ',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      TextSpan(text: reply.body),
                    ],
                  ),
                ),
              ),
            ),
            if (post.replyCount > 2)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: TextButton(
                  onPressed: onReplyTap,
                  child: const Text('Tüm yanıtları gör'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _RepliesSheet extends StatefulWidget {
  final PhotoFlowPost post;
  final String sessionToken;
  final VoidCallback? onRequireLogin;

  const _RepliesSheet({
    required this.post,
    required this.sessionToken,
    this.onRequireLogin,
  });

  @override
  State<_RepliesSheet> createState() => _RepliesSheetState();
}

class _RepliesSheetState extends State<_RepliesSheet> {
  late PhotoFlowPost _post;
  final TextEditingController _replyCtrl = TextEditingController();
  bool _sending = false;

  bool get _isLoggedIn => widget.sessionToken.trim().isNotEmpty;

  @override
  void initState() {
    super.initState();
    _post = widget.post;
  }

  @override
  void dispose() {
    _replyCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendReply() async {
    if (!_isLoggedIn) {
      Navigator.of(context).pop();
      widget.onRequireLogin?.call();
      return;
    }
    final text = _replyCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      final updated = await PhotoFlowApi.addReply(
        widget.sessionToken,
        postId: _post.id,
        text: text,
      );
      if (!mounted) return;
      _replyCtrl.clear();
      setState(() => _post = updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.78,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderStrong,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Yanıtlar',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                children: [
                  _FeedPostCard(
                    post: _post,
                    onLikeTap: () {},
                    onReplyTap: () {},
                  ),
                  const SizedBox(height: 12),
                  if (_post.replies.isEmpty)
                    const _InfoCard(text: 'Henüz yanıt yok. İlk yorumu sen bırak.')
                  else
                    ..._post.replies.map(
                      (reply) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(14),
                        decoration: AppTheme.panel(tone: AppTone.photos, radius: 18, subtle: true),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              reply.authorName,
                              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              formatDateTimeDdMmYyyyHmDot(reply.createdAt, fallback: '-'),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textSecondary,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(reply.body),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceSecondary,
                border: Border(top: BorderSide(color: AppTheme.borderSoft)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _replyCtrl,
                      minLines: 1,
                      maxLines: 3,
                      decoration: InputDecoration(
                        hintText: 'Yanıtını yaz',
                        filled: true,
                        fillColor: AppTheme.surfacePrimary,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: AppTheme.borderSoft),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: AppTheme.borderSoft),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    onPressed: _sending ? null : _sendReply,
                    child: Text(_sending ? '...' : 'Yanıtla'),
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

class _AlbumDetailFeed {
  final List<_Photo> photos;
  final List<_Album> subalbums;
  final int total;
  final int page;
  final int pageSize;

  const _AlbumDetailFeed({
    this.photos = const [],
    this.subalbums = const [],
    this.total = 0,
    this.page = 1,
    this.pageSize = 200,
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
  late Future<_AlbumDetailFeed> _photosFuture;
  List<_FavoritePhoto> _favorites = [];
  bool _showFavoritesOnly = false;
  static const int _pageSize = 100;
  static const int _prefetchCount = 12;
  int _currentPage = 1;
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
    _currentPage = 1;
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

  Future<_AlbumDetailFeed> _fetchPhotos({int page = 1}) async {
    final safePage = page < 1 ? 1 : page;
    final offset = (safePage - 1) * _pageSize;
    final url =
        'https://api2.dansmagazin.net/photos/albums/${widget.album.slug}?limit=$_pageSize&offset=$offset';
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
    List<dynamic> subalbumRows;
    if (raw is List) {
      rows = raw;
      subalbumRows = const <dynamic>[];
    } else if (raw is Map<String, dynamic>) {
      rows = (raw['photos'] as List<dynamic>?) ??
          (raw['items'] as List<dynamic>?) ??
          (raw['results'] as List<dynamic>?) ??
          <dynamic>[];
      subalbumRows = (raw['subalbums'] as List<dynamic>?) ?? <dynamic>[];
    } else {
      rows = <dynamic>[];
      subalbumRows = <dynamic>[];
    }

    final photos = rows
        .whereType<Map<String, dynamic>>()
        .map(_Photo.fromJson)
        .where((p) => p.url.isNotEmpty)
        .toList();
    photos.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final subalbums = subalbumRows
        .whereType<Map<String, dynamic>>()
        .map(_Album.fromJson)
        .where((a) => a.slug.isNotEmpty)
        .toList();
    return _AlbumDetailFeed(
      photos: photos,
      subalbums: subalbums,
      total: (raw is Map<String, dynamic>) ? ((raw['total'] as num?)?.toInt() ?? photos.length) : photos.length,
      page: safePage,
      pageSize: _pageSize,
    );
  }

  void _warmVisibleThumbs(List<_Photo> photos) {
    if (!mounted || photos.isEmpty) return;
    for (final photo in photos.take(_prefetchCount)) {
      final url = photo.gridThumbUrl.isNotEmpty
          ? photo.gridThumbUrl
          : (photo.thumbUrl.isNotEmpty ? photo.thumbUrl : '');
      if (url.isEmpty) continue;
      precacheImage(CachedNetworkImageProvider(url), context);
    }
  }

  Future<void> _refreshAlbum() async {
    setState(() {
      _currentPage = 1;
      _photosFuture = _fetchPhotos(page: 1);
    });
    await _photosFuture;
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
        _photosFuture = _fetchPhotos(page: 1);
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
        throw Exception('album like failed');
      }
      if (!mounted) return;
      setState(() {
        _photosFuture = _fetchPhotos(page: 1);
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Albüm beğenisi güncellenemedi')),
      );
    }
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
    if (mounted) {
      setState(() {
        _photosFuture = _fetchPhotos(page: _currentPage);
      });
    }
    await _loadFavorites();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: Text(widget.album.name),
        actions: [
          TextButton.icon(
            onPressed: () => setState(() => _showFavoritesOnly = !_showFavoritesOnly),
            icon: Icon(
              _showFavoritesOnly ? Icons.star : Icons.star_border,
              color: _showFavoritesOnly ? AppTheme.amber : AppTheme.textPrimary,
            ),
            label: Text(
              I18n.t('my_favorites'),
              style: TextStyle(
                color: _showFavoritesOnly ? AppTheme.amber : AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<_AlbumDetailFeed>(
          future: _photosFuture,
          builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text(
                I18n.t('album_load_failed'),
                style: TextStyle(color: Colors.white.withOpacity(0.8)),
              ),
            );
          }

          final feed = snapshot.data ?? const _AlbumDetailFeed();
          _warmVisibleThumbs(feed.photos);
          final photos = feed.photos;
          final subalbums = feed.subalbums;
          final totalPages =
              feed.pageSize > 0 ? ((feed.total + feed.pageSize - 1) ~/ feed.pageSize) : 1;
          final shown = _showFavoritesOnly
              ? photos.where((p) => _isFavorite(p.url)).toList()
              : photos;
          if (shown.isEmpty && subalbums.isEmpty) {
            return Center(
              child: Text(
                _showFavoritesOnly
                    ? I18n.t('no_favorite_photo_in_album')
                    : I18n.t('no_photo_in_album'),
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
            );
          }

          return RefreshIndicator(
            onRefresh: _refreshAlbum,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(10),
              children: [
                if (subalbums.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Text(
                      I18n.t('upload_parts'),
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                    ),
                  ),
                  ...subalbums.map(
                    (album) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _AlbumCard(
                        album: album,
                        liked: album.likedByMe,
                        onLikeTap: () async {
                          await _toggleAlbumLike(album);
                        },
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
                          if (!mounted) return;
                          setState(() {
                            _currentPage = 1;
                            _photosFuture = _fetchPhotos(page: 1);
                          });
                          await _loadFavorites();
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                if (shown.isNotEmpty)
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
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
                                child: CachedNetworkImage(
                                  imageUrl: p.gridThumbUrl.isNotEmpty
                                      ? p.gridThumbUrl
                                      : (p.thumbUrl.isNotEmpty ? p.thumbUrl : p.url),
                                  fit: BoxFit.cover,
                                  fadeInDuration: Duration.zero,
                                  placeholderFadeInDuration: Duration.zero,
                                  errorWidget: (_, __, ___) => Container(color: AppTheme.surfaceElevated),
                                  placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
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
                                  color: AppTheme.bgDeep.withOpacity(0.72),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      p.likedByMe ? Icons.favorite : Icons.favorite_border,
                                      color: p.likedByMe ? AppTheme.pink : AppTheme.textPrimary,
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
                                  color: AppTheme.bgDeep.withOpacity(0.72),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                                ),
                                child: Icon(
                                  fav ? Icons.star : Icons.star_border,
                                  color: fav ? AppTheme.amber : AppTheme.textPrimary,
                                  size: 18,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                if (!_showFavoritesOnly && totalPages > 1) ...[
                  const SizedBox(height: 14),
                  Center(
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: List.generate(
                        totalPages,
                        (index) {
                          final pageNum = index + 1;
                          final selected = pageNum == feed.page;
                          return OutlinedButton(
                            onPressed: selected
                                ? null
                                : () {
                                    setState(() {
                                      _currentPage = pageNum;
                                      _photosFuture = _fetchPhotos(page: pageNum);
                                    });
                                  },
                            style: OutlinedButton.styleFrom(
                              backgroundColor:
                                  selected ? AppTheme.violet : Colors.transparent,
                            ),
                            child: Text(
                              '$pageNum',
                              style: TextStyle(color: selected ? AppTheme.textPrimary : null),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ],
            ),
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
  late final TransformationController _transformController;
  int _index = 0;
  List<_FavoritePhoto> _favorites = [];
  late List<_Photo> _photos;
  TapDownDetails? _doubleTapDetails;
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
    _transformController = TransformationController();
    _loadFavorites();
    WidgetsBinding.instance.addPostFrameCallback((_) => _warmViewerImages(_index));
  }

  void _resetZoom() {
    _transformController.value = Matrix4.identity();
  }

  void _toggleZoom() {
    final details = _doubleTapDetails;
    if (details == null) return;
    final current = _transformController.value;
    if (!current.isIdentity()) {
      _resetZoom();
      return;
    }

    const scale = 2.5;
    final position = details.localPosition;
    final x = -position.dx * (scale - 1);
    final y = -position.dy * (scale - 1);

    _transformController.value = Matrix4.identity()
      ..translate(x, y)
      ..scale(scale);
  }

  void _warmViewerImages(int index) {
    if (!mounted || _photos.isEmpty) return;
    for (final neighbor in [index - 1, index, index + 1]) {
      if (neighbor < 0 || neighbor >= _photos.length) continue;
      final photo = _photos[neighbor];
      final url = photo.viewerUrl.isNotEmpty ? photo.viewerUrl : photo.url;
      if (url.isEmpty) continue;
      precacheImage(CachedNetworkImageProvider(url), context);
    }
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
        SnackBar(content: Text(saved ? I18n.t('photo_saved_to_gallery') : I18n.t('cannot_open_download'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('cannot_open_download')} (${e.runtimeType})')),
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
    _transformController.dispose();
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
                onPageChanged: (v) {
                  setState(() => _index = v);
                  _resetZoom();
                  _warmViewerImages(v);
                },
                itemBuilder: (context, i) {
                  final p = _photos[i];
                  return GestureDetector(
                    onDoubleTapDown: (details) => _doubleTapDetails = details,
                    onDoubleTap: _toggleZoom,
                    child: InteractiveViewer(
                      transformationController: _transformController,
                      minScale: 1,
                      maxScale: 4,
                      child: Center(
                        child: CachedNetworkImage(
                          imageUrl: p.viewerUrl.isNotEmpty ? p.viewerUrl : p.url,
                          fit: BoxFit.contain,
                          fadeInDuration: Duration.zero,
                          placeholderFadeInDuration: Duration.zero,
                          errorWidget: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                          placeholder: (_, __) => Container(color: const Color(0xFF111827)),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: AppTheme.bgDeep.withOpacity(0.96),
                border: Border(top: BorderSide(color: Colors.white.withOpacity(0.06))),
              ),
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: EdgeInsets.only(bottom: 10),
                    child: Text(
                      '${I18n.t('download_full_resolution_notice')}\n${I18n.t('download_contact_notice')}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _iconAction(
                        onTap: () => _togglePhotoLike(photo),
                        tooltip: '${I18n.t('like')} (${photo.likeCount})',
                        icon: photo.likedByMe ? Icons.favorite : Icons.favorite_border,
                        color: photo.likedByMe ? AppTheme.pink : AppTheme.textPrimary,
                      ),
                      _iconAction(
                        onTap: () => _toggleFavorite(photo),
                        tooltip: fav ? I18n.t('remove_from_favorites') : I18n.t('add_to_favorites'),
                        icon: fav ? Icons.star : Icons.star_border,
                        color: fav ? AppTheme.amber : AppTheme.textPrimary,
                      ),
                      _iconAction(
                        onTap: () => _download(photo.url),
                        tooltip: I18n.t('download'),
                        icon: Icons.download,
                        color: AppTheme.cyan,
                      ),
                    ],
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
            color: AppTheme.surfaceSecondary,
            border: Border.all(color: color.withOpacity(0.28)),
            boxShadow: [
              BoxShadow(
                color: color.withOpacity(0.18),
                blurRadius: 14,
                offset: const Offset(0, 8),
              ),
            ],
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
      borderRadius: BorderRadius.circular(22),
      child: Container(
        decoration: AppTheme.panel(tone: AppTone.photos, radius: 22, elevated: true),
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
                      errorBuilder: (_, __, ___) => Container(color: AppTheme.surfaceElevated),
                    )
                  : Container(color: AppTheme.surfaceElevated),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: AppTheme.cyan.withOpacity(0.16),
                    ),
                    child: Text(
                      album.albumType == 'top_liked' ? 'Trend' : 'Albüm',
                      style: const TextStyle(
                        color: AppTheme.cyan,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    album.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              child: Text(
                '${album.photoCount} fotoğraf  ·  ${album.createdAt}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onLikeTap,
                      icon: Icon(
                        liked ? Icons.favorite : Icons.favorite_border,
                        color: liked ? AppTheme.pink : AppTheme.textPrimary,
                        size: 18,
                      ),
                      label: Text('${I18n.t('like')} (${album.likeCount})'),
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
                child: CachedNetworkImage(
                  imageUrl: photo.gridThumbUrl.isNotEmpty
                      ? photo.gridThumbUrl
                      : (photo.thumbUrl.isNotEmpty ? photo.thumbUrl : photo.url),
                  fit: BoxFit.cover,
                  fadeInDuration: Duration.zero,
                  placeholderFadeInDuration: Duration.zero,
                  errorWidget: (_, __, ___) => Container(color: AppTheme.surfaceElevated),
                  placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
                ),
              ),
              Positioned(
                left: 6,
                right: 6,
                bottom: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                  decoration: BoxDecoration(
                    color: AppTheme.bgDeep.withOpacity(0.72),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.favorite, size: 14, color: AppTheme.pink),
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
      return _InfoCard(text: I18n.t('no_favorite_photo'));
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
                  child: CachedNetworkImage(
                    imageUrl: p.thumbUrl.isNotEmpty ? p.thumbUrl : p.url,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    placeholderFadeInDuration: Duration.zero,
                    errorWidget: (_, __, ___) => Container(color: AppTheme.surfaceElevated),
                    placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
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
                  color: AppTheme.bgDeep.withOpacity(0.72),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: const Icon(Icons.favorite, color: AppTheme.pink, size: 18),
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
  final String albumType;
  final String coverUrl;
  final String coverThumbUrl;
  final String createdAt;
  final int photoCount;
  final int likeCount;
  final bool likedByMe;

  const _Album({
    required this.slug,
    required this.name,
    required this.albumType,
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
      albumType: (json['album_type'] ?? 'event').toString(),
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
  final String gridThumbUrl;
  final String viewerUrl;
  final String createdAt;
  final int likeCount;
  final bool likedByMe;

  const _Photo({
    required this.id,
    required this.url,
    required this.thumbUrl,
    required this.gridThumbUrl,
    required this.viewerUrl,
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
    final gridThumb = _absUrl(
      json['grid_thumb_url'] ?? json['small_thumb_url'] ?? json['thumb_small_url'] ?? thumb,
    );
    final viewerUrl = _absUrl(
      json['viewer_url'] ?? json['large_thumb_url'] ?? json['preview_large_url'] ?? url,
    );
    return _Photo(
      id: (json['id'] as num?)?.toInt() ?? 0,
      url: url,
      thumbUrl: thumb,
      gridThumbUrl: gridThumb,
      viewerUrl: viewerUrl,
      createdAt: _fmtDate((json['created_at'] ?? json['date'] ?? '').toString()),
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      likedByMe: json['liked_by_me'] == true,
    );
  }

  _Photo copyWith({
    int? id,
    String? url,
    String? thumbUrl,
    String? gridThumbUrl,
    String? viewerUrl,
    String? createdAt,
    int? likeCount,
    bool? likedByMe,
  }) {
    return _Photo(
      id: id ?? this.id,
      url: url ?? this.url,
      thumbUrl: thumbUrl ?? this.thumbUrl,
      gridThumbUrl: gridThumbUrl ?? this.gridThumbUrl,
      viewerUrl: viewerUrl ?? this.viewerUrl,
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
        SnackBar(content: Text(saved ? I18n.t('photo_saved_to_gallery') : I18n.t('cannot_open_download'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('cannot_open_download')} (${e.runtimeType})')),
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
                      label: Text(fav ? I18n.t('liked') : I18n.t('like')),
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
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.photos, radius: 18, subtle: true),
      child: Text(text, style: const TextStyle(color: AppTheme.textSecondary)),
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
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.photos, radius: 18, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
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
      decoration: AppTheme.panel(tone: AppTone.danger, radius: 18, subtle: true),
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
