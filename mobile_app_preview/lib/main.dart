import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'services/auth_api.dart';
import 'services/app_settings.dart';
import 'services/i18n.dart';
import 'services/notification_center.dart';
import 'services/push_notifications_service.dart';
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
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080B14),
        visualDensity: VisualDensity.compact,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFE53935),
          secondary: Color(0xFFFF5A5F),
          surface: Color(0xFF111827),
        ),
      ),
      home: const RootScreen(),
    );
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

  @override
  void initState() {
    super.initState();
    AppSettings.language.addListener(_onLanguageChanged);
    NotificationCenter.totalCount.addListener(_onNotificationCountChanged);
    _initDeepLinks();
    unawaited(PushNotificationsService.primeSystemPermissionPrompt());
    _restoreSession();
  }

  void _onLanguageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    AppSettings.language.removeListener(_onLanguageChanged);
    NotificationCenter.totalCount.removeListener(_onNotificationCountChanged);
    _notifTimer?.cancel();
    _deepLinkSub?.cancel();
    PushNotificationsService.dispose();
    super.dispose();
  }

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
    if (uri.scheme != 'dansmagazin' || uri.host != 'auth-callback') return;
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
  }

  void _onNavTap(int i) {
    if ((i == 3 || i == 4) && !_isLoggedIn) {
      _openAuth(allowGuest: false, targetIndex: i);
      return;
    }
    setState(() => _index = i);
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
    final path = (uri?.path ?? raw).trim();
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
          builder: (_) => NotificationsScreen(sessionToken: _sessionToken),
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
        _openAuth(allowGuest: true);
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
        onRequireLogin: () => _openAuth(allowGuest: false, targetIndex: 2),
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
        onLoginTap: () => _openAuth(allowGuest: false, targetIndex: 4),
        onLogoutTap: () {
          _logout();
        },
      ),
    ];

    final keyboardVisible = MediaQuery.of(context).viewInsets.bottom > 0;

    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: _index,
          type: BottomNavigationBarType.fixed,
          selectedItemColor: const Color(0xFFE53935),
          unselectedItemColor: Colors.white70,
          backgroundColor: const Color(0xFF0F172A),
          onTap: _onNavTap,
          items: [
            BottomNavigationBarItem(
              icon: Icon(Icons.article_outlined),
              activeIcon: Icon(Icons.article),
              label: _tr('news'),
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.shopping_bag_outlined),
              activeIcon: Icon(Icons.shopping_bag),
              label: _tr('shop'),
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.circle),
              activeIcon: Icon(Icons.circle),
              label: '',
            ),
            BottomNavigationBarItem(
              icon: _socialNavIcon(active: false),
              activeIcon: _socialNavIcon(active: true),
              label: _tr('social'),
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              activeIcon: Icon(Icons.person),
              label: _tr('profile'),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: keyboardVisible
          ? null
          : GestureDetector(
              onTap: () => _onNavTap(2),
              child: SizedBox(
                width: 92,
                height: 92,
                child: Image.asset(
                  'assets/icons/dm.png',
                  fit: BoxFit.contain,
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
    final iconColor = hasNotification ? Colors.redAccent : (active ? const Color(0xFFE53935) : Colors.white70);
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
                color: Colors.redAccent,
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
