import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/auth_api.dart';
import 'services/app_settings.dart';
import 'services/i18n.dart';
import 'services/notifications_api.dart';
import 'screens/auth_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/events_store_hub_screen.dart';
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
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: media.textScaler.clamp(minScaleFactor: 0.92, maxScaleFactor: 1.0),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
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

  @override
  void initState() {
    super.initState();
    AppSettings.language.addListener(_onLanguageChanged);
    _restoreSession();
  }

  void _onLanguageChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    AppSettings.language.removeListener(_onLanguageChanged);
    _notifTimer?.cancel();
    super.dispose();
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
    _stopNotificationsPolling();
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
      _stopNotificationsPolling();
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
  }

  Future<void> _logout() async {
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
    _stopNotificationsPolling();
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
      return;
    }
    try {
      final s = await NotificationsApi.fetchSummary(token);
      if (!mounted) return;
      if (_notificationCount != s.totalCount) {
        setState(() => _notificationCount = s.totalCount);
      }
    } catch (_) {}
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
      PhotosScreen(accountId: _accountId, sessionToken: _sessionToken),
      EventsStoreHubScreen(
        sessionToken: _sessionToken,
        canCreateEvent: _canCreateMobileEvent,
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
        canCreateMobileEvent: _canCreateMobileEvent,
        onLoginTap: () => _openAuth(allowGuest: false, targetIndex: 4),
        onLogoutTap: () {
          _logout();
        },
      ),
    ];

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
              icon: Icon(Icons.photo_library_outlined),
              activeIcon: Icon(Icons.photo_library),
              label: _tr('photos'),
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
      floatingActionButton: GestureDetector(
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
