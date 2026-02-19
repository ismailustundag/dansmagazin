import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/auth_screen.dart';
import 'screens/discover_screen.dart';
import 'screens/events_screen.dart';
import 'screens/messages_screen.dart';
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

  int _index = 0;
  bool _bootDone = false;
  bool _isLoggedIn = false;
  bool _guestMode = false;
  String _userName = '';
  String _userEmail = '';

  @override
  void initState() {
    super.initState();
    _restoreSession();
  }

  Future<void> _restoreSession() async {
    final prefs = await SharedPreferences.getInstance();
    final remember = prefs.getBool(_kRemember) ?? false;
    final loggedIn = prefs.getBool(_kLoggedIn) ?? false;
    if (!mounted) return;
    setState(() {
      _isLoggedIn = remember && loggedIn;
      _guestMode = !_isLoggedIn;
      _userName = prefs.getString(_kName) ?? '';
      _userEmail = prefs.getString(_kEmail) ?? '';
      _bootDone = true;
    });
  }

  Future<void> _persist({
    required bool remember,
    required bool loggedIn,
    required String name,
    required String email,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRemember, remember);
    await prefs.setBool(_kLoggedIn, loggedIn);
    await prefs.setString(_kName, name);
    await prefs.setString(_kEmail, email);
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
      });
      return;
    }
    await _persist(
      remember: result.rememberMe,
      loggedIn: true,
      name: result.name,
      email: result.email,
    );
    if (!mounted) return;
    setState(() {
      _guestMode = true;
      _isLoggedIn = true;
      _userName = result.name;
      _userEmail = result.email;
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
      const DiscoverScreen(),
      const EventsScreen(),
      const PhotosScreen(),
      MessagesScreen(
        isLoggedIn: _isLoggedIn,
        onLoginTap: () => _openAuth(allowGuest: false, targetIndex: 3),
      ),
      ProfileScreen(
        isLoggedIn: _isLoggedIn,
        userName: _userName,
        userEmail: _userEmail,
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
            icon: Icon(Icons.chat_bubble_outline),
            activeIcon: Icon(Icons.chat_bubble),
            label: 'Mesajlar',
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
