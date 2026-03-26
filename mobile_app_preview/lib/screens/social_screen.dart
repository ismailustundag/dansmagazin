import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/auth_api.dart';
import '../services/event_social_api.dart';
import '../services/i18n.dart';
import '../services/notification_center.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';
import 'chat_thread_screen.dart';
import 'friend_profile_screen.dart';
import 'screen_shell.dart';

BoxDecoration _friendCardDecoration({required bool hasUnread}) {
  if (!hasUnread) {
    return AppTheme.panel(tone: AppTone.social, radius: 16, subtle: true);
  }
  return BoxDecoration(
    borderRadius: BorderRadius.circular(16),
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(AppTheme.pink.withOpacity(0.14), AppTheme.surfaceSecondary),
        Color.alphaBlend(AppTheme.violet.withOpacity(0.12), AppTheme.surfaceElevated),
      ],
    ),
    border: Border.all(color: AppTheme.pink.withOpacity(0.42), width: 1.15),
    boxShadow: [
      BoxShadow(
        color: AppTheme.pink.withOpacity(0.08),
        blurRadius: 14,
        offset: const Offset(0, 6),
      ),
    ],
  );
}

class SocialScreen extends StatefulWidget {
  final String sessionToken;
  final bool initiallyOpenAddFriends;
  final int openAddFriendsToken;

  const SocialScreen({
    super.key,
    required this.sessionToken,
    this.initiallyOpenAddFriends = false,
    this.openAddFriendsToken = 0,
  });

  @override
  State<SocialScreen> createState() => _SocialScreenState();
}

