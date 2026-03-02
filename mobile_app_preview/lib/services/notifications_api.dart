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
}

