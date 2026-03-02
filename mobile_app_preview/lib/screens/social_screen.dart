import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/event_social_api.dart';
import 'chat_thread_screen.dart';
import 'friend_profile_screen.dart';
import 'screen_shell.dart';

class SocialScreen extends StatefulWidget {
  final String sessionToken;

  const SocialScreen({super.key, required this.sessionToken});

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
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

  Future<void> _refresh() async {
    setState(() {
      _future = _fetchFriends();
      _incomingFuture = _fetchIncoming();
    });
    await _future;
  }

  Future<List<FriendRequestItem>> _fetchIncoming() {
    return EventSocialApi.friendRequests(
      sessionToken: widget.sessionToken,
      direction: 'incoming',
    );
  }

  Future<void> _accept(int requestId) async {
    await EventSocialApi.acceptFriendRequest(
      sessionToken: widget.sessionToken,
      requestId: requestId,
    );
    if (!mounted) return;
    setState(() {
      _future = _fetchFriends();
      _incomingFuture = _fetchIncoming();
    });
  }

  Future<void> _reject(int requestId) async {
    await EventSocialApi.rejectFriendRequest(
      sessionToken: widget.sessionToken,
      requestId: requestId,
    );
    if (!mounted) return;
    setState(() => _incomingFuture = _fetchIncoming());
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Sosyal',
      icon: Icons.groups,
      subtitle: 'Arkadaşlarınla bağlantıda kal ve mesajlaş.',
      onRefresh: _refresh,
      content: [
        FutureBuilder<List<FriendRequestItem>>(
          future: _incomingFuture,
          builder: (context, snapshot) {
            final reqs = snapshot.data ?? const <FriendRequestItem>[];
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    reqs.isEmpty ? 'Gelen İstekler' : 'Gelen İstekler (${reqs.length})',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (reqs.isEmpty)
                    Text(
                      'Bekleyen arkadaşlık isteği yok.',
                      style: TextStyle(color: Colors.white.withOpacity(0.75)),
                    )
                  else
                    ...reqs.map(
                      (r) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.peerName.isNotEmpty ? r.peerName : 'Kullanıcı',
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _reject(r.requestId),
                              child: const Text('Reddet'),
                            ),
                            ElevatedButton(
                              onPressed: () => _accept(r.requestId),
                              child: const Text('Kabul Et'),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        FutureBuilder<List<_FriendItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _SocialErrorCard(onRetry: _refresh);
            }
            final items = snapshot.data ?? const <_FriendItem>[];
            if (items.isEmpty) {
              return const _SocialInfoCard(text: 'Henüz arkadaş eklenmemiş.');
            }
            return Column(
              children: items
                  .map(
                    (f) => Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121826),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _FriendAvatar(item: f),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  f.name.isNotEmpty ? f.name : 'Kullanıcı',
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                                if (f.email.isNotEmpty)
                                  Text(
                                    f.email,
                                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                                  ),
                                const SizedBox(height: 8),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => FriendProfileScreen(
                                              sessionToken: widget.sessionToken,
                                              friendAccountId: f.accountId,
                                            ),
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.person, size: 16),
                                      label: const Text('Profil'),
                                    ),
                                    ElevatedButton.icon(
                                      onPressed: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) => ChatThreadScreen(
                                              sessionToken: widget.sessionToken,
                                              peerAccountId: f.accountId,
                                              peerName: f.name.isNotEmpty ? f.name : 'Kullanıcı',
                                            ),
                                          ),
                                        );
                                      },
                                      icon: const Icon(Icons.chat_bubble, size: 16),
                                      label: const Text('Mesaj Gönder'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

class _FriendAvatar extends StatelessWidget {
  final _FriendItem item;

  const _FriendAvatar({required this.item});

  @override
  Widget build(BuildContext context) {
    final url = item.avatarUrl.trim();
    if (url.isNotEmpty) {
      return CircleAvatar(
        radius: 22,
        backgroundImage: NetworkImage(url),
        backgroundColor: const Color(0xFF1F2937),
      );
    }
    final label = item.name.isNotEmpty ? item.name.substring(0, 1).toUpperCase() : '?';
    return CircleAvatar(
      radius: 22,
      backgroundColor: const Color(0xFFE53935),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _SocialInfoCard extends StatelessWidget {
  final String text;
  const _SocialInfoCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(text, style: TextStyle(color: Colors.white.withOpacity(0.8))),
    );
  }
}

class _SocialErrorCard extends StatelessWidget {
  final Future<void> Function() onRetry;
  const _SocialErrorCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Sosyal liste yüklenemedi.',
              style: TextStyle(color: Colors.white.withOpacity(0.85)),
            ),
          ),
          TextButton(
            onPressed: () => onRetry(),
            child: const Text('Tekrar Dene'),
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
  final String avatarUrl;

  const _FriendItem({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
  });

  factory _FriendItem.fromJson(Map<String, dynamic> json) {
    return _FriendItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatar'] ?? '').toString(),
    );
  }
}
