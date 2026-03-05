import 'dart:convert';

import 'package:http/http.dart' as http;

class NotificationSummary {
  final int totalCount;
  final int incomingFriendRequestsCount;
  final int unreadMessagesCount;

  const NotificationSummary({
    required this.totalCount,
    required this.incomingFriendRequestsCount,
    required this.unreadMessagesCount,
  });

  factory NotificationSummary.fromJson(Map<String, dynamic> json) {
    return NotificationSummary(
      totalCount: (json['total_count'] as num?)?.toInt() ?? 0,
      incomingFriendRequestsCount: (json['incoming_friend_requests_count'] as num?)?.toInt() ?? 0,
      unreadMessagesCount: (json['unread_messages_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class NotificationFeedItem {
  final int id;
  final String title;
  final String body;
  final String type;
  final String createdAt;
  final int? sentByAccountId;
  final String sentByName;

  const NotificationFeedItem({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    required this.createdAt,
    required this.sentByAccountId,
    required this.sentByName,
  });

  factory NotificationFeedItem.fromJson(Map<String, dynamic> json) {
    return NotificationFeedItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      type: (json['type'] ?? 'manual').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
      sentByAccountId: (json['sent_by_account_id'] as num?)?.toInt(),
      sentByName: (json['sent_by_name'] ?? '').toString(),
    );
  }
}

class NotificationUserCandidate {
  final int accountId;
  final String name;
  final String email;

  const NotificationUserCandidate({
    required this.accountId,
    required this.name,
    required this.email,
  });

  factory NotificationUserCandidate.fromJson(Map<String, dynamic> json) {
    return NotificationUserCandidate(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
    );
  }
}

class NotificationsApi {
  static const _base = 'https://api2.dansmagazin.net';

  static Future<NotificationSummary> fetchSummary(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/notifications'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Bildirimler alınamadı');
    }
    return NotificationSummary.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<List<NotificationFeedItem>> fetchFeed(
    String sessionToken, {
    int limit = 50,
  }) async {
    final lim = limit < 1 ? 1 : (limit > 200 ? 200 : limit);
    final resp = await http.get(
      Uri.parse('$_base/profile/notifications/feed?limit=$lim'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Bildirim listesi alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(NotificationFeedItem.fromJson)
        .toList();
  }

  static Future<void> clearFeed(String sessionToken) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/notifications/feed'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Bildirimler temizlenemedi'));
    }
  }

  static Future<List<NotificationFeedItem>> fetchSent(
    String sessionToken, {
    int limit = 200,
  }) async {
    final lim = limit < 1 ? 1 : (limit > 1000 ? 1000 : limit);
    final resp = await http.get(
      Uri.parse('$_base/profile/notifications/sent?limit=$lim'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Gönderilen bildirimler alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(NotificationFeedItem.fromJson)
        .toList();
  }

  static Future<List<NotificationUserCandidate>> searchUsers(
    String sessionToken, {
    String query = '',
    int limit = 100,
  }) async {
    final q = query.trim();
    final lim = limit < 1 ? 1 : (limit > 100 ? 100 : limit);
    final resp = await http.get(
      Uri.parse('$_base/profile/users/search?q=${Uri.encodeQueryComponent(q)}&limit=$lim'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Kullanıcılar alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(NotificationUserCandidate.fromJson)
        .toList();
  }

  static Future<int> sendNotification(
    String sessionToken, {
    required String title,
    required String body,
    required bool sendToAll,
    List<int> targetAccountIds = const [],
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/notifications/send'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'title': title.trim(),
        'body': body.trim(),
        'send_to_all': sendToAll,
        'target_account_ids': targetAccountIds,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Bildirim gönderilemedi'));
    }
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    return (data['sent_count'] as num?)?.toInt() ?? 0;
  }


  static Future<void> registerPushToken(
    String sessionToken, {
    required String deviceToken,
    required String platform,
    bool notificationsEnabled = true,
    String appVersion = '',
    String deviceModel = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/push/register'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'device_token': deviceToken.trim(),
        'platform': platform.trim(),
        'notifications_enabled': notificationsEnabled,
        'app_version': appVersion,
        'device_model': deviceModel,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Push kayıt yapılamadı'));
    }
  }

  static Future<void> unregisterPushToken(
    String sessionToken, {
    String? deviceToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/push/unregister'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'device_token': (deviceToken ?? '').trim().isEmpty ? null : deviceToken!.trim(),
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Push kaydı kaldırılamadı'));
    }
  }

  static String _parseError(String body, {required String fallback}) {
    try {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) {
        final detail = j['detail'];
        if (detail is List && detail.isNotEmpty) {
          final first = detail.first;
          if (first is Map<String, dynamic>) {
            return (first['msg'] ?? first['message'] ?? fallback).toString();
          }
          return first.toString();
        }
        return (detail ?? j['message'] ?? fallback).toString();
      }
    } catch (_) {}
    return fallback;
  }
}
