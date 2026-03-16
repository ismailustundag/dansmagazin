import 'dart:convert';

import 'package:http/http.dart' as http;

class ProfileSettingsData {
  final int accountId;
  final String username;
  final String email;
  final String city;
  final String birthDate;
  final String danceInterests;
  final String danceSchool;
  final String about;
  final String registeredAt;
  final String language;
  final bool notificationsEnabled;
  final Map<String, bool> notificationPreferences;
  final String avatarUrl;

  const ProfileSettingsData({
    required this.accountId,
    required this.username,
    required this.email,
    required this.city,
    required this.birthDate,
    required this.danceInterests,
    required this.danceSchool,
    required this.about,
    required this.registeredAt,
    required this.language,
    required this.notificationsEnabled,
    required this.notificationPreferences,
    required this.avatarUrl,
  });

  static Map<String, bool> _parseNotificationPreferences(Map<String, dynamic> json) {
    const defaults = <String, bool>{
      'news': true,
      'dance_night': true,
      'festival': true,
      'competition': true,
      'promo_lesson': true,
      'system': true,
    };
    final raw = json['notification_preferences'];
    if (raw is! Map) return Map<String, bool>.from(defaults);
    final out = Map<String, bool>.from(defaults);
    for (final key in defaults.keys) {
      if (raw.containsKey(key)) {
        out[key] = raw[key] == true;
      }
    }
    return out;
  }

  factory ProfileSettingsData.fromJson(Map<String, dynamic> json) {
    return ProfileSettingsData(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      username: (json['username'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      birthDate: (json['birth_date'] ?? '').toString(),
      danceInterests: (json['dance_interests'] ?? '').toString(),
      danceSchool: (json['dance_school'] ?? '').toString(),
      about: (json['about'] ?? '').toString(),
      registeredAt: (json['registered_at'] ?? '').toString(),
      language: (json['language'] ?? 'tr').toString(),
      notificationsEnabled: json['notifications_enabled'] == true,
      notificationPreferences: _parseNotificationPreferences(json),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
    );
  }
}

class SupportContact {
  final int accountId;
  final String name;
  final String avatarUrl;

  const SupportContact({
    required this.accountId,
    required this.name,
    required this.avatarUrl,
  });
}

class ProfileApi {
  static const _base = 'https://api2.dansmagazin.net';

  static Future<ProfileSettingsData> settings(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/settings'),
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Ayarlar yüklenemedi (${resp.statusCode})');
    }
    return ProfileSettingsData.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<ProfileSettingsData> updateSettings({
    required String sessionToken,
    String? username,
    String? city,
    String? birthDate,
    String? danceInterests,
    String? danceSchool,
    String? about,
    String? language,
    bool? notificationsEnabled,
    Map<String, bool>? notificationPreferences,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (city != null) body['city'] = city;
    if (birthDate != null) body['birth_date'] = birthDate;
    if (danceInterests != null) body['dance_interests'] = danceInterests;
    if (danceSchool != null) body['dance_school'] = danceSchool;
    if (about != null) body['about'] = about;
    if (language != null) body['language'] = language;
    if (notificationsEnabled != null) body['notifications_enabled'] = notificationsEnabled;
    if (notificationPreferences != null) body['notification_preferences'] = notificationPreferences;
    if (avatarUrl != null) body['avatar_url'] = avatarUrl;
    final resp = await http.put(
      Uri.parse('$_base/profile/settings'),
      headers: {
        'Authorization': 'Bearer $sessionToken',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );
    if (resp.statusCode != 200) {
      String detail = 'Ayarlar kaydedilemedi';
      try {
        detail = (jsonDecode(resp.body) as Map<String, dynamic>)['detail']?.toString() ?? detail;
      } catch (_) {}
      throw Exception(detail);
    }
    return ProfileSettingsData.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  static Future<String> uploadAvatar({
    required String sessionToken,
    required String filePath,
  }) async {
    final req = http.MultipartRequest('POST', Uri.parse('$_base/profile/avatar-upload'))
      ..headers['Authorization'] = 'Bearer $sessionToken'
      ..files.add(await http.MultipartFile.fromPath('file', filePath));
    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      String detail = 'Profil fotoğrafı yüklenemedi';
      try {
        detail = (jsonDecode(body) as Map<String, dynamic>)['detail']?.toString() ?? detail;
      } catch (_) {}
      throw Exception(detail);
    }
    final j = jsonDecode(body) as Map<String, dynamic>;
    return (j['avatar_url'] ?? '').toString();
  }

  static Future<void> deleteAccount(String sessionToken) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/account'),
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    if (resp.statusCode == 200) return;
    String detail = 'Hesap silinemedi';
    try {
      detail = (jsonDecode(resp.body) as Map<String, dynamic>)['detail']?.toString() ?? detail;
    } catch (_) {}
    throw Exception(detail);
  }

  static Future<SupportContact?> supportContact(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/friends?limit=400'),
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Destek hesabı alınamadı (${resp.statusCode})');
    }

    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (body['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();

    SupportContact? byName;
    SupportContact? byFallbackId;
    for (final item in items) {
      final accountId = (item['account_id'] as num?)?.toInt() ?? 0;
      if (accountId <= 0) continue;
      final name = (item['name'] ?? '').toString().trim();
      final email = (item['email'] ?? '').toString().trim().toLowerCase();
      final avatarUrl = (item['avatar_url'] ?? '').toString().trim();
      final contact = SupportContact(
        accountId: accountId,
        name: name.isEmpty ? 'Dansmagazin' : name,
        avatarUrl: avatarUrl,
      );

      if (email == 'info@dansmagazin.net') {
        return contact;
      }
      final normName = name.toLowerCase();
      if (byName == null && normName.contains('dans') && normName.contains('magazin')) {
        byName = contact;
      }
      if (byFallbackId == null && accountId == 164) {
        byFallbackId = contact;
      }
    }
    return byName ?? byFallbackId;
  }
}
