import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'services/auth_api.dart';
import 'services/app_settings.dart';
import 'services/i18n.dart';
import 'services/notification_center.dart';
import 'services/notifications_api.dart';
import 'services/push_notifications_service.dart';
import 'theme/app_theme.dart';
import 'screens/auth_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/event_detail_screen.dart';
import 'screens/events_store_hub_screen.dart';
import 'screens/chat_thread_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/photos_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/social_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  AppSettings.load().whenComplete(() => runApp(const DansMagazinApp()));
}

class DansMagazinApp extends StatelessWidget {
  const DansMagazinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dansmagazin',
      theme: AppTheme.buildTheme(),
      scrollBehavior: const _AppScrollBehavior(),
      home: const RootScreen(),
    );
  }
}

class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const ClampingScrollPhysics();
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class RootScreen extends StatefulWidget {
  const RootScreen({super.key});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  static const _apiBase = 'https://api2.dansmagazin.net';
  static const _kRemember = 'auth.remember';
  static const _kLoggedIn = 'auth.logged_in';
  static const _kName = 'auth.name';
  static const _kEmail = 'auth.email';
  static const _kSessionToken = 'auth.session_token';
  static const _kAccountId = 'auth.account_id';
  static const _kWpUserId = 'auth.wp_user_id';
  static const _kWpRoles = 'auth.wp_roles';
  static const _kAppRole = 'auth.app_role';
  static const _kCanCreateMobileEvent = 'auth.can_create_mobile_event';
  static const _kOnboardingSeen = 'app.onboarding_seen_v1';
  static const _kDismissedPopupIds = 'app.dismissed_popup_ids_v1';

  int _index = 0;
  bool _bootDone = false;
  bool _isLoggedIn = false;
  bool _guestMode = false;
  String _userName = '';
  String _userEmail = '';
  String _sessionToken = '';
  int _accountId = 0;
  int? _wpUserId;
  List<String> _wpRoles = const [];
  String _appRole = 'customer';
  bool _canCreateMobileEvent = false;
  int _notificationCount = 0;
  Timer? _notifTimer;
  StreamSubscription<Uri>? _deepLinkSub;
  bool _authInFlight = false;
  bool _onboardingChecked = false;
  bool _onboardingVisible = false;
  bool _startupPopupChecked = false;
  bool _startupPopupVisible = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(_appLifecycleObserver);
    AppSettings.language.addListener(_onLanguageChanged);
    NotificationCenter.totalCount.addListener(_onNotificationCountChanged);
    _initDeepLinks();
    unawaited(PushNotificationsService.primeSystemPermissionPrompt());
    unawaited(PushNotificationsService.clearBadge());
    _restoreSession();
  }

  void _onLanguageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(_appLifecycleObserver);
    AppSettings.language.removeListener(_onLanguageChanged);
    NotificationCenter.totalCount.removeListener(_onNotificationCountChanged);
    _notifTimer?.cancel();
    _deepLinkSub?.cancel();
    PushNotificationsService.dispose();
    super.dispose();
  }

  late final WidgetsBindingObserver _appLifecycleObserver = _RootLifecycleObserver(
    onResumed: () => PushNotificationsService.clearBadge(),
  );

  static bool _readBoolParam(String? v) {
    final s = (v ?? '').trim().toLowerCase();
    return s == '1' || s == 'true' || s == 'yes';
  }

  Future<void> _initDeepLinks() async {
    final appLinks = AppLinks();
    try {
      final initial = await appLinks.getInitialLink();
      if (initial != null) {
        await _handleDeepLink(initial);
      }
    } catch (_) {}
    _deepLinkSub = appLinks.uriLinkStream.listen((uri) async {
      await _handleDeepLink(uri);
    }, onError: (_) {});
  }

  Future<void> _handleDeepLink(Uri uri) async {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();

    if (scheme == 'dansmagazin' && host == 'auth-callback') {
      final sessionToken = (uri.queryParameters['session_token'] ?? '').trim();
      if (sessionToken.isEmpty) return;
      final accountId = int.tryParse((uri.queryParameters['account_id'] ?? '0').trim()) ?? 0;
      final wpUserIdRaw = (uri.queryParameters['wp_user_id'] ?? '').trim();
      final wpUserId = wpUserIdRaw.isEmpty ? null : int.tryParse(wpUserIdRaw);
      final wpRolesRaw = (uri.queryParameters['wp_roles'] ?? '').trim();
      final wpRoles = wpRolesRaw.isEmpty
          ? const <String>[]
          : wpRolesRaw
              .split(',')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(growable: false);
      final appRole = (uri.queryParameters['app_role'] ?? 'customer').trim();
      final canCreate = _readBoolParam(uri.queryParameters['can_create_mobile_event']);
      final email = (uri.queryParameters['email'] ?? '').trim();
      final name = (uri.queryParameters['name'] ?? '').trim();

      await _persist(
        remember: true,
        loggedIn: true,
        name: name,
        email: email,
        sessionToken: sessionToken,
        accountId: accountId,
        wpUserId: wpUserId,
        wpRoles: wpRoles,
        appRole: appRole,
        canCreateMobileEvent: canCreate,
      );
      if (!mounted) return;
      setState(() {
        _guestMode = false;
        _isLoggedIn = true;
        _userName = name;
        _userEmail = email;
        _sessionToken = sessionToken;
        _accountId = accountId;
        _wpUserId = wpUserId;
        _wpRoles = wpRoles;
        _appRole = appRole.isEmpty ? 'customer' : appRole;
        _canCreateMobileEvent = canCreate;
        _index = 0;
      });
      _startNotificationsPolling();
      unawaited(PushNotificationsService.initForSession(
        _sessionToken,
        onRouteTap: _openFromPushRoute,
      ));
      _scheduleStartupPopupCheck(forceCheck: true);
      return;
    }

    final route = _routeFromIncomingUri(uri);
    if (route.isNotEmpty) {
      await _openFromPushRoute(route);
    }
  }

  String _routeFromIncomingUri(Uri uri) {
    final qRoute = (uri.queryParameters['route'] ?? '').trim();
    if (qRoute.startsWith('/')) return qRoute;

    final host = uri.host.toLowerCase();
    final path = uri.path.trim();
    final segments = uri.pathSegments.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

    if (path.startsWith('/events/') || path.startsWith('/messages/') || path == '/profile/notifications') {
      return path;
    }

    if (uri.scheme.toLowerCase() == 'dansmagazin') {
      if ((host == 'events' || host == 'event') && segments.isNotEmpty) {
        final id = int.tryParse(segments.first) ?? 0;
        if (id > 0) return '/events/$id';
      }
      if ((host == 'messages' || host == 'message' || host == 'chat') && segments.isNotEmpty) {
        final id = int.tryParse(segments.first) ?? 0;
        if (id > 0) return '/messages/$id';
      }
      if (host == 'notifications' || host == 'notification') {
        return '/profile/notifications';
      }
    }

    if (host.endsWith('dansmagazin.net')) {
      if (path == '/notifications' || path == '/bildirimler') {
        return '/profile/notifications';
      }
      final eId = int.tryParse((uri.queryParameters['event_submission_id'] ?? uri.queryParameters['event_id'] ?? '').trim()) ?? 0;
      if (eId > 0) return '/events/$eId';
    }
    return '';
  }

  void _onNotificationCountChanged() {
    if (!mounted) return;
    final next = NotificationCenter.totalCount.value;
    if (_notificationCount != next) {
      setState(() => _notificationCount = next);
    }
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool(_kRemember) ?? false;
    final loggedIn = prefs.getBool(_kLoggedIn) ?? false;
    final token = prefs.getString(_kSessionToken) ?? '';
    if (!mounted) return;
    if (remember && loggedIn && token.isNotEmpty) {
      try {
        final me = await AuthApi.me(token);
        if (!mounted) return;
        setState(() {
          _isLoggedIn = true;
          _guestMode = false;
          _sessionToken = token;
          _accountId = me.accountId;
          _wpUserId = me.wpUserId;
          _wpRoles = me.wpRoles;
          _appRole = me.appRole;
          _canCreateMobileEvent = me.canCreateMobileEvent;
          _userName = me.name;
          _userEmail = me.email;
          _bootDone = true;
        });
        _startNotificationsPolling();
        unawaited(PushNotificationsService.initForSession(
          _sessionToken,
          onRouteTap: _openFromPushRoute,
        ));
        _scheduleOnboardingCheck();
        return;
      } catch (_) {
        // invalid/expired token: fall through to logged-out mode
      }
    }
    setState(() {
      _isLoggedIn = false;
      _guestMode = false;
      _sessionToken = '';
      _accountId = 0;
      _wpUserId = null;
      _wpRoles = const [];
      _appRole = 'customer';
      _canCreateMobileEvent = false;
      _userName = '';
      _userEmail = '';
      _bootDone = true;
      _notificationCount = 0;
    });
    NotificationCenter.clear();
    _stopNotificationsPolling();
    unawaited(PushNotificationsService.dispose());
    _scheduleOnboardingCheck();
  }

  Future<void> _persist({
    required bool remember,
    required bool loggedIn,
    required String name,
    required String email,
    String sessionToken = '',
    int accountId = 0,
    int? wpUserId,
    List<String> wpRoles = const [],
    String appRole = 'customer',
    bool canCreateMobileEvent = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRemember, remember);
    await prefs.setBool(_kLoggedIn, loggedIn);
    await prefs.setString(_kName, name);
    await prefs.setString(_kEmail, email);
    await prefs.setString(_kSessionToken, sessionToken);
    await prefs.setInt(_kAccountId, accountId);
    if (wpUserId == null) {
      await prefs.remove(_kWpUserId);
    } else {
      await prefs.setInt(_kWpUserId, wpUserId);
    }
    await prefs.setStringList(_kWpRoles, wpRoles);
    await prefs.setString(_kAppRole, appRole);
    await prefs.setBool(_kCanCreateMobileEvent, canCreateMobileEvent);
  }

  Future<void> _openAuth({required bool allowGuest, int? targetIndex}) async {
    if (_authInFlight || !mounted) return;
    _authInFlight = true;
    try {
      final result = await Navigator.of(context).push<AuthResult>(
        MaterialPageRoute(builder: (_) => AuthScreen(allowGuest: allowGuest)),
      );
      if (result == null || !mounted) return;
      if (result.action == AuthAction.guest) {
        final previousSession = _sessionToken;
        setState(() {
          _guestMode = true;
          _isLoggedIn = false;
          _sessionToken = '';
          _accountId = 0;
          _wpUserId = null;
          _wpRoles = const [];
          _appRole = 'customer';
          _canCreateMobileEvent = false;
          _index = 0;
          _notificationCount = 0;
        });
        NotificationCenter.clear();
        _stopNotificationsPolling();
        unawaited(PushNotificationsService.unregisterForSession(previousSession));
        unawaited(PushNotificationsService.dispose());
        _scheduleStartupPopupCheck(forceCheck: true);
        return;
      }
      await _persist(
        remember: result.rememberMe,
        loggedIn: true,
        name: result.name,
        email: result.email,
        sessionToken: result.sessionToken,
        accountId: result.accountId,
        wpUserId: result.wpUserId,
        wpRoles: result.wpRoles,
        appRole: result.appRole,
        canCreateMobileEvent: result.canCreateMobileEvent,
      );
      if (!mounted) return;
      setState(() {
        _guestMode = false;
        _isLoggedIn = true;
        _userName = result.name;
        _userEmail = result.email;
        _sessionToken = result.sessionToken;
        _accountId = result.accountId;
        _wpUserId = result.wpUserId;
        _wpRoles = result.wpRoles;
        _appRole = result.appRole;
        _canCreateMobileEvent = result.canCreateMobileEvent;
        if (targetIndex != null) _index = targetIndex;
      });
      _startNotificationsPolling();
      unawaited(PushNotificationsService.initForSession(
        _sessionToken,
        onRouteTap: _openFromPushRoute,
      ));
      _scheduleOnboardingCheck();
      _scheduleStartupPopupCheck(forceCheck: true);
    } finally {
      _authInFlight = false;
    }
  }

  Future<void> _openAuthIfNeeded({required bool allowGuest, int? targetIndex}) async {
    if (_authInFlight || !mounted) return;
    await _openAuth(allowGuest: allowGuest, targetIndex: targetIndex);
  }

  Future<void> _refreshSessionIdentity() async {
    final token = _sessionToken.trim();
    if (!_isLoggedIn || token.isEmpty) return;
    try {
      final me = await AuthApi.me(token);
      if (!mounted) return;
      final wpRolesChanged = _wpRoles.length != me.wpRoles.length ||
          _wpRoles.any((r) => !me.wpRoles.contains(r));
      final needsUpdate = _userName != me.name ||
          _userEmail != me.email ||
          _accountId != me.accountId ||
          _wpUserId != me.wpUserId ||
          _appRole != me.appRole ||
          _canCreateMobileEvent != me.canCreateMobileEvent ||
          wpRolesChanged;
      if (!needsUpdate) return;
      setState(() {
        _userName = me.name;
        _userEmail = me.email;
        _accountId = me.accountId;
        _wpUserId = me.wpUserId;
        _wpRoles = me.wpRoles;
        _appRole = me.appRole;
        _canCreateMobileEvent = me.canCreateMobileEvent;
      });
    } catch (_) {
      // geçici ağ hatalarında sessizce devam et
    }
  }

  Future<void> _logout() async {
    final previousSession = _sessionToken;
    await _persist(remember: false, loggedIn: false, name: '', email: '');
    if (!mounted) return;
    setState(() {
      _isLoggedIn = false;
      _userName = '';
      _userEmail = '';
      _sessionToken = '';
      _accountId = 0;
      _wpUserId = null;
      _wpRoles = const [];
      _appRole = 'customer';
      _canCreateMobileEvent = false;
      _index = 0;
      _guestMode = false;
      _notificationCount = 0;
    });
    NotificationCenter.clear();
    _stopNotificationsPolling();
    unawaited(PushNotificationsService.unregisterForSession(previousSession));
    unawaited(PushNotificationsService.dispose());
    _scheduleOnboardingCheck(forceCheck: true);
    _startupPopupChecked = false;
  }

  void _scheduleOnboardingCheck({bool forceCheck = false}) {
    if (forceCheck) {
      _onboardingChecked = false;
    }
    if (_onboardingChecked || _onboardingVisible || !mounted) return;
    _onboardingChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowOnboarding());
    });
  }

  void _scheduleStartupPopupCheck({bool forceCheck = false}) {
    if (forceCheck) {
      _startupPopupChecked = false;
    }
    if (_startupPopupChecked || _startupPopupVisible || !mounted) return;
    if (!_bootDone || _authInFlight) return;
    _startupPopupChecked = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeShowStartupPopup());
    });
  }

  Future<void> _maybeShowOnboarding() async {
    if (!mounted || _onboardingVisible || !_bootDone || _authInFlight) return;
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool(_kOnboardingSeen) ?? false;
    if (seen || !mounted) {
      _scheduleStartupPopupCheck(forceCheck: true);
      return;
    }
    _onboardingVisible = true;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _OnboardingDialog(),
    );
    await prefs.setBool(_kOnboardingSeen, true);
    _onboardingVisible = false;
    _scheduleStartupPopupCheck(forceCheck: true);
  }

  int _compareVersionStrings(String a, String b) {
    List<int> parts(String raw) {
      final nums = RegExp(r'\d+')
          .allMatches(raw)
          .map((m) => int.tryParse(m.group(0) ?? '0') ?? 0)
          .toList();
      return nums.isEmpty ? <int>[0] : nums;
    }

    final left = parts(a);
    final right = parts(b);
    final maxLen = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < maxLen; i++) {
      final l = i < left.length ? left[i] : 0;
      final r = i < right.length ? right[i] : 0;
      if (l != r) return l.compareTo(r);
    }
    return 0;
  }

  Future<void> _markPopupDismissed(int popupId) async {
    if (popupId <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kDismissedPopupIds) ?? const <String>[];
    if (ids.contains('$popupId')) return;
    await prefs.setStringList(_kDismissedPopupIds, [...ids, '$popupId']);
  }

  Future<bool> _isPopupDismissed(int popupId) async {
    if (popupId <= 0) return false;
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_kDismissedPopupIds) ?? const <String>[];
    return ids.contains('$popupId');
  }

  Future<void> _handlePopupAction(AppPopupConfig popup) async {
    final target = popup.ctaTarget.trim();
    if (target.isEmpty) return;
    if (target.startsWith('/')) {
      await _openFromPushRoute(target);
      return;
    }
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _maybeShowStartupPopup() async {
    if (!mounted || _startupPopupVisible || !_bootDone || _authInFlight) return;
    try {
      final popup = await NotificationsApi.fetchCurrentPopup();
      if (!mounted || popup == null || !popup.isActive) return;
      if (!_isLoggedIn && !popup.showToGuests) return;
      final minVersion = popup.minimumAppVersion.trim();
      if (minVersion.isNotEmpty) {
        final info = await PackageInfo.fromPlatform();
        final currentVersion = '${info.version}+${info.buildNumber}';
        if (_compareVersionStrings(currentVersion, minVersion) >= 0) {
          return;
        }
      }
      final alreadyDismissed = await _isPopupDismissed(popup.id);
      if (alreadyDismissed && popup.dismissible && !popup.forceUpdate) {
        return;
      }
      _startupPopupVisible = true;
      final dismissible = popup.dismissible && !popup.forceUpdate;
      final actionLabel = popup.ctaLabel.trim().isEmpty
          ? (popup.forceUpdate ? 'Güncelle' : 'Tamam')
          : popup.ctaLabel.trim();

      final actionPressed = await showDialog<bool>(
        context: context,
        barrierDismissible: dismissible,
        builder: (ctx) {
          return WillPopScope(
            onWillPop: () async => dismissible,
            child: AlertDialog(
              backgroundColor: AppTheme.surfaceSecondary,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              title: Text(popup.title.trim().isEmpty ? 'Duyuru' : popup.title.trim()),
              content: Text(
                popup.body.trim(),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              actions: [
                if (dismissible)
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: Text(I18n.t('cancel')),
                  ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(actionLabel),
                ),
              ],
            ),
          );
        },
      );

      if (!mounted) return;
      if (actionPressed == true) {
        await _handlePopupAction(popup);
      } else if (dismissible) {
        await _markPopupDismissed(popup.id);
      }
    } catch (_) {
      // Açılış popupı hatası ana akışı bozmasın.
    } finally {
      _startupPopupVisible = false;
    }
  }

  void _onNavTap(int i) {
    if ((i == 3 || i == 4) && !_isLoggedIn) {
      unawaited(_openAuthIfNeeded(allowGuest: false, targetIndex: i));
      return;
    }
    setState(() => _index = i);
    unawaited(_refreshSessionIdentity());
  }

  void _stopNotificationsPolling() {
    _notifTimer?.cancel();
    _notifTimer = null;
  }

  void _startNotificationsPolling() {
    _stopNotificationsPolling();
    _refreshNotificationCount();
    _notifTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      _refreshNotificationCount();
    });
  }

  Future<void> _refreshNotificationCount() async {
    final token = _sessionToken.trim();
    if (!_isLoggedIn || token.isEmpty) {
      if (mounted && _notificationCount != 0) {
        setState(() => _notificationCount = 0);
      }
      NotificationCenter.clear();
      return;
    }
    await NotificationCenter.refresh(token);
  }

  Future<void> _openFromPushRoute(String route) async {
    final raw = route.trim();
    if (raw.isEmpty || !mounted) return;
    final uri = Uri.tryParse(raw);
    final maybeFromLink = uri == null ? '' : _routeFromIncomingUri(uri);
    final normalized = maybeFromLink.isNotEmpty ? maybeFromLink : raw;
    final path = (Uri.tryParse(normalized)?.path ?? normalized).trim();
    final eventMatch = RegExp(r'^/events/(\d+)$').firstMatch(path);
    if (eventMatch != null) {
      final id = int.tryParse(eventMatch.group(1) ?? '') ?? 0;
      if (id > 0) {
        await _openEventDetailById(id);
        return;
      }
    }
    final messageMatch = RegExp(r'^/messages/(\d+)$').firstMatch(path);
    if (messageMatch != null) {
      final peerId = int.tryParse(messageMatch.group(1) ?? '') ?? 0;
      if (peerId > 0 && _sessionToken.trim().isNotEmpty) {
        if (!mounted) return;
        setState(() => _index = 3);
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatThreadScreen(
              sessionToken: _sessionToken,
              peerAccountId: peerId,
              peerName: I18n.t('user'),
            ),
          ),
        );
        return;
      }
    }
    if (path == '/profile/notifications') {
      if (!mounted) return;
      setState(() => _index = 4);
      if (_sessionToken.trim().isEmpty) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NotificationsScreen(
            sessionToken: _sessionToken,
            onOpenRoute: _openFromPushRoute,
          ),
        ),
      );
      return;
    }
  }

  String _asAbsUrl(String v, {String host = _apiBase}) {
    final x = v.trim();
    if (x.isEmpty) return '';
    if (x.startsWith('http://') || x.startsWith('https://')) return x;
    if (x.startsWith('/')) return '$host$x';
    return '$host/$x';
  }

  Future<void> _openEventDetailById(int submissionId) async {
    try {
      final uri = Uri.parse('$_apiBase/events').replace(queryParameters: {'limit': '500'});
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return;
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final items = (body['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>();
      Map<String, dynamic>? event;
      for (final it in items) {
        if ((it['id'] as num?)?.toInt() == submissionId) {
          event = it;
          break;
        }
      }
      if (event == null || !mounted) return;
      final ev = event;
      setState(() => _index = 0);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => EventDetailScreen(
            title: (ev['name'] ?? '').toString(),
            submissionId: submissionId,
            cover: _asAbsUrl((ev['cover'] ?? ev['cover_url'] ?? ev['image'] ?? '').toString()),
            description: (ev['description'] ?? '').toString(),
            eventDate: (ev['start_at'] ?? ev['event_date'] ?? '').toString(),
            endAt: (ev['end_at'] ?? '').toString(),
            venue: (ev['venue'] ?? '').toString(),
            venueMapUrl: (ev['venue_map_url'] ?? '').toString(),
            organizer: (ev['organizer_name'] ?? '').toString(),
            program: (ev['program_text'] ?? '').toString(),
            entryFee: (ev['entry_fee'] as num?)?.toDouble() ?? 0.0,
            ticketUrl: _asAbsUrl((ev['ticket_url'] ?? '').toString(), host: 'https://www.dansmagazin.net'),
            wooProductId: (ev['woo_product_id'] ?? '').toString(),
            ticketSalesEnabled: (ev['ticket_sales_enabled'] == true) || (ev['ticket_sales_enabled'] == 1),
            sessionToken: _sessionToken,
          ),
        ),
      );
    } catch (_) {
      // sessiz geç: bildirim açılışı ana akışı bozmasın
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_bootDone) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_guestMode && !_isLoggedIn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_openAuthIfNeeded(allowGuest: true));
      });
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final pages = [
      DiscoverScreen(sessionToken: _sessionToken),
      EventsStoreHubScreen(
        sessionToken: _sessionToken,
        canCreateEvent: _canCreateMobileEvent,
      ),
      PhotosScreen(
        accountId: _accountId,
        sessionToken: _sessionToken,
        appRole: _appRole,
        onRequireLogin: () => _openAuthIfNeeded(allowGuest: false, targetIndex: 2),
      ),
      SocialScreen(sessionToken: _sessionToken),
      ProfileScreen(
        isLoggedIn: _isLoggedIn,
        userName: _userName,
        userEmail: _userEmail,
        sessionToken: _sessionToken,
        accountId: _accountId,
        wpUserId: _wpUserId,
        wpRoles: _wpRoles,
        appRole: _appRole,
        canCreateMobileEvent: _canCreateMobileEvent,
        onLoginTap: () => _openAuthIfNeeded(allowGuest: false, targetIndex: 4),
        onLogoutTap: () {
          _logout();
        },
        onOpenRoute: _openFromPushRoute,
      ),
    ];

    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfacePrimary.withOpacity(0.96),
            border: Border(top: BorderSide(color: AppTheme.borderStrong.withOpacity(0.92))),
            boxShadow: [
              BoxShadow(
                color: AppTheme.violet.withOpacity(0.08),
                blurRadius: 22,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: BottomNavigationBar(
            currentIndex: _index,
            onTap: _onNavTap,
            items: [
              BottomNavigationBarItem(
                icon: const Icon(Icons.article_outlined),
                activeIcon: const Icon(Icons.article),
                label: _tr('news'),
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.shopping_bag_outlined),
                activeIcon: const Icon(Icons.shopping_bag),
                label: _tr('shop'),
              ),
              const BottomNavigationBarItem(
                icon: Icon(Icons.circle, color: Colors.transparent),
                activeIcon: Icon(Icons.circle, color: Colors.transparent),
                label: '',
              ),
              BottomNavigationBarItem(
                icon: _socialNavIcon(active: false),
                activeIcon: _socialNavIcon(active: true),
                label: _tr('social'),
              ),
              BottomNavigationBarItem(
                icon: const Icon(Icons.person_outline),
                activeIcon: const Icon(Icons.person),
                label: _tr('profile'),
              ),
            ],
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: keyboardVisible
          ? null
          : GestureDetector(
              onTap: () => _onNavTap(2),
              child: Container(
                width: 86,
                height: 86,
                padding: const EdgeInsets.all(10),
                decoration: AppTheme.glowCircle(tone: AppTone.photos, radius: 26),
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.bgDeep.withOpacity(0.9),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: Image.asset(
                    'assets/icons/dm.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
    );
  }

  String _tr(String key) {
    return I18n.t(key);
  }

  Widget _socialNavIcon({required bool active}) {
    final hasNotification = _notificationCount > 0;
    final iconColor =
        hasNotification ? AppTheme.pink : (active ? AppTheme.violet : AppTheme.textTertiary);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(active ? Icons.groups : Icons.groups_outlined, color: iconColor),
        if (hasNotification)
          Positioned(
            right: -8,
            top: -6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.pink,
                borderRadius: BorderRadius.circular(10),
              ),
              constraints: const BoxConstraints(minWidth: 18),
              child: Text(
                _notificationCount > 99 ? '99+' : _notificationCount.toString(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700),
              ),
            ),
          ),
      ],
    );
  }
}

