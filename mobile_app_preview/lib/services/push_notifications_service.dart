import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
  static bool _localReady = false;
  static String _sessionToken = '';
  static StreamSubscription<String>? _tokenRefreshSub;
  static StreamSubscription<RemoteMessage>? _onMessageSub;
  static StreamSubscription<RemoteMessage>? _onMessageOpenedSub;
  static Future<void> Function(String route)? _onRouteTap;
  static const MethodChannel _badgeChannel = MethodChannel('dansmagazin/badge');

  static const AndroidNotificationChannel _androidChannel =
      AndroidNotificationChannel(
    'dmz_general',
    'Genel Bildirimler',
    description: 'Dansmagazin bildirimleri',
    importance: Importance.max,
    playSound: true,
  );

  static final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  static Future<String?> _resolveFcmTokenWithRetry(
    FirebaseMessaging messaging,
  ) async {
    for (var i = 0; i < 4; i++) {
      final t = await messaging.getToken();
      if (t != null && t.trim().isNotEmpty) {
        return t.trim();
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    return null;
  }

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

  static Future<void> _ensureLocalReady() async {
    if (_localReady) return;

    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    );

    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (details) {
        final route = (details.payload ?? '').trim();
        if (route.isNotEmpty) {
          unawaited(_onRouteTap?.call(route));
        }
      },
    );

    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(_androidChannel);

    _localReady = true;
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

  static Future<bool> _requestPlatformNotificationPermission() async {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      // iOS izin istegi FirebaseMessaging.requestPermission ile initForSession
      // icinde yapiliyor. Burada derleme uyumlulugu icin ekstra plugin tipine
      // bagimli bir cagri yapmiyoruz.
      return true;
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      // Android 13+ icin runtime bildirim izni iste.
      final androidPlugin = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      final granted = await androidPlugin?.requestNotificationsPermission();
      return granted != false;
    }
    return true;
  }

  static Future<void> primeSystemPermissionPrompt() async {
    await _ensureLocalReady();
    await _requestPlatformNotificationPermission();
  }

  static Future<void> clearBadge() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) return;
    try {
      await _badgeChannel.invokeMethod<void>('clearBadge');
    } catch (_) {}
  }

  static Future<void> initForSession(
    String sessionToken, {
    bool notificationsEnabled = true,
    Future<void> Function(String route)? onRouteTap,
  }) async {
    final token = sessionToken.trim();
    if (token.isEmpty) return;
    _sessionToken = token;
    _onRouteTap = onRouteTap;

    await _ensureLocalReady();

    final grantedByPlatform = await _requestPlatformNotificationPermission();
    if (!grantedByPlatform || !notificationsEnabled) {
      try {
        await NotificationsApi.unregisterPushToken(token);
      } catch (_) {}
      return;
    }

    final ready = await _ensureFirebaseReady();
    if (!ready) return;

    final messaging = FirebaseMessaging.instance;
    bool isGranted = true;
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      final settings = await messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );
      isGranted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    }

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

    String? currentToken = await _resolveFcmTokenWithRetry(messaging);
    if ((currentToken ?? '').isEmpty) {
      // Token gelmiyorsa bir kez resetleyip tekrar dene.
      try {
        await messaging.deleteToken();
      } catch (_) {}
      currentToken = await _resolveFcmTokenWithRetry(messaging);
    }

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

      _onMessageSub = FirebaseMessaging.onMessage.listen((message) async {
        final n = message.notification;
        if (n == null) return;

        await _localNotifications.show(
          DateTime.now().millisecondsSinceEpoch.remainder(100000),
          n.title ?? 'Dansmagazin',
          n.body ?? '',
          NotificationDetails(
            android: AndroidNotificationDetails(
              _androidChannel.id,
              _androidChannel.name,
              channelDescription: _androidChannel.description,
              importance: Importance.max,
              priority: Priority.high,
              icon: '@mipmap/ic_launcher',
            ),
            iOS: const DarwinNotificationDetails(
              presentAlert: true,
              presentBadge: true,
              presentSound: true,
            ),
          ),
          payload: _routeFromMessage(message),
        );
      });

      _onMessageOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final route = _routeFromMessage(message);
        if (route.isNotEmpty) {
          unawaited(_onRouteTap?.call(route));
        }
      });

      unawaited(() async {
        final initial = await FirebaseMessaging.instance.getInitialMessage();
        if (initial == null) return;
        final route = _routeFromMessage(initial);
        if (route.isNotEmpty) {
          await _onRouteTap?.call(route);
        }
      }());

      _listenersBound = true;
    }
  }

  static String _routeFromMessage(RemoteMessage message) {
    final data = message.data;
    final type = (data['type'] ?? '').toString().trim().toLowerCase();
    if (type == 'message') {
      final fromId = int.tryParse((data['from_account_id'] ?? '').toString()) ?? 0;
      if (fromId > 0) {
        return '/messages/$fromId';
      }
    }
    final route = (data['route'] ?? '').toString().trim();
    if (route.isNotEmpty) return route;
    final eventId = int.tryParse((data['event_submission_id'] ?? data['event_id'] ?? '').toString()) ?? 0;
    if (eventId > 0) return '/events/$eventId';
    return '/profile/notifications';
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
    try {
      await FirebaseMessaging.instance.deleteToken();
    } catch (_) {}
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
    await _onMessageSub?.cancel();
    await _onMessageOpenedSub?.cancel();
    _tokenRefreshSub = null;
    _onMessageSub = null;
    _onMessageOpenedSub = null;
    _listenersBound = false;
    _onRouteTap = null;
  }
}
