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
}
