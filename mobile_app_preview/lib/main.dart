import 'package:flutter/material.dart';

import 'screens/discover_screen.dart';
import 'screens/events_screen.dart';
import 'screens/login_screen.dart';
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
  int _index = 0;
  bool _isLoggedIn = false;
  String _userName = '';
  String _userEmail = '';

  Future<void> _openLogin({int? targetIndex}) async {
    final result = await Navigator.of(context).push<LoginResult>(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
    );
    if (result == null || !mounted) return;
    setState(() {
      _isLoggedIn = true;
      _userName = result.name;
      _userEmail = result.email;
      if (targetIndex != null) _index = targetIndex;
    });
  }

  void _logout() {
    setState(() {
      _isLoggedIn = false;
      _userName = '';
      _userEmail = '';
      _index = 0;
    });
  }

  void _onNavTap(int i) {
    if ((i == 3 || i == 4) && !_isLoggedIn) {
      _openLogin(targetIndex: i);
      return;
    }
    setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const DiscoverScreen(),
      const EventsScreen(),
      const PhotosScreen(),
      MessagesScreen(
        isLoggedIn: _isLoggedIn,
        onLoginTap: () => _openLogin(targetIndex: 3),
      ),
      ProfileScreen(
        isLoggedIn: _isLoggedIn,
        userName: _userName,
        userEmail: _userEmail,
        onLoginTap: () => _openLogin(targetIndex: 4),
        onLogoutTap: _logout,
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
            icon: Icon(Icons.explore_outlined),
            activeIcon: Icon(Icons.explore),
            label: 'Keşfet',
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
