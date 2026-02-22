import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/event_social_api.dart';
import 'friend_profile_screen.dart';

class FriendsScreen extends StatefulWidget {
  final String sessionToken;

  const FriendsScreen({super.key, required this.sessionToken});

  @override
  State<FriendsScreen> createState() => _FriendsScreenState();
}

class _FriendsScreenState extends State<FriendsScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_FriendItem>> _future;
  late Future<List<FriendRequestItem>> _incomingFuture;

  @override
  void initState() {
    super.initState();
    _future = _fetchFriends();
    _incomingFuture = _fetchIncoming();
  }

  Future<List<_FriendItem>> _fetchFriends() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) throw Exception('Oturum bulunamadı');
    final resp = await http.get(
      Uri.parse('$_base/profile/friends'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Arkadaş listesi alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => _FriendItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<List<FriendRequestItem>> _fetchIncoming() {
    return EventSocialApi.friendRequests(
      sessionToken: widget.sessionToken,
      direction: 'incoming',
    );
  }

  Future<void> _accept(int requestId) async {
    await EventSocialApi.acceptFriendRequest(sessionToken: widget.sessionToken, requestId: requestId);
    if (!mounted) return;
    setState(() {
      _future = _fetchFriends();
      _incomingFuture = _fetchIncoming();
    });
  }

  Future<void> _reject(int requestId) async {
    await EventSocialApi.rejectFriendRequest(sessionToken: widget.sessionToken, requestId: requestId);
    if (!mounted) return;
    setState(() => _incomingFuture = _fetchIncoming());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: const Text('Arkadaşlarım'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          FutureBuilder<List<FriendRequestItem>>(
            future: _incomingFuture,
            builder: (context, snapshot) {
              final reqs = snapshot.data ?? const <FriendRequestItem>[];
              return Container(
                margin: const EdgeInsets.only(bottom: 14),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Gelen İstekler (${reqs.length})',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    if (snapshot.connectionState == ConnectionState.waiting)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (reqs.isEmpty)
                      const Text('Bekleyen arkadaşlık isteği yok.')
                    else
                      ...reqs.map((r) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(child: Text(r.peerName)),
                              TextButton(onPressed: () => _reject(r.requestId), child: const Text('Reddet')),
                              ElevatedButton(onPressed: () => _accept(r.requestId), child: const Text('Kabul Et')),
                            ],
                          ),
                        );
                      }),
                  ],
                ),
              );
            },
          ),
          FutureBuilder<List<_FriendItem>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: TextButton(
                    onPressed: () => setState(() => _future = _fetchFriends()),
                    child: const Text('Arkadaşlar yüklenemedi, tekrar dene'),
                  ),
                );
              }
              final items = snapshot.data ?? [];
              if (items.isEmpty) {
                return const Center(child: Text('Henüz arkadaş eklenmemiş.'));
              }
              return Column(
                children: items.map((f) {
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => FriendProfileScreen(
                            sessionToken: widget.sessionToken,
                            friendAccountId: f.accountId,
                          ),
                        ),
                      );
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121826),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          const CircleAvatar(
                            backgroundColor: Color(0xFFE53935),
                            child: Icon(Icons.person, color: Colors.white),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(f.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                                if (f.email.isNotEmpty)
                                  Text(f.email, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                          const Icon(Icons.chevron_right, color: Colors.white54),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FriendItem {
  final int accountId;
  final String name;
  final String email;

  const _FriendItem({required this.accountId, required this.name, required this.email});

  factory _FriendItem.fromJson(Map<String, dynamic> json) {
    return _FriendItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
    );
  }
}
