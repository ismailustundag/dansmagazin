import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'chat_thread_screen.dart';

class FriendProfileScreen extends StatefulWidget {
  final String sessionToken;
  final int friendAccountId;

  const FriendProfileScreen({
    super.key,
    required this.sessionToken,
    required this.friendAccountId,
  });

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<_FriendProfile> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<_FriendProfile> _fetch() async {
    final resp = await http.get(
      Uri.parse('$_base/profile/friends/${widget.friendAccountId}'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Arkadaş profili alınamadı');
    }
    return _FriendProfile.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(backgroundColor: const Color(0xFF0B1020), title: const Text('Arkadaş Profili')),
      body: FutureBuilder<_FriendProfile>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() => _future = _fetch()),
                child: const Text('Profil yüklenemedi, tekrar dene'),
              ),
            );
          }
          final p = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: const Color(0xFF121826),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Row(
                  children: [
                    const CircleAvatar(
                      radius: 28,
                      backgroundColor: Color(0xFFE53935),
                      child: Icon(Icons.person, color: Colors.white, size: 28),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(p.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                          if (p.email.isNotEmpty)
                            Text(p.email, style: const TextStyle(color: Colors.white70, fontSize: 13)),
                          if (p.friendsSince.isNotEmpty)
                            Text('Arkadaşlık: ${p.friendsSince}', style: const TextStyle(color: Colors.white54, fontSize: 12)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => ChatThreadScreen(
                          sessionToken: widget.sessionToken,
                          peerAccountId: p.accountId,
                          peerName: p.name,
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.chat_bubble),
                  label: const Text('Mesaj Gönder'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _FriendProfile {
  final int accountId;
  final String name;
  final String email;
  final String friendsSince;

  const _FriendProfile({
    required this.accountId,
    required this.name,
    required this.email,
    required this.friendsSince,
  });

  factory _FriendProfile.fromJson(Map<String, dynamic> json) {
    return _FriendProfile(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      friendsSince: (json['friends_since'] ?? '').toString(),
    );
  }
}
