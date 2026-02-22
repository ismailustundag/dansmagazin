import 'dart:convert';

import 'package:http/http.dart' as http;

class CheckoutApiException implements Exception {
  final String message;
  CheckoutApiException(this.message);
}

class CheckoutApi {
  static const String _base = 'https://api2.dansmagazin.net';

  static Future<String> buildAutoLoginUrl({
    required String sessionToken,
    required String targetUrl,
  }) async {
    final uri = Uri.parse('$_base/auth/woo-auto-login-url').replace(
      queryParameters: {'target_url': targetUrl},
    );
    final resp = await http.get(
      uri,
      headers: {'Authorization': 'Bearer $sessionToken'},
    );
    if (resp.statusCode != 200) {
      throw CheckoutApiException(_parseError(resp.body, fallback: 'Bilet sayfası açılamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final url = (body['url'] ?? '').toString().trim();
    if (url.isEmpty) {
      throw CheckoutApiException('Geçersiz checkout linki');
    }
    return url;
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
