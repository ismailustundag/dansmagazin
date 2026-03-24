import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/date_time_format.dart';
import '../widgets/emoji_text.dart';
import 'chat_thread_screen.dart';
import 'screen_shell.dart';

class MessagesScreen extends StatefulWidget {
  final bool isLoggedIn;
  final String sessionToken;
  final VoidCallback onLoginTap;

  const MessagesScreen({
    super.key,
    required this.isLoggedIn,
    required this.sessionToken,
    required this.onLoginTap,
  });

  @override
  State<MessagesScreen> createState() => _MessagesScreenState();
}

class _MessagesScreenState extends State<MessagesScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_InboxItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchInbox();
  }

  @override
  void didUpdateWidget(covariant MessagesScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionToken != widget.sessionToken || oldWidget.isLoggedIn != widget.isLoggedIn) {
      _future = _fetchInbox();
    }
  }

  Future<List<_InboxItem>> _fetchInbox() async {
    if (!widget.isLoggedIn || widget.sessionToken.trim().isEmpty) return [];
    final resp = await http.get(
      Uri.parse('$_base/messages'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Mesajlar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => _InboxItem.fromJson(e as Map<String, dynamic>))
        .map((e) => e.copyWith(lastAt: formatDateTimeDdMmYyyyHmDot(e.lastAt)))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isLoggedIn) {
      return ScreenShell(
        title: 'Mesajlar',
        icon: Icons.chat_bubble,
        subtitle: 'Mesajları görmek için giriş yapın.',
        content: [
          PreviewCard(
            title: 'Giriş Yap',
            subtitle: 'Arkadaşlarınla mesajlaşmak için',
            icon: Icons.login,
            onTap: widget.onLoginTap,
          ),
        ],
      );
    }

    return ScreenShell(
      title: 'Mesajlar',
      icon: Icons.chat_bubble,
      subtitle: 'Arkadaşların ve mesajlaşmaların.',
      content: [
        FutureBuilder<List<_InboxItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return PreviewCard(
                title: 'Mesajlar yüklenemedi',
                subtitle: 'Tekrar denemek için dokun',
                icon: Icons.error_outline,
                onTap: () => setState(() => _future = _fetchInbox()),
              );
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return const PreviewCard(
                title: 'Henüz konuşma yok',
                subtitle: 'Arkadaşlarını ekleyip mesajlaşmaya başlayabilirsin.',
                icon: Icons.people_outline,
              );
            }
            return Column(
              children: [
                ...items.map(
                  (m) => PreviewCard(
                    title: m.name,
                    titleWidget: EmojiText(
                      m.name,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 15),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: m.lastAt.isNotEmpty ? 'Son mesaj: ${m.lastAt}' : 'Henüz mesaj yok, yazmaya başla',
                    icon: Icons.person,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => ChatThreadScreen(
                            sessionToken: widget.sessionToken,
                            peerAccountId: m.accountId,
                            peerName: m.name,
                            peerAvatarUrl: m.avatarUrl,
                            peerIsVerified: m.isVerified,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _InboxItem {
  final int accountId;
  final String name;
  final bool isVerified;
  final String lastAt;
  final String avatarUrl;

  const _InboxItem({
    required this.accountId,
    required this.name,
    required this.isVerified,
    required this.lastAt,
    required this.avatarUrl,
  });

  _InboxItem copyWith({
    int? accountId,
    String? name,
    bool? isVerified,
    String? lastAt,
    String? avatarUrl,
  }) {
    return _InboxItem(
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      isVerified: isVerified ?? this.isVerified,
      lastAt: lastAt ?? this.lastAt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }

  factory _InboxItem.fromJson(Map<String, dynamic> json) {
    return _InboxItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
      lastAt: (json['last_at'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
    );
  }
}
