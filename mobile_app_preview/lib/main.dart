import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'services/auth_api.dart';
import 'screens/auth_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/events_screen.dart';
import 'screens/store_screen.dart';
import 'screens/photos_screen.dart';
import 'screens/profile_screen.dart';

void main() {
  runApp(const DansMagazinApp());
}

class DansMagazinApp extends StatelessWidget {
  const DansMagazinApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dansmagazin',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF080B14),
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

  @override
  void initState() {
    super.initState();
    _restoreSession();
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
    });
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
      });
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
    });
  }

  void _onNavTap(int i) {
    if ((i == 3 || i == 4) && !_isLoggedIn) {
      _openAuth(allowGuest: false, targetIndex: i);
      return;
    }
    setState(() => _index = i);
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
      EventsScreen(
        sessionToken: _sessionToken,
        canCreateEvent: _canCreateMobileEvent,
      ),
      PhotosScreen(accountId: _accountId),
      const StoreScreen(),
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
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        type: BottomNavigationBarType.fixed,
        selectedItemColor: const Color(0xFFE53935),
        unselectedItemColor: Colors.white70,
        backgroundColor: const Color(0xFF0F172A),
        onTap: _onNavTap,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.article_outlined),
            activeIcon: Icon(Icons.article),
            label: 'Haberler',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.event_outlined),
            activeIcon: Icon(Icons.event),
            label: 'Etkinlikler',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.photo_library_outlined),
            activeIcon: Icon(Icons.photo_library),
            label: 'Fotoğraflar',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.storefront_outlined),
            activeIcon: Icon(Icons.storefront),
            label: 'Mağaza',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            activeIcon: Icon(Icons.person),
            label: 'Profil',
          ),
        ],
      ),
    );
  }
}
