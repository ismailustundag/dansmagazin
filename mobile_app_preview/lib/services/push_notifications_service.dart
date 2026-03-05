import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'notifications_api.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (_) {}
}

class PushNotificationsService {
  static bool _firebaseReady = false;
  static bool _listenersBound = false;
  static String _sessionToken = '';
  static StreamSubscription<String>? _tokenRefreshSub;

  static Future<bool> _ensureFirebaseReady() async {
    if (_firebaseReady) return true;
    try {
      await Firebase.initializeApp();
      _firebaseReady = true;
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
      return true;
    } catch (_) {
      _firebaseReady = false;
      return false;
    }
  }

  static String _platformName() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return 'unknown';
    }
  }

  static Future<void> initForSession(
    String sessionToken, {
    bool notificationsEnabled = true,
  }) async {
    final token = sessionToken.trim();
    if (token.isEmpty) return;
    _sessionToken = token;

    final ready = await _ensureFirebaseReady();
    if (!ready) return;

    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission(
      alert: true,
      announcement: false,
      badge: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
      sound: true,
    );

    final isGranted =
        settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;

    if (!isGranted || !notificationsEnabled) {
      try {
        await NotificationsApi.unregisterPushToken(token);
      } catch (_) {}
      return;
    }

    try {
      await messaging.setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {}

    final currentToken = await messaging.getToken();
    if (currentToken != null && currentToken.trim().isNotEmpty) {
      try {
        await NotificationsApi.registerPushToken(
          token,
          deviceToken: currentToken,
          platform: _platformName(),
          notificationsEnabled: true,
        );
      } catch (_) {}
    }

    if (!_listenersBound) {
      _tokenRefreshSub = messaging.onTokenRefresh.listen((newToken) async {
        final t = _sessionToken.trim();
        if (t.isEmpty || newToken.trim().isEmpty) return;
        try {
          await NotificationsApi.registerPushToken(
            t,
            deviceToken: newToken,
            platform: _platformName(),
            notificationsEnabled: true,
          );
        } catch (_) {}
      });
      _listenersBound = true;
    }
  }

  static Future<void> syncPreference(String sessionToken, bool enabled) async {
    final token = sessionToken.trim();
    if (token.isEmpty) return;
    if (!enabled) {
      try {
        await NotificationsApi.unregisterPushToken(token);
      } catch (_) {}
      return;
    }
    await initForSession(token, notificationsEnabled: true);
  }

  static Future<void> unregisterForSession(String sessionToken) async {
    final token = sessionToken.trim();
    if (token.isEmpty) return;
    try {
      await NotificationsApi.unregisterPushToken(token);
    } catch (_) {}
  }

  static Future<void> dispose() async {
    _sessionToken = '';
    await _tokenRefreshSub?.cancel();
    _tokenRefreshSub = null;
    _listenersBound = false;
  }
}
