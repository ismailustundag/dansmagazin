import 'dart:convert';

import 'package:http/http.dart' as http;

class ProfileSettingsData {
  final String username;
  final String email;
  final String language;
  final bool notificationsEnabled;
  final String avatarUrl;

  const ProfileSettingsData({
    required this.username,
    required this.email,
    required this.language,
    required this.notificationsEnabled,
    required this.avatarUrl,
  });

  factory ProfileSettingsData.fromJson(Map<String, dynamic> json) {
    return ProfileSettingsData(
      username: (json['username'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      language: (json['language'] ?? 'tr').toString(),
      notificationsEnabled: json['notifications_enabled'] == true,
      avatarUrl: (json['avatar_url'] ?? '').toString(),
    );
  }
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
    String? language,
    bool? notificationsEnabled,
    String? avatarUrl,
  }) async {
    final body = <String, dynamic>{};
    if (username != null) body['username'] = username;
    if (language != null) body['language'] = language;
    if (notificationsEnabled != null) body['notifications_enabled'] = notificationsEnabled;
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
}
