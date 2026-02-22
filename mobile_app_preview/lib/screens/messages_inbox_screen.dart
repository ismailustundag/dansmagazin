import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'chat_thread_screen.dart';

class MessagesInboxScreen extends StatefulWidget {
  final String sessionToken;

  const MessagesInboxScreen({super.key, required this.sessionToken});

  @override
  State<MessagesInboxScreen> createState() => _MessagesInboxScreenState();
}

class _MessagesInboxScreenState extends State<MessagesInboxScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_InboxItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchInbox();
  }

  Future<List<_InboxItem>> _fetchInbox() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) throw Exception('Oturum bulunamadı');
    final resp = await http.get(
      Uri.parse('$_base/messages'),
      headers: {'Authorization': 'Bearer $token'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Mesajlar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => _InboxItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: const Text('Mesajlarım'),
      ),
      body: FutureBuilder<List<_InboxItem>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () => setState(() => _future = _fetchInbox()),
                child: const Text('Mesajlar yüklenemedi, tekrar dene'),
              ),
            );
          }
          final items = snapshot.data ?? [];
          if (items.isEmpty) {
            return const Center(child: Text('Henüz mesaj konuşmanız yok.'));
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: items.length,
            itemBuilder: (_, i) {
              final m = items[i];
              return InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChatThreadScreen(
                        sessionToken: widget.sessionToken,
                        peerAccountId: m.accountId,
                        peerName: m.name,
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
                        child: Icon(Icons.chat_bubble, color: Colors.white),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                            if (m.lastAt.isNotEmpty)
                              Text('Son mesaj: ${m.lastAt}', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, color: Colors.white54),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _InboxItem {
  final int accountId;
  final String name;
  final String lastAt;

  const _InboxItem({required this.accountId, required this.name, required this.lastAt});

  factory _InboxItem.fromJson(Map<String, dynamic> json) {
    return _InboxItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      lastAt: (json['last_at'] ?? '').toString(),
    );
  }
}
