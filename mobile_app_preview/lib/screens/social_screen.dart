import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/event_social_api.dart';
import '../services/i18n.dart';
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
  int _unreadTotal = 0;

  @override
  void initState() {
    super.initState();
    _future = _fetchFriends();
    _incomingFuture = _fetchIncoming();
  }

  Future<List<_FriendItem>> _fetchFriends() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) throw Exception('Oturum bulunamadı');

    final friendResp = await http.get(
      Uri.parse('$_base/profile/friends'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (friendResp.statusCode != 200) {
      throw Exception('Arkadaş listesi alınamadı');
    }
    final friendBody = jsonDecode(friendResp.body) as Map<String, dynamic>;
    final friends = (friendBody['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_FriendItem.fromJson)
        .toList();

    final inboxResp = await http.get(
      Uri.parse('$_base/messages'),
      headers: {'Authorization': 'Bearer $token'},
    );
    final inboxMap = <int, _InboxLite>{};
    int unreadTotal = 0;
    if (inboxResp.statusCode == 200) {
      final inboxBody = jsonDecode(inboxResp.body) as Map<String, dynamic>;
      final inboxRows = (inboxBody['items'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(_InboxLite.fromJson)
          .toList();
      for (final row in inboxRows) {
        inboxMap[row.accountId] = row;
        unreadTotal += row.unreadCount;
      }
    }

    if (mounted && _unreadTotal != unreadTotal) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() => _unreadTotal = unreadTotal);
      });
    }

    final merged = friends
        .map((f) {
          final ib = inboxMap[f.accountId];
          return f.copyWith(
            unreadCount: ib?.unreadCount ?? 0,
            lastMessageAt: ib?.lastAt ?? '',
          );
        })
        .toList();

    merged.sort((a, b) {
      final aUnread = a.unreadCount > 0 ? 1 : 0;
      final bUnread = b.unreadCount > 0 ? 1 : 0;
      if (aUnread != bUnread) return bUnread.compareTo(aUnread);
      if (a.unreadCount != b.unreadCount) return b.unreadCount.compareTo(a.unreadCount);
      final byLast = b.lastMessageAt.compareTo(a.lastMessageAt);
      if (byLast != 0) return byLast;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

    return merged;
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
    final t = I18n.t;
    return ScreenShell(
      title: t('social'),
      icon: Icons.groups,
      subtitle: t('social_subtitle'),
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
                    reqs.isEmpty ? t('incoming_requests') : '${t('incoming_requests')} (${reqs.length})',
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
                      t('no_pending_friend_request'),
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
                                r.peerName.isNotEmpty ? r.peerName : t('user'),
                                style: const TextStyle(fontWeight: FontWeight.w600),
                              ),
                            ),
                            TextButton(
                              onPressed: () => _reject(r.requestId),
                              child: Text(t('reject')),
                            ),
                            ElevatedButton(
                              onPressed: () => _accept(r.requestId),
                              child: Text(t('accept')),
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
        if (_unreadTotal > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF1D1520),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.redAccent),
            ),
            child: Row(
              children: [
                const Icon(Icons.mark_chat_unread, color: Colors.redAccent, size: 18),
                const SizedBox(width: 8),
                Text('${t('unread_message')}: $_unreadTotal', style: const TextStyle(fontWeight: FontWeight.w700)),
              ],
            ),
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
              return _SocialInfoCard(text: t('no_friends_yet'));
            }
            return Column(
              children: items
                  .map(
                    (f) => Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ChatThreadScreen(
                                sessionToken: widget.sessionToken,
                                peerAccountId: f.accountId,
                                peerName: f.name.isNotEmpty ? f.name : t('user'),
                              ),
                            ),
                          );
                          if (!mounted) return;
                          await _refresh();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: f.unreadCount > 0 ? const Color(0xFF1D1520) : const Color(0xFF121826),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: f.unreadCount > 0 ? Colors.redAccent : Colors.white12),
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
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            f.name.isNotEmpty ? f.name : t('user'),
                                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                        if (f.unreadCount > 0)
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.redAccent,
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              f.unreadCount > 99 ? '99+' : '${f.unreadCount}',
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                                            ),
                                          ),
                                      ],
                                    ),
                                    if (f.email.isNotEmpty)
                                      Text(
                                        f.email,
                                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                                      ),
                                    if (f.lastMessageAt.isNotEmpty)
                                      Text(
                                        '${t('last_message')}: ${f.lastMessageAt}',
                                        style: TextStyle(
                                          color: f.unreadCount > 0 ? Colors.redAccent : Colors.white70,
                                          fontSize: 12,
                                          fontWeight: f.unreadCount > 0 ? FontWeight.w600 : FontWeight.w400,
                                        ),
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
                                          label: Text(t('profile')),
                                        ),
                                        ElevatedButton.icon(
                                          onPressed: () async {
                                            await Navigator.of(context).push(
                                              MaterialPageRoute(
                                                builder: (_) => ChatThreadScreen(
                                                  sessionToken: widget.sessionToken,
                                                  peerAccountId: f.accountId,
                                                  peerName: f.name.isNotEmpty ? f.name : t('user'),
                                                ),
                                              ),
                                            );
                                            if (!mounted) return;
                                            await _refresh();
                                          },
                                          icon: const Icon(Icons.chat_bubble, size: 16),
                                          label: Text(t('send_message')),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
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
              I18n.t('social_list_error'),
              style: TextStyle(color: Colors.white.withOpacity(0.85)),
            ),
          ),
          TextButton(
            onPressed: () => onRetry(),
            child: Text(I18n.t('retry')),
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
  final int unreadCount;
  final String lastMessageAt;

  const _FriendItem({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.unreadCount,
    required this.lastMessageAt,
  });

  factory _FriendItem.fromJson(Map<String, dynamic> json) {
    return _FriendItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatar'] ?? '').toString(),
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastMessageAt: (json['last_at'] ?? '').toString(),
    );
  }

  _FriendItem copyWith({
    int? accountId,
    String? name,
    String? email,
    String? avatarUrl,
    int? unreadCount,
    String? lastMessageAt,
  }) {
    return _FriendItem(
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      unreadCount: unreadCount ?? this.unreadCount,
      lastMessageAt: lastMessageAt ?? this.lastMessageAt,
    );
  }
}

class _InboxLite {
  final int accountId;
  final int unreadCount;
  final String lastAt;

  const _InboxLite({
    required this.accountId,
    required this.unreadCount,
    required this.lastAt,
  });

  factory _InboxLite.fromJson(Map<String, dynamic> json) {
    return _InboxLite(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastAt: (json['last_at'] ?? '').toString(),
    );
  }
}
