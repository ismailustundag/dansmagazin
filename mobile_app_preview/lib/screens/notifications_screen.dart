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
      final s = await NotificationsApi.fetchSummary(widget.sessionToken);
      if (!mounted) return;
      NotificationCenter.setSummary(s);
      setState(() {
        _summary = s;
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
}
