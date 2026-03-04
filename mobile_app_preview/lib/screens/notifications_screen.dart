import 'dart:async';

import 'package:flutter/material.dart';

import '../services/notification_center.dart';
import '../services/notifications_api.dart';
import 'messages_inbox_screen.dart';
import 'social_screen.dart';

class NotificationsScreen extends StatefulWidget {
  final String sessionToken;

  const NotificationsScreen({super.key, required this.sessionToken});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  NotificationSummary _summary = const NotificationSummary(
    totalCount: 0,
    incomingFriendRequestsCount: 0,
    unreadMessagesCount: 0,
  );
  List<NotificationFeedItem> _feed = const [];
  bool _loading = true;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    NotificationCenter.summary.addListener(_onExternalSummary);
    _summary = NotificationCenter.summary.value;
    _loading = false;
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    NotificationCenter.summary.removeListener(_onExternalSummary);
    super.dispose();
  }

  void _onExternalSummary() {
    if (!mounted) return;
    setState(() {
      _summary = NotificationCenter.summary.value;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<dynamic>([
        NotificationsApi.fetchSummary(widget.sessionToken),
        NotificationsApi.fetchFeed(widget.sessionToken, limit: 100),
      ]);
      final s = results[0] as NotificationSummary;
      final feed = results[1] as List<NotificationFeedItem>;
      if (!mounted) return;
      NotificationCenter.setSummary(s);
      setState(() {
        _summary = s;
        _feed = feed;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('Bildirimler'),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('Bildirimler yüklenemedi, tekrar dene'),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      _card(
                        title: 'Toplam Bildirim',
                        value: _summary.totalCount.toString(),
                        icon: Icons.notifications_active,
                        color: _summary.totalCount > 0 ? Colors.redAccent : Colors.white70,
                      ),
                      const SizedBox(height: 10),
                      _card(
                        title: 'Gelen Arkadaşlık İstekleri',
                        value: _summary.incomingFriendRequestsCount.toString(),
                        icon: Icons.group_add,
                        color: _summary.incomingFriendRequestsCount > 0 ? Colors.orangeAccent : Colors.white70,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => SocialScreen(sessionToken: widget.sessionToken),
                            ),
                          );
                          await _refresh(silent: true);
                        },
                      ),
                      const SizedBox(height: 10),
                      _card(
                        title: 'Okunmamış Mesajlar',
                        value: _summary.unreadMessagesCount.toString(),
                        icon: Icons.mark_chat_unread,
                        color: _summary.unreadMessagesCount > 0 ? Colors.redAccent : Colors.white70,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => MessagesInboxScreen(sessionToken: widget.sessionToken),
                            ),
                          );
                          await _refresh(silent: true);
                        },
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Son Bildirimler',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 8),
                      if (_feed.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF121826),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Text(
                            'Henüz bildirim yok.',
                            style: TextStyle(color: Colors.white.withOpacity(0.75)),
                          ),
                        )
                      else
                        ..._feed.map(
                          (n) => Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFF121826),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        n.title.trim().isEmpty ? 'Bildirim' : n.title.trim(),
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      _fmtDate(n.createdAt),
                                      style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  n.body,
                                  style: const TextStyle(color: Colors.white70),
                                ),
                                if (n.sentByName.trim().isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(
                                    'Gönderen: ${n.sentByName}',
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
      ),
    );
  }

  Widget _card({
    required String title,
    required String value,
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Colors.white10,
              child: Icon(icon, color: color),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            ),
            Text(
              value,
              style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtDate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return '-';
    final d = DateTime.tryParse(value);
    if (d == null) {
      final c = value.replaceAll('T', ' ');
      return c.length >= 16 ? c.substring(0, 16) : c;
    }
    final local = d.toLocal();
    final dd = local.day.toString().padLeft(2, '0');
    final mm = local.month.toString().padLeft(2, '0');
    final yyyy = local.year.toString();
    final hh = local.hour.toString().padLeft(2, '0');
    final mi = local.minute.toString().padLeft(2, '0');
    return '$dd.$mm.$yyyy $hh:$mi';
  }
}
