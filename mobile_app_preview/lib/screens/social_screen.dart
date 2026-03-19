import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/event_social_api.dart';
import '../services/i18n.dart';
import '../services/notification_center.dart';
import '../theme/app_theme.dart';
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
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  List<SocialUserItem> _searchItems = const [];
  bool _searchLoading = false;
  String _searchError = '';
  bool _addFriendsOpen = false;
  bool _searchHasMore = false;
  bool _searchHasTyped = false;
  int _searchOffset = 0;
  int _searchMinQueryLength = 2;
  static const int _searchPageSize = 20;

  @override
  void initState() {
    super.initState();
    _future = _fetchFriends();
    _incomingFuture = _fetchIncoming();
    NotificationCenter.refresh(widget.sessionToken);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
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
    if (_addFriendsOpen && _searchCtrl.text.trim().length >= _searchMinQueryLength) {
      await _runSearch();
    }
    await NotificationCenter.refresh(widget.sessionToken);
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
    await NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _reject(int requestId) async {
    await EventSocialApi.rejectFriendRequest(
      sessionToken: widget.sessionToken,
      requestId: requestId,
    );
    if (!mounted) return;
    setState(() => _incomingFuture = _fetchIncoming());
    await NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _runSearch() async {
    await _runSearchPage(reset: true);
  }

  void _scheduleSearch() {
    _searchDebounce?.cancel();
    final q = _searchCtrl.text.trim();
    setState(() {
      _searchHasTyped = q.isNotEmpty;
      if (q.isEmpty) {
        _searchItems = const [];
        _searchError = '';
        _searchOffset = 0;
        _searchHasMore = false;
      }
    });
    if (q.isEmpty) return;
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      _runSearch();
    });
  }

  Future<void> _runSearchPage({required bool reset}) async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      if (!mounted) return;
      setState(() {
        _searchHasTyped = false;
        _searchLoading = false;
        _searchError = '';
        _searchItems = const [];
        _searchOffset = 0;
        _searchHasMore = false;
      });
      return;
    }
    setState(() {
      _searchHasTyped = q.isNotEmpty;
      _searchLoading = true;
      _searchError = '';
    });
    try {
      final result = await EventSocialApi.searchUsers(
        sessionToken: widget.sessionToken,
        query: q,
        limit: _searchPageSize,
        offset: reset ? 0 : _searchOffset,
      );
      if (!mounted) return;
      setState(() {
        _searchMinQueryLength = result.minQueryLength;
        _searchItems = reset ? result.items : [..._searchItems, ...result.items];
        _searchHasMore = result.hasMore;
        _searchOffset = result.nextOffset ?? _searchItems.length;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _searchError = e.toString());
    } finally {
      if (mounted) setState(() => _searchLoading = false);
    }
  }

  Future<void> _toggleAddFriendsPanel() async {
    final next = !_addFriendsOpen;
    setState(() => _addFriendsOpen = next);
  }

  Future<void> _sendFriendRequest(SocialUserItem user) async {
    try {
      await EventSocialApi.sendFriendRequestDirect(
        sessionToken: widget.sessionToken,
        targetAccountId: user.accountId,
      );
      await _runSearchPage(reset: true);
      if (!mounted) return;
      setState(() => _incomingFuture = _fetchIncoming());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Arkadaşlık isteği gönderildi.')),
      );
      await NotificationCenter.refresh(widget.sessionToken);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _cancelFriendRequest(int requestId) async {
    try {
      await EventSocialApi.cancelFriendRequest(
        sessionToken: widget.sessionToken,
        requestId: requestId,
      );
      await _runSearchPage(reset: true);
      if (!mounted) return;
      setState(() => _incomingFuture = _fetchIncoming());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İstek geri çekildi.')),
      );
      await NotificationCenter.refresh(widget.sessionToken);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _openChat(_FriendItem friend) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          sessionToken: widget.sessionToken,
          peerAccountId: friend.accountId,
          peerName: friend.name.isNotEmpty ? friend.name : I18n.t('user'),
          peerAvatarUrl: friend.avatarUrl,
        ),
      ),
    );
    if (!mounted) return;
    await _refresh();
    await NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _openFriendProfile(_FriendItem friend) async {
    final removed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(
          sessionToken: widget.sessionToken,
          friendAccountId: friend.accountId,
        ),
      ),
    );
    if (!mounted) return;
    if (removed == true) {
      setState(() => _future = _fetchFriends());
    }
    await _refresh();
    await NotificationCenter.refresh(widget.sessionToken);
  }

  void _showAvatarPreview(String avatarUrl, String name) {
    final url = avatarUrl.trim();
    if (url.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Container(
                    padding: const EdgeInsets.all(20),
                    color: const Color(0xFF111827),
                    child: Text(name.isEmpty ? 'Görsel açılamadı' : name),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 6,
              child: IconButton(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return ScreenShell(
      title: t('social'),
      icon: Icons.groups,
      subtitle: t('social_subtitle'),
      tone: AppTone.social,
      onRefresh: _refresh,
      content: [
        FutureBuilder<List<FriendRequestItem>>(
          future: _incomingFuture,
          builder: (context, snapshot) {
            final reqs = snapshot.data ?? const <FriendRequestItem>[];
            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(14),
              decoration: AppTheme.panel(tone: AppTone.social, radius: 18, subtle: true),
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
                      style: const TextStyle(color: AppTheme.textSecondary),
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
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: AppTheme.panel(tone: AppTone.social, radius: 18, elevated: true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: _toggleAddFriendsPanel,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Arkadaş Ekle',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                      ),
                      Icon(
                        _addFriendsOpen ? Icons.expand_less : Icons.expand_more,
                        color: Colors.white70,
                      ),
                    ],
                  ),
                ),
              ),
              if (_addFriendsOpen) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) => _scheduleSearch(),
                        onSubmitted: (_) => _runSearch(),
                        decoration: InputDecoration(
                          hintText: 'En az $_searchMinQueryLength harf ile ara',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _searchLoading ? null : _runSearch,
                      child: Text(_searchLoading ? '...' : 'Ara'),
                    ),
                  ],
                ),
                if (_searchError.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(_searchError, style: const TextStyle(color: Colors.redAccent)),
                ],
                if (_searchCtrl.text.trim().isEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Tum kullanicilar otomatik listelenmez. Kullanici bulmak icin arama yapin.',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                ] else if (_searchCtrl.text.trim().length < _searchMinQueryLength) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Arama yapmak icin en az $_searchMinQueryLength harf yazin.',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                ] else if (_searchLoading && _searchItems.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Center(child: CircularProgressIndicator()),
                ] else if (_searchHasTyped && _searchItems.isEmpty && _searchError.isEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Sonuc bulunamadi.',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
                if (_searchItems.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  ..._searchItems.map(
                    (u) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: AppTheme.glassPanel(tone: AppTone.social, radius: 16),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: AppTheme.surfaceElevated,
                            backgroundImage: u.avatarUrl.trim().isNotEmpty ? NetworkImage(u.avatarUrl.trim()) : null,
                            child: u.avatarUrl.trim().isNotEmpty
                                ? null
                                : Text(
                                    (u.name.isNotEmpty ? u.name[0] : '?').toUpperCase(),
                                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                                  ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  u.name.isNotEmpty ? u.name : t('user'),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                          ),
                          if (u.friendStatus == 'friend')
                            const Text('Arkadaş', style: TextStyle(color: AppTheme.success))
                          else if (u.friendStatus == 'pending_outgoing')
                            OutlinedButton(
                              onPressed: (u.friendRequestId ?? 0) > 0
                                  ? () => _cancelFriendRequest(u.friendRequestId!)
                                  : null,
                              child: const Text('Geri Çek'),
                            )
                          else if (u.friendStatus == 'pending_incoming')
                            const Text('Sana istek gönderdi', style: TextStyle(color: AppTheme.warning))
                          else
                            ElevatedButton(
                              onPressed: () => _sendFriendRequest(u),
                              child: const Text('Ekle'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_searchHasMore) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton(
                        onPressed: _searchLoading ? null : () => _runSearchPage(reset: false),
                        child: Text(_searchLoading ? '...' : 'Daha Fazla'),
                      ),
                    ),
                  ],
                ],
              ],
            ],
          ),
        ),
        if (_unreadTotal > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: AppTheme.panel(tone: AppTone.social, radius: 16, subtle: true),
            child: Row(
              children: [
                const Icon(Icons.mark_chat_unread, color: AppTheme.pink, size: 18),
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
                    (f) => Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: AppTheme.panel(
                        tone: AppTone.social,
                        radius: 18,
                        elevated: f.unreadCount > 0,
                        subtle: f.unreadCount <= 0,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _FriendAvatar(
                            item: f,
                            onTap: () => _showAvatarPreview(f.avatarUrl, f.name),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _openFriendProfile(f),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          f.name.isNotEmpty ? f.name : t('user'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                        ),
                                      ),
                                      if (f.unreadCount > 0)
                                        Container(
                                          margin: const EdgeInsets.only(left: 8),
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: AppTheme.pink,
                                            borderRadius: BorderRadius.circular(999),
                                          ),
                                          child: Text(
                                            f.unreadCount > 99 ? '99+' : '${f.unreadCount}',
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          _MessageActionButton(onTap: () => _openChat(f)),
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
  final VoidCallback onTap;

  const _FriendAvatar({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final url = item.avatarUrl.trim();
    if (url.isNotEmpty) {
        return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(28),
        child: CircleAvatar(
          radius: 24,
          backgroundImage: NetworkImage(url),
          backgroundColor: AppTheme.surfaceElevated,
        ),
      );
    }
    final label = item.name.isNotEmpty ? item.name.substring(0, 1).toUpperCase() : '?';
    return CircleAvatar(
      radius: 24,
      backgroundColor: AppTheme.pink.withOpacity(0.84),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _MessageActionButton extends StatelessWidget {
  final VoidCallback onTap;

  const _MessageActionButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.violet.withOpacity(0.12),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: SizedBox(
          width: 42,
          height: 42,
          child: Icon(
            Icons.chat_bubble_outline_rounded,
            color: AppTheme.violet,
            size: 20,
          ),
        ),
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
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.social, radius: 18, subtle: true),
      child: Text(text, style: const TextStyle(color: AppTheme.textSecondary)),
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
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.danger, radius: 18, subtle: true),
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
