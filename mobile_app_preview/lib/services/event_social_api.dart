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

  const EventAttendee({
    required this.accountId,
    required this.name,
    required this.isMe,
    required this.isFriend,
  });

  factory EventAttendee.fromJson(Map<String, dynamic> json) {
    return EventAttendee(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      isMe: (json['is_me'] == true),
      isFriend: (json['is_friend'] == true),
    );
  }
}

class EventSocialApi {
  static const String _base = 'https://api2.dansmagazin.net';

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

  static Future<void> addFriend({
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
