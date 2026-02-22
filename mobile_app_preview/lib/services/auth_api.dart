import 'dart:convert';

import 'package:http/http.dart' as http;

class AuthApiException implements Exception {
  final String message;
  AuthApiException(this.message);
}

bool _readBool(dynamic v) {
  if (v is bool) return v;
  if (v is num) return v.toInt() == 1;
  if (v is String) {
    final s = v.trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }
  return false;
}

class AuthSession {
  final String sessionToken;
  final String expiresAt;
  final int accountId;
  final String email;
  final String name;
  final int? wpUserId;
  final List<String> wpRoles;
  final String appRole;
  final bool canCreateMobileEvent;

  const AuthSession({
    required this.sessionToken,
    required this.expiresAt,
    required this.accountId,
    required this.email,
    required this.name,
    required this.wpUserId,
    required this.wpRoles,
    required this.appRole,
    required this.canCreateMobileEvent,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) {
    return AuthSession(
      sessionToken: (json['session_token'] ?? '').toString(),
      expiresAt: (json['expires_at'] ?? '').toString(),
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      email: (json['email'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      wpUserId: (json['wp_user_id'] as num?)?.toInt(),
      wpRoles: (json['wp_roles'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      appRole: (json['app_role'] ?? 'customer').toString(),
      canCreateMobileEvent: _readBool(json['can_create_mobile_event']),
    );
  }
}

class AuthApi {
  static const String _base = 'https://api2.dansmagazin.net';

  static Future<AuthSession> login({
    required String usernameOrEmail,
    required String password,
    required bool rememberMe,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/auth/login'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username_or_email': usernameOrEmail.trim(),
        'password': password,
        'remember_me': rememberMe,
      }),
    );
    return _parseSession(resp);
  }

  static Future<AuthSession> register({
    required String email,
    required String password,
    required String name,
    required bool rememberMe,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'password': password,
        'name': name.trim(),
        'remember_me': rememberMe,
      }),
    );
    return _parseSession(resp);
  }

  static Future<AuthSession> me(String sessionToken) async {
    final resp = await http.get(
      Uri.parse('$_base/auth/me'),
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    if (resp.statusCode != 200) {
      throw AuthApiException(_parseError(resp.body, fallback: 'Oturum geçersiz'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return AuthSession(
      sessionToken: sessionToken,
      expiresAt: '',
      accountId: (body['account_id'] as num?)?.toInt() ?? 0,
      email: (body['email'] ?? '').toString(),
      name: (body['name'] ?? '').toString(),
      wpUserId: (body['wp_user_id'] as num?)?.toInt(),
      wpRoles: (body['wp_roles'] as List<dynamic>? ?? [])
          .map((e) => e.toString())
          .toList(),
      appRole: (body['app_role'] ?? 'customer').toString(),
      canCreateMobileEvent: _readBool(body['can_create_mobile_event']),
    );
  }

  static AuthSession _parseSession(http.Response resp) {
    if (resp.statusCode != 200) {
      throw AuthApiException(_parseError(resp.body, fallback: 'Kimlik doğrulama başarısız'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final session = AuthSession.fromJson(body);
    if (session.sessionToken.isEmpty) {
      throw AuthApiException('Geçersiz oturum cevabı');
    }
    return session;
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
