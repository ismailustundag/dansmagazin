import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  static const _kLanguage = 'settings.language';
  static const _kTextScale = 'settings.text_scale';
  static final ValueNotifier<String> language =
      ValueNotifier<String>(_deviceLanguage());
  static final ValueNotifier<double> textScale = ValueNotifier<double>(1.0);

  static String _deviceLanguage() {
    final languageCode =
        PlatformDispatcher.instance.locale.languageCode.toLowerCase();
    return languageCode == 'en' || languageCode == 'es' ? languageCode : 'tr';
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    language.value = prefs.getString(_kLanguage) ?? _deviceLanguage();
    final rawScale = prefs.getDouble(_kTextScale) ?? 1.0;
    textScale.value = rawScale.clamp(0.90, 1.35).toDouble();
  }

  static Future<void> setLanguage(String value) async {
    final raw = value.trim().toLowerCase();
    final v = raw == 'en' || raw == 'es' ? raw : 'tr';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLanguage, v);
    language.value = v;
  }

  static Future<void> setTextScale(double value) async {
    final v = value.clamp(0.90, 1.35).toDouble();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTextScale, v);
    textScale.value = v;
  }
}
