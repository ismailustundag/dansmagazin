import 'dart:convert';

import 'package:http/http.dart' as http;

class EventSocialApiException implements Exception {
  final String message;
  EventSocialApiException(this.message);
}

class EventAttendee {
  final int accountId;
  final String name;
  final bool isMe;
  final bool isFriend;
  final String friendStatus;
  final int? friendRequestId;

  const EventAttendee({
    required this.accountId,
    required this.name,
    required this.isMe,
    required this.isFriend,
    required this.friendStatus,
    required this.friendRequestId,
  });

  factory EventAttendee.fromJson(Map<String, dynamic> json) {
    return EventAttendee(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      isMe: (json['is_me'] == true),
      isFriend: (json['is_friend'] == true),
      friendStatus: (json['friend_status'] ?? 'none').toString(),
      friendRequestId: (json['friend_request_id'] as num?)?.toInt(),
    );
  }
}

class FriendRequestItem {
  final int requestId;
  final int peerAccountId;
  final String peerName;
  final String peerEmail;
  final String createdAt;

  const FriendRequestItem({
    required this.requestId,
    required this.peerAccountId,
    required this.peerName,
    required this.peerEmail,
    required this.createdAt,
  });

  factory FriendRequestItem.fromJson(Map<String, dynamic> json) {
    return FriendRequestItem(
      requestId: (json['request_id'] as num?)?.toInt() ?? 0,
      peerAccountId: (json['peer_account_id'] as num?)?.toInt() ?? 0,
      peerName: (json['peer_name'] ?? '').toString(),
      peerEmail: (json['peer_email'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class EventSocialApi {
  static const String _base = 'https://api2.dansmagazin.net';

  static const String statusPendingOutgoing = 'pending_outgoing';

  static Future<List<EventAttendee>> attendees({
    required int submissionId,
    String? sessionToken,
  }) async {
    final headers = <String, String>{};
    final t = (sessionToken ?? '').trim();
    if (t.isNotEmpty) headers['Authorization'] = 'Bearer $t';

    final resp = await http.get(
      Uri.parse('$_base/events/$submissionId/attendees'),
      headers: headers,
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException('Katılımcılar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => EventAttendee.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> attend({
    required int submissionId,
    required String sessionToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/$submissionId/attend'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Katılım kaydedilemedi'));
    }
  }

  static Future<void> leave({
    required int submissionId,
    required String sessionToken,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/events/$submissionId/attend'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Katılım iptal edilemedi'));
    }
  }

  static Future<Map<String, dynamic>> addFriend({
    required int submissionId,
    required int targetAccountId,
    required String sessionToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/$submissionId/attendees/$targetAccountId/friend'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Arkadaş eklenemedi'));
    }
    try {
      final body = jsonDecode(resp.body);
      if (body is Map<String, dynamic>) return body;
    } catch (_) {}
    return const {};
  }

  static Future<List<FriendRequestItem>> friendRequests({
    required String sessionToken,
    String direction = 'incoming',
  }) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/friend-requests?direction=$direction'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Arkadaşlık istekleri alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => FriendRequestItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> acceptFriendRequest({
    required String sessionToken,
    required int requestId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friend-requests/$requestId/accept'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'İstek kabul edilemedi'));
    }
  }

  static Future<void> rejectFriendRequest({
    required String sessionToken,
    required int requestId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friend-requests/$requestId/reject'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'İstek reddedilemedi'));
    }
  }

  static String _parseError(String body, {required String fallback}) {
    try {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) {
        return (j['detail'] ?? j['message'] ?? fallback).toString();
      }
    } catch (_) {}
    return fallback;
  }
}
