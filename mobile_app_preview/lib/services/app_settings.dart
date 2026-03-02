import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kLanguage = 'settings.language';
  static final ValueNotifier<String> language = ValueNotifier<String>('tr');

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    language.value = prefs.getString(_kLanguage) ?? 'tr';
  }

  static Future<void> setLanguage(String value) async {
    final v = value.trim().toLowerCase() == 'en' ? 'en' : 'tr';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLanguage, v);
    language.value = v;
  }
}