class _SocialScreenState extends State<SocialScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_FriendItem>> _future;
  late Future<List<FriendRequestItem>> _incomingFuture;
  late Future<List<FriendRequestItem>> _outgoingFuture;
  int _lastUnreadSummaryCount = 0;
  int _lastIncomingRequestCount = 0;
  final TextEditingController _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  Timer? _liveRefreshDebounce;
  List<_FriendItem> _cachedFriends = const [];
  List<FriendRequestItem> _cachedIncomingRequests = const [];
  List<FriendRequestItem> _cachedOutgoingRequests = const [];
  List<SocialUserItem> _searchItems = const [];
  bool _searchLoading = false;
  String _searchError = '';
  bool _addFriendsOpen = false;
  bool _searchHasMore = false;
  bool _searchHasTyped = false;
  int _searchOffset = 0;
  int _searchMinQueryLength = 2;
  static const int _searchPageSize = 20;
  int? _myAccountId;
  bool _loadingMyQr = false;
  bool _processingQr = false;

  @override
  void initState() {
    super.initState();
    _addFriendsOpen =
        widget.initiallyOpenAddFriends || widget.openAddFriendsToken > 0;
    _future = _fetchFriends();
    _incomingFuture = _fetchIncoming();
    _outgoingFuture = _fetchOutgoing();
    final summary = NotificationCenter.summary.value;
    _lastUnreadSummaryCount = summary.unreadMessagesCount;
    _lastIncomingRequestCount = summary.incomingFriendRequestsCount;
    NotificationCenter.summary.addListener(_onNotificationSummaryChanged);
    NotificationCenter.refresh(widget.sessionToken);
    _loadMyAccountId();
  }

  @override
  void didUpdateWidget(covariant SocialScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openAddFriendsToken != oldWidget.openAddFriendsToken &&
        widget.openAddFriendsToken > 0) {
      setState(() {
        _addFriendsOpen = true;
        _incomingFuture = _fetchIncoming();
        _outgoingFuture = _fetchOutgoing();
      });
    }
  }

  @override
  void dispose() {
    NotificationCenter.summary.removeListener(_onNotificationSummaryChanged);
    _searchDebounce?.cancel();
    _liveRefreshDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onNotificationSummaryChanged() {
    if (!mounted) return;
    final summary = NotificationCenter.summary.value;
    final unreadChanged =
        summary.unreadMessagesCount != _lastUnreadSummaryCount;
    final requestsChanged =
        summary.incomingFriendRequestsCount != _lastIncomingRequestCount;
    if (!unreadChanged && !requestsChanged) return;

    _lastUnreadSummaryCount = summary.unreadMessagesCount;
    _lastIncomingRequestCount = summary.incomingFriendRequestsCount;

    _liveRefreshDebounce?.cancel();
    _liveRefreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      setState(() {
        _future = _fetchFriends();
        if (unreadChanged && !requestsChanged) {
          // Arkadaş listesi zaten _future ile tazeleniyor.
        }
        if (requestsChanged) {
          _incomingFuture = _fetchIncoming();
          _outgoingFuture = _fetchOutgoing();
        }
      });
    });
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

    _cachedFriends = merged;
    return merged;
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _fetchFriends();
      _incomingFuture = _fetchIncoming();
      _outgoingFuture = _fetchOutgoing();
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
    ).then((items) {
      _cachedIncomingRequests = items;
      return items;
    });
  }

  Future<List<FriendRequestItem>> _fetchOutgoing() {
    return EventSocialApi.friendRequests(
      sessionToken: widget.sessionToken,
      direction: 'outgoing',
    ).then((items) {
      _cachedOutgoingRequests = items;
      return items;
    });
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

  Future<void> _loadMyAccountId() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) return;
    setState(() => _loadingMyQr = true);
    try {
      final session = await AuthApi.me(token);
      if (!mounted) return;
      setState(() => _myAccountId = session.accountId > 0 ? session.accountId : null);
    } catch (_) {
      if (mounted) setState(() => _myAccountId = null);
    } finally {
      if (mounted) setState(() => _loadingMyQr = false);
    }
  }

  String get _friendQrPayload {
    final id = _myAccountId;
    if (id == null || id <= 0) return '';
    return 'dmfriend:$id';
  }

  Future<void> _openQrScanner() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('QR ile arkadaş eklemek için giriş yapmalısın.')),
      );
      return;
    }
    final payload = await Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const _FriendQrScannerScreen()),
    );
    if (!mounted || payload == null || payload.trim().isEmpty) return;
    setState(() => _processingQr = true);
    try {
      final result = await EventSocialApi.connectFriendByQr(
        sessionToken: token,
        payload: payload,
      );
      if (!mounted) return;
      final status = (result['status'] ?? '').toString();
      setState(() {
        _future = _fetchFriends();
        _incomingFuture = _fetchIncoming();
        _outgoingFuture = _fetchOutgoing();
      });
      if (_addFriendsOpen && _searchCtrl.text.trim().length >= _searchMinQueryLength) {
        await _runSearch();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'already_friends'
                ? 'Bu kullanıcı zaten arkadaş listende.'
                : 'Arkadaş başarıyla eklendi.',
          ),
        ),
      );
      await NotificationCenter.refresh(widget.sessionToken);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _processingQr = false);
    }
  }

  void _showMyQrDialog() {
    final payload = _friendQrPayload;
    final accountId = _myAccountId;
    if (payload.isEmpty || accountId == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: Container(
          padding: const EdgeInsets.all(20),
          decoration: AppTheme.panel(tone: AppTone.social, radius: 24, elevated: true),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Arkadaşlık QR Kodu',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(
                'Profil ID: $accountId',
                style: const TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 18),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: QrImageView(
                  data: payload,
                  size: 220,
                  eyeStyle: const QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: Colors.black,
                  ),
                  dataModuleStyle: const QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: Colors.black,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Arkadaş ekle ekranındaki QR ile Ekle butonundan bu kod okutulabilir.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Kapat'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _headerQr() {
    if (_loadingMyQr) {
      return const SizedBox(
        width: 68,
        height: 68,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final payload = _friendQrPayload;
    if (payload.isEmpty) return const SizedBox.shrink();
    return InkWell(
      onTap: _showMyQrDialog,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        width: 68,
        height: 68,
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withOpacity(0.96),
              const Color(0xFFF5F7FF),
            ],
          ),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: AppTheme.borderSoft),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: ColoredBox(
            color: Colors.white,
            child: QrImageView(
              data: payload,
              size: 58,
              padding: EdgeInsets.zero,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Colors.black,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Colors.black,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _sendFriendRequest(SocialUserItem user) async {
    try {
      await EventSocialApi.sendFriendRequestDirect(
        sessionToken: widget.sessionToken,
        targetAccountId: user.accountId,
      );
      await _runSearchPage(reset: true);
      if (!mounted) return;
      setState(() {
        _incomingFuture = _fetchIncoming();
        _outgoingFuture = _fetchOutgoing();
      });
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
      setState(() {
        _incomingFuture = _fetchIncoming();
        _outgoingFuture = _fetchOutgoing();
      });
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
          peerIsVerified: friend.isVerified,
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
      subtitle: '',
      headerTrailing: _headerQr(),
      tone: AppTone.social,
      onRefresh: _refresh,
      content: [
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: AppTheme.panel(tone: AppTone.social, radius: 18, elevated: true),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: InkWell(
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
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton.icon(
                    onPressed: _processingQr ? null : _openQrScanner,
                    icon: const Icon(Icons.qr_code_scanner_rounded),
                    label: Text(_processingQr ? '...' : 'QR ile Ekle'),
                  ),
                ],
              ),
              if (_addFriendsOpen) ...[
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    FutureBuilder<List<FriendRequestItem>>(
                      future: _incomingFuture,
                      builder: (context, snapshot) {
                        final reqs = snapshot.data ?? _cachedIncomingRequests;
                        final loading =
                            snapshot.connectionState == ConnectionState.waiting &&
                            reqs.isEmpty;
                        if (!loading && reqs.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _RequestColumn(
                            title: t('incoming_requests'),
                            count: reqs.length,
                            loading: loading,
                            emptyText: t('no_pending_friend_request'),
                            children: reqs
                                .map(
                                  (r) => _RequestRow(
                                    name: r.peerName.isNotEmpty ? r.peerName : t('user'),
                                    primaryLabel: t('accept'),
                                    primaryAction: () => _accept(r.requestId),
                                    secondaryLabel: t('reject'),
                                    secondaryAction: () => _reject(r.requestId),
                                  ),
                                )
                                .toList(),
                          ),
                        );
                      },
                    ),
                    FutureBuilder<List<FriendRequestItem>>(
                      future: _outgoingFuture,
                      builder: (context, snapshot) {
                        final reqs = snapshot.data ?? _cachedOutgoingRequests;
                        final loading =
                            snapshot.connectionState == ConnectionState.waiting &&
                            reqs.isEmpty;
                        if (!loading && reqs.isEmpty) {
                          return const SizedBox.shrink();
                        }
                        return _RequestColumn(
                          title: 'Bekleyen İstekler',
                          count: reqs.length,
                          loading: loading,
                          emptyText: 'Bekleyen istek yok.',
                          children: reqs
                              .map(
                                (r) => _RequestRow(
                                  name: r.peerName.isNotEmpty ? r.peerName : t('user'),
                                  primaryLabel: 'Geri Çek',
                                  primaryAction: () => _cancelFriendRequest(r.requestId),
                                ),
                              )
                              .toList(),
                        );
                      },
                    ),
                  ],
                ),
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
                  const SizedBox(height: 4),
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
                      key: ValueKey('search_user_${u.accountId}'),
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: AppTheme.glassPanel(tone: AppTone.social, radius: 16),
                      child: Row(
                        children: [
                          VerifiedAvatar(
                            imageUrl: u.avatarUrl,
                            label: u.name,
                            isVerified: u.isVerified,
                            radius: 16,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                EmojiText(
                                  u.name.isNotEmpty ? u.name : t('user'),
                                  style: const TextStyle(fontWeight: FontWeight.w600),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
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
        FutureBuilder<List<_FriendItem>>(
          future: _future,
          builder: (context, snapshot) {
            final items = snapshot.data ?? _cachedFriends;
            if (snapshot.connectionState == ConnectionState.waiting && items.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return _SocialErrorCard(onRetry: _refresh);
            }
            if (items.isEmpty) {
              return _SocialInfoCard(text: t('no_friends_yet'));
            }
            return Column(
              children: items
                  .map(
                    (f) => AnimatedContainer(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOutCubic,
                      key: ValueKey('friend_${f.accountId}'),
                      margin: const EdgeInsets.only(bottom: 7),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      decoration: _friendCardDecoration(hasUnread: f.unreadCount > 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          if (f.unreadCount > 0)
                            Container(
                              width: 4,
                              height: 42,
                              margin: const EdgeInsets.only(right: 10),
                              decoration: BoxDecoration(
                                color: AppTheme.pink,
                                borderRadius: BorderRadius.circular(999),
                              ),
                            ),
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
                                  padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            EmojiText(
                                              f.name.isNotEmpty ? f.name : t('user'),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w700,
                                                color: f.unreadCount > 0 ? Colors.white : null,
                                              ),
                                            ),
                                            if (f.unreadCount > 0) ...[
                                              const SizedBox(height: 4),
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  const Icon(
                                                    Icons.mark_chat_unread_rounded,
                                                    size: 12,
                                                    color: AppTheme.pink,
                                                  ),
                                                  const SizedBox(width: 4),
                                                  Flexible(
                                                    child: Text(
                                                      t('friend_card_new_message'),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: const TextStyle(
                                                        fontSize: 11.5,
                                                        fontWeight: FontWeight.w700,
                                                        color: AppTheme.pink,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ],
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

class _RequestColumn extends StatelessWidget {
  final String title;
  final int count;
  final bool loading;
  final String emptyText;
  final List<Widget> children;

  const _RequestColumn({
    required this.title,
    required this.count,
    required this.loading,
    required this.emptyText,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: AppTheme.glassPanel(tone: AppTone.social, radius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            count > 0 ? '$title ($count)' : title,
            style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          if (loading)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (children.isEmpty)
            Text(
              emptyText,
              style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            )
          else
            ...children,
        ],
      ),
    );
  }
}

class _RequestRow extends StatelessWidget {
  final String name;
  final String primaryLabel;
  final VoidCallback primaryAction;
  final String? secondaryLabel;
  final VoidCallback? secondaryAction;

  const _RequestRow({
    required this.name,
    required this.primaryLabel,
    required this.primaryAction,
    this.secondaryLabel,
    this.secondaryAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Expanded(
            child: EmojiText(
              name,
              style: const TextStyle(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (secondaryLabel != null && secondaryAction != null) ...[
            _SlimRequestButton(
              label: secondaryLabel!,
              onTap: secondaryAction!,
              outlined: true,
            ),
            const SizedBox(width: 6),
          ],
          _SlimRequestButton(
            label: primaryLabel,
            onTap: primaryAction,
          ),
        ],
      ),
    );
  }
}

class _SlimRequestButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool outlined;

  const _SlimRequestButton({
    required this.label,
    required this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final child = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        color: outlined ? Colors.white.withOpacity(0.84) : Colors.white,
      ),
    );
    if (outlined) {
      return OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
          side: BorderSide(color: Colors.white.withOpacity(0.14)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        ),
        child: child,
      );
    }
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      ),
      child: child,
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
        borderRadius: BorderRadius.circular(24),
        child: VerifiedAvatar(
          imageUrl: url,
          label: item.name,
          isVerified: item.isVerified,
          radius: 20,
        ),
      );
    }
    return VerifiedAvatar(
      imageUrl: '',
      label: item.name,
      isVerified: item.isVerified,
      radius: 20,
      backgroundColor: AppTheme.pink.withOpacity(0.84),
      fallbackStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
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
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 38,
          height: 38,
          child: Icon(
            Icons.chat_bubble_outline_rounded,
            color: AppTheme.violet,
            size: 18,
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
  final bool isVerified;
  final int unreadCount;
  final String lastMessageAt;

  const _FriendItem({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.isVerified,
    required this.unreadCount,
    required this.lastMessageAt,
  });

  factory _FriendItem.fromJson(Map<String, dynamic> json) {
    return _FriendItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? json['avatar'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
      unreadCount: (json['unread_count'] as num?)?.toInt() ?? 0,
      lastMessageAt: (json['last_at'] ?? '').toString(),
    );
  }

  _FriendItem copyWith({
    int? accountId,
    String? name,
    String? email,
    String? avatarUrl,
    bool? isVerified,
    int? unreadCount,
    String? lastMessageAt,
  }) {
    return _FriendItem(
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      email: email ?? this.email,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isVerified: isVerified ?? this.isVerified,
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

class _FriendQrScannerScreen extends StatefulWidget {
  const _FriendQrScannerScreen();

  @override
  State<_FriendQrScannerScreen> createState() => _FriendQrScannerScreenState();
}

class _FriendQrScannerScreenState extends State<_FriendQrScannerScreen> {
  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _scannerOpen = false;
  bool _handling = false;
  String _lastValue = '';
  DateTime _lastScanAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _openScanner();
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _openScanner() async {
    setState(() => _scannerOpen = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (!mounted || !_scannerOpen) return;
      await _scannerController.start();
    } catch (_) {
      if (!mounted) return;
      setState(() => _scannerOpen = false);
    }
  }

  Future<void> _closeScanner() async {
    setState(() => _scannerOpen = false);
    try {
      await _scannerController.stop();
    } catch (_) {}
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (!_scannerOpen || _handling) return;
    String payload = '';
    for (final code in capture.barcodes) {
      final raw = (code.rawValue ?? '').trim();
      if (raw.isNotEmpty) {
        payload = raw;
        break;
      }
    }
    if (payload.isEmpty) return;
    final now = DateTime.now();
    if (_lastValue == payload && now.difference(_lastScanAt).inMilliseconds < 1200) {
      return;
    }
    _lastValue = payload;
    _lastScanAt = now;
    _handling = true;
    await _closeScanner();
    if (!mounted) return;
    Navigator.of(context).pop(payload);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('QR ile Ekle')),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  decoration: AppTheme.panel(tone: AppTone.social, radius: 24, elevated: true),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Arkadaşının QR kodunu okut',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Sosyal ekranının sağ üstündeki küçük QR kod bu ekrandan okutulabilir.',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 16),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Container(
                            color: const Color(0xFF0A111B),
                            child: _scannerOpen
                                ? Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      MobileScanner(
                                        controller: _scannerController,
                                        onDetect: _onDetect,
                                      ),
                                      IgnorePointer(
                                        child: Center(
                                          child: Container(
                                            width: 220,
                                            height: 220,
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(24),
                                              border: Border.all(color: Colors.white70, width: 2.2),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : const Center(
                                    child: Icon(
                                      Icons.qr_code_scanner_rounded,
                                      size: 72,
                                      color: AppTheme.textSecondary,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  label: const Text('Kapat'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
