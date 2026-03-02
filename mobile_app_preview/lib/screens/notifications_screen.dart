import 'package:flutter/material.dart';

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
  late Future<NotificationSummary> _future;

  @override
  void initState() {
    super.initState();
    _future = NotificationsApi.fetchSummary(widget.sessionToken);
  }

  Future<void> _refresh() async {
    setState(() => _future = NotificationsApi.fetchSummary(widget.sessionToken));
    await _future;
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
        child: FutureBuilder<NotificationSummary>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: TextButton(
                  onPressed: _refresh,
                  child: const Text('Bildirimler yüklenemedi, tekrar dene'),
                ),
              );
            }
            final s = snapshot.data ??
                const NotificationSummary(
                  totalCount: 0,
                  incomingFriendRequestsCount: 0,
                  unreadMessagesCount: 0,
                );
            return ListView(
              padding: const EdgeInsets.all(14),
              children: [
                _card(
                  title: 'Toplam Bildirim',
                  value: s.totalCount.toString(),
                  icon: Icons.notifications_active,
                  color: s.totalCount > 0 ? Colors.redAccent : Colors.white70,
                ),
                const SizedBox(height: 10),
                _card(
                  title: 'Gelen Arkadaşlık İstekleri',
                  value: s.incomingFriendRequestsCount.toString(),
                  icon: Icons.group_add,
                  color: s.incomingFriendRequestsCount > 0 ? Colors.orangeAccent : Colors.white70,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SocialScreen(sessionToken: widget.sessionToken),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 10),
                _card(
                  title: 'Okunmamış Mesajlar',
                  value: s.unreadMessagesCount.toString(),
                  icon: Icons.mark_chat_unread,
                  color: s.unreadMessagesCount > 0 ? Colors.redAccent : Colors.white70,
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => MessagesInboxScreen(sessionToken: widget.sessionToken),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Yenile'),
                ),
              ],
            );
          },
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