class _OnboardingStep {
  final IconData icon;
  final String titleKey;
  final String bodyKey;

  const _OnboardingStep({
    required this.icon,
    required this.titleKey,
    required this.bodyKey,
  });
}

class _RootLifecycleObserver with WidgetsBindingObserver {
  final Future<void> Function() onResumed;

  _RootLifecycleObserver({required this.onResumed});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(onResumed());
    }
  }
}

class _OnboardingDialog extends StatefulWidget {
  const _OnboardingDialog();

  @override
  State<_OnboardingDialog> createState() => _OnboardingDialogState();
}

class _OnboardingDialogState extends State<_OnboardingDialog> {
  final PageController _controller = PageController();
  int _index = 0;

  static const List<_OnboardingStep> _steps = [
    _OnboardingStep(
      icon: Icons.waving_hand_rounded,
      titleKey: 'onboarding_welcome_title',
      bodyKey: 'onboarding_welcome_body',
    ),
    _OnboardingStep(
      icon: Icons.article_outlined,
      titleKey: 'onboarding_news_title',
      bodyKey: 'onboarding_news_body',
    ),
    _OnboardingStep(
      icon: Icons.shopping_bag_outlined,
      titleKey: 'onboarding_shop_title',
      bodyKey: 'onboarding_shop_body',
    ),
    _OnboardingStep(
      icon: Icons.photo_library_outlined,
      titleKey: 'onboarding_photos_title',
      bodyKey: 'onboarding_photos_body',
    ),
    _OnboardingStep(
      icon: Icons.groups_outlined,
      titleKey: 'onboarding_social_title',
      bodyKey: 'onboarding_social_body',
    ),
    _OnboardingStep(
      icon: Icons.person_outline,
      titleKey: 'onboarding_profile_title',
      bodyKey: 'onboarding_profile_body',
    ),
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_index >= _steps.length - 1) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    await _controller.nextPage(
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    final isLast = _index == _steps.length - 1;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 420),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF1A2238), Color(0xFF0B1020)],
          ),
          border: Border.all(color: Colors.white12),
          boxShadow: const [
            BoxShadow(
              color: Color(0x55000000),
              blurRadius: 30,
              offset: Offset(0, 16),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t('onboarding_skip')),
              ),
            ),
            SizedBox(
              height: 340,
              child: PageView.builder(
                controller: _controller,
                itemCount: _steps.length,
                onPageChanged: (value) => setState(() => _index = value),
                itemBuilder: (_, i) {
                  final step = _steps[i];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 82,
                          height: 82,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE53935).withOpacity(0.18),
                            shape: BoxShape.circle,
                            border: Border.all(color: const Color(0xFFE53935).withOpacity(0.35)),
                          ),
                          child: Icon(step.icon, size: 40, color: const Color(0xFFFF6B6B)),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          t(step.titleKey),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          t(step.bodyKey),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.45,
                            color: Colors.white.withOpacity(0.82),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(
                _steps.length,
                (i) => AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: _index == i ? 22 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _index == i ? const Color(0xFFE53935) : Colors.white24,
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(t('onboarding_skip')),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _next,
                    child: Text(isLast ? t('onboarding_start') : t('onboarding_next')),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
