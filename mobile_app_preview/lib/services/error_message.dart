import 'dart:convert';

String sanitizeErrorText(
  String raw, {
  required String fallback,
}) {
  var text = raw.trim();
  if (text.isEmpty) return fallback;

  text = text
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '• ')
      .replaceAll(RegExp(r'<[^>]+>'), ' ');

  const entities = <String, String>{
    '&nbsp;': ' ',
    '&amp;': '&',
    '&quot;': '"',
    '&#34;': '"',
    '&#39;': "'",
    '&#039;': "'",
    '&apos;': "'",
    '&lt;': '<',
    '&gt;': '>',
  };
  for (final entry in entities.entries) {
    text = text.replaceAll(entry.key, entry.value);
  }

  text = text.replaceAll(RegExp(r'https?://\S+'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();

  final lower = text.toLowerCase();
  if (lower.contains('kullanıcı adı veya parola yanlış') ||
      lower.contains('yazdığınız kullanıcı adı veya parola yanlış') ||
      lower.contains('incorrect username or password') ||
      lower.contains('incorrect password')) {
    return 'E-posta veya şifre yanlış.';
  }

  text = text
      .replaceAll(RegExp(r'^hata\s*:\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'^error\s*:\s*', caseSensitive: false), '')
      .replaceAll(RegExp(r'parolanızı unuttunuz mu\??', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+([,.:;!?])'), r'$1')
      .trim();

  return text.isEmpty ? fallback : text;
}

String parseApiErrorBody(
  String body, {
  required String fallback,
}) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) {
      final detail = decoded['detail'];
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map<String, dynamic>) {
          final candidate = (first['msg'] ?? first['message'] ?? fallback).toString();
          return sanitizeErrorText(candidate, fallback: fallback);
        }
        return sanitizeErrorText(first.toString(), fallback: fallback);
      }
      final candidate = (detail ?? decoded['message'] ?? decoded['error'] ?? fallback).toString();
      return sanitizeErrorText(candidate, fallback: fallback);
    }
    if (decoded is List && decoded.isNotEmpty) {
      return sanitizeErrorText(decoded.first.toString(), fallback: fallback);
    }
  } catch (_) {}
  return sanitizeErrorText(body, fallback: fallback);
}
