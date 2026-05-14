import 'dart:convert';

import 'package:http/http.dart' as http;

import 'error_message.dart';

class GuestListApiException implements Exception {
  final String message;
  GuestListApiException(this.message);

  @override
  String toString() => message;
}

class GuestListSummary {
  final int guestListId;
  final String name;
  final int memberCount;
  final String createdAt;
  final String updatedAt;

  const GuestListSummary({
    required this.guestListId,
    required this.name,
    required this.memberCount,
    required this.createdAt,
    required this.updatedAt,
  });

  factory GuestListSummary.fromJson(Map<String, dynamic> json) {
    return GuestListSummary(
      guestListId: (json['guest_list_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      createdAt: (json['created_at'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? '').toString(),
    );
  }
}

class GuestListMember {
  final int accountId;
  final String name;
  final String email;
  final String avatarUrl;
  final bool isVerified;
  final String addedAt;

  const GuestListMember({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.isVerified,
    required this.addedAt,
  });

  factory GuestListMember.fromJson(Map<String, dynamic> json) {
    return GuestListMember(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
      addedAt: (json['added_at'] ?? '').toString(),
    );
  }
}

class GuestListDetail {
  final GuestListSummary summary;
  final List<GuestListMember> members;

  const GuestListDetail({
    required this.summary,
    required this.members,
  });

  factory GuestListDetail.fromJson(Map<String, dynamic> json) {
    return GuestListDetail(
      summary: GuestListSummary.fromJson(json),
      members: (json['members'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(GuestListMember.fromJson)
          .toList(),
    );
  }
}

class EventInvitee {
  final int accountId;
  final String name;
  final String email;
  final String avatarUrl;
  final bool isVerified;
  final int? sourceGuestListId;
  final String sourceGuestListName;
  final int? ticketId;
  final String invitedAt;

  const EventInvitee({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.isVerified,
    required this.sourceGuestListId,
    required this.sourceGuestListName,
    required this.ticketId,
    required this.invitedAt,
  });

  factory EventInvitee.fromJson(Map<String, dynamic> json) {
    return EventInvitee(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
      sourceGuestListId: (json['source_guest_list_id'] as num?)?.toInt(),
      sourceGuestListName: (json['source_guest_list_name'] ?? '').toString(),
      ticketId: (json['ticket_id'] as num?)?.toInt(),
      invitedAt: (json['invited_at'] ?? '').toString(),
    );
  }
}

class EventInviteesResult {
  final int submissionId;
  final String eventName;
  final int total;
  final List<EventInvitee> items;

  const EventInviteesResult({
    required this.submissionId,
    required this.eventName,
    required this.total,
    required this.items,
  });

  factory EventInviteesResult.fromJson(Map<String, dynamic> json) {
    return EventInviteesResult(
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      eventName: (json['event_name'] ?? '').toString(),
      total: (json['total'] as num?)?.toInt() ?? 0,
      items: (json['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(EventInvitee.fromJson)
          .toList(),
    );
  }
}

class GuestListImportResult extends EventInviteesResult {
  final int guestListId;
  final String guestListName;
  final int importedCount;
  final int existingCount;
  final int ticketCreatedCount;

  const GuestListImportResult({
    required super.submissionId,
    required super.eventName,
    required super.total,
    required super.items,
    required this.guestListId,
    required this.guestListName,
    required this.importedCount,
    required this.existingCount,
    required this.ticketCreatedCount,
  });

  factory GuestListImportResult.fromJson(Map<String, dynamic> json) {
    final base = EventInviteesResult.fromJson(json);
    return GuestListImportResult(
      submissionId: base.submissionId,
      eventName: base.eventName,
      total: base.total,
      items: base.items,
      guestListId: (json['guest_list_id'] as num?)?.toInt() ?? 0,
      guestListName: (json['guest_list_name'] ?? '').toString(),
      importedCount: (json['imported_count'] as num?)?.toInt() ?? 0,
      existingCount: (json['existing_count'] as num?)?.toInt() ?? 0,
      ticketCreatedCount: (json['ticket_created_count'] as num?)?.toInt() ?? 0,
    );
  }
}

class GuestListApi {
  static const _base = 'https://api2.dansmagazin.net';

  static Map<String, String> _headers(String sessionToken, {bool jsonBody = false}) {
    return <String, String>{
      'Authorization': 'Bearer ${sessionToken.trim()}',
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }

  static Future<List<GuestListSummary>> listGuestLists(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/guest-lists'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli listeleri alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(GuestListSummary.fromJson)
        .toList();
  }

  static Future<GuestListDetail> createGuestList({
    required String sessionToken,
    required String name,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/guest-lists'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'name': name.trim()}),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli listesi oluşturulamadı'));
    }
    return GuestListDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<GuestListDetail> guestListDetail({
    required String sessionToken,
    required int guestListId,
  }) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/guest-lists/$guestListId'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli listesi alınamadı'));
    }
    return GuestListDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<GuestListDetail> renameGuestList({
    required String sessionToken,
    required int guestListId,
    required String name,
  }) async {
    final resp = await http.patch(
      Uri.parse('$_base/profile/guest-lists/$guestListId'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'name': name.trim()}),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli listesi güncellenemedi'));
    }
    return GuestListDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<void> deleteGuestList({
    required String sessionToken,
    required int guestListId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/guest-lists/$guestListId'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli listesi silinemedi'));
    }
  }

  static Future<GuestListDetail> addMember({
    required String sessionToken,
    required int guestListId,
    required int accountId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/guest-lists/$guestListId/members'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'account_id': accountId}),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Kullanıcı listeye eklenemedi'));
    }
    return GuestListDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<GuestListDetail> removeMember({
    required String sessionToken,
    required int guestListId,
    required int accountId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/guest-lists/$guestListId/members/$accountId'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Kullanıcı listeden çıkarılamadı'));
    }
    return GuestListDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<EventInviteesResult> eventInvitees({
    required String sessionToken,
    required int submissionId,
  }) async {
    final resp = await http.get(
      Uri.parse('$_base/events/manage/items/$submissionId/invitees'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Etkinlik davetlileri alınamadı'));
    }
    return EventInviteesResult.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<GuestListImportResult> importGuestListToEvent({
    required String sessionToken,
    required int submissionId,
    required int guestListId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/manage/items/$submissionId/invitees/import-guest-list'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'guest_list_id': guestListId}),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli listesi etkinliğe aktarılamadı'));
    }
    return GuestListImportResult.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<EventInviteesResult> removeEventInvitee({
    required String sessionToken,
    required int submissionId,
    required int accountId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/events/manage/items/$submissionId/invitees/$accountId'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw GuestListApiException(parseApiErrorBody(resp.body, fallback: 'Davetli kaldırılamadı'));
    }
    return EventInviteesResult.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }
}
