import 'dart:convert';

import 'package:http/http.dart' as http;

class PhotoFlowReply {
  final int id;
  final int postId;
  final int accountId;
  final String body;
  final String createdAt;
  final String authorName;
  final bool authorIsVerified;
  final String authorAvatarUrl;

  const PhotoFlowReply({
    required this.id,
    required this.postId,
    required this.accountId,
    required this.body,
    required this.createdAt,
    required this.authorName,
    required this.authorIsVerified,
    required this.authorAvatarUrl,
  });

  factory PhotoFlowReply.fromJson(Map<String, dynamic> json) {
    return PhotoFlowReply(
      id: (json['id'] as num?)?.toInt() ?? 0,
      postId: (json['post_id'] as num?)?.toInt() ?? 0,
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      body: (json['body'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
      authorName: (json['author_name'] ?? '').toString(),
      authorIsVerified: json['author_is_verified'] == true,
      authorAvatarUrl: (json['author_avatar_url'] ?? '').toString(),
    );
  }
}

class PhotoFlowPost {
  final int id;
  final int accountId;
  final String body;
  final String imageUrl;
  final String imageThumbUrl;
  final int likeCount;
  final int replyCount;
  final bool likedByMe;
  final String createdAt;
  final String authorName;
  final bool authorIsVerified;
  final String authorAvatarUrl;
  final List<PhotoFlowReply> replies;

  const PhotoFlowPost({
    required this.id,
    required this.accountId,
    required this.body,
    required this.imageUrl,
    required this.imageThumbUrl,
    required this.likeCount,
    required this.replyCount,
    required this.likedByMe,
    required this.createdAt,
    required this.authorName,
    required this.authorIsVerified,
    required this.authorAvatarUrl,
    required this.replies,
  });

  factory PhotoFlowPost.fromJson(Map<String, dynamic> json) {
    final replies = (json['replies'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PhotoFlowReply.fromJson)
        .toList();
    return PhotoFlowPost(
      id: (json['id'] as num?)?.toInt() ?? 0,
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      body: (json['body'] ?? '').toString(),
      imageUrl: (json['image_url'] ?? '').toString(),
      imageThumbUrl: (json['image_thumb_url'] ?? '').toString(),
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      replyCount: (json['reply_count'] as num?)?.toInt() ?? 0,
      likedByMe: json['liked_by_me'] == true,
      createdAt: (json['created_at'] ?? '').toString(),
      authorName: (json['author_name'] ?? '').toString(),
      authorIsVerified: json['author_is_verified'] == true,
      authorAvatarUrl: (json['author_avatar_url'] ?? '').toString(),
      replies: replies,
    );
  }
}

class PhotoFlowApi {
  static const String _base = 'https://api2.dansmagazin.net/photos/feed';

  static Map<String, String> _headers(String sessionToken, {bool jsonBody = false}) {
    return {
      if (sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${sessionToken.trim()}',
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }

  static String _parseError(String body, {required String fallback}) {
    try {
      final raw = jsonDecode(body);
      if (raw is Map<String, dynamic>) {
        final detail = (raw['detail'] ?? raw['message'] ?? raw['error'] ?? '').toString().trim();
        if (detail.isNotEmpty) return detail;
      }
    } catch (_) {}
    return fallback;
  }

  static Future<List<PhotoFlowPost>> fetch({
    String sessionToken = '',
    int limit = 30,
    int offset = 0,
  }) async {
    final uri = Uri.parse(_base).replace(queryParameters: {
      'limit': '$limit',
      'offset': '$offset',
    });
    final resp = await http.get(uri, headers: _headers(sessionToken));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Akış yüklenemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return (map['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PhotoFlowPost.fromJson)
        .toList();
  }

  static Future<PhotoFlowPost> createPost(
    String sessionToken, {
    required String text,
    String? imagePath,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/posts'))
      ..headers.addAll(_headers(sessionToken))
      ..fields['text'] = text;
    final path = (imagePath ?? '').trim();
    if (path.isNotEmpty) {
      req.files.add(await http.MultipartFile.fromPath('image', path));
    }
    final streamed = await req.send();
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Gönderi paylaşılamadı'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoFlowPost.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<PhotoFlowPost> setLike(
    String sessionToken, {
    required int postId,
    required bool like,
  }) async {
    final endpoint = like ? 'like' : 'unlike';
    final resp = await http.post(
      Uri.parse('$_base/posts/$postId/$endpoint'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Beğeni güncellenemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoFlowPost.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<PhotoFlowPost> addReply(
    String sessionToken, {
    required int postId,
    required String text,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/posts/$postId/replies'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'text': text}),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Yanıt gönderilemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoFlowPost.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }
}
