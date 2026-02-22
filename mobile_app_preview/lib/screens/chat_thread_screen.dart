import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ChatThreadScreen extends StatefulWidget {
  final String sessionToken;
  final int peerAccountId;
  final String peerName;

  const ChatThreadScreen({
    super.key,
    required this.sessionToken,
    required this.peerAccountId,
    required this.peerName,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  static const String _base = 'https://api2.dansmagazin.net';

  final _msgCtrl = TextEditingController();
  bool _sending = false;
  late Future<_ThreadData> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchThread();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<_ThreadData> _fetchThread() async {
    final t = widget.sessionToken.trim();
    final resp = await http.get(
      Uri.parse('$_base/messages?with_account_id=${widget.peerAccountId}&limit=200'),
      headers: {'Authorization': 'Bearer $t'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Mesajlar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final meId = (body['me_account_id'] as num?)?.toInt() ?? 0;
    final items = (body['items'] as List<dynamic>? ?? [])
        .map((e) => _MsgItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return _ThreadData(meAccountId: meId, items: items);
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      final resp = await http.post(
        Uri.parse('$_base/messages/send'),
        headers: {
          'Authorization': 'Bearer ${widget.sessionToken.trim()}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'to_account_id': widget.peerAccountId, 'body': text}),
      );
      if (resp.statusCode != 200) {
        String msg = 'Mesaj gönderilemedi';
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          msg = (j['detail'] ?? msg).toString();
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }
      _msgCtrl.clear();
      if (!mounted) return;
      setState(() => _future = _fetchThread());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: Text(widget.peerName),
      ),
      body: Column(
        children: [
          Expanded(
            child: FutureBuilder<_ThreadData>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: TextButton(
                      onPressed: () => setState(() => _future = _fetchThread()),
                      child: const Text('Mesajlar yüklenemedi, tekrar dene'),
                    ),
                  );
                }
                final data = snapshot.data!;
                if (data.items.isEmpty) {
                  return const Center(child: Text('Henüz mesaj yok.'));
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(12),
                  itemCount: data.items.length,
                  itemBuilder: (_, i) {
                    final m = data.items[i];
                    final mine = m.senderAccountId == data.meAccountId;
                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        constraints: const BoxConstraints(maxWidth: 280),
                        decoration: BoxDecoration(
                          color: mine ? const Color(0xFFE53935) : const Color(0xFF1F2937),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.body),
                            const SizedBox(height: 4),
                            Text(
                              m.createdAt,
                              style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              color: const Color(0xFF0F172A),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      minLines: 1,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: 'Mesaj yaz...',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _sending ? null : _send,
                    child: _sending
                        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Text('Gönder'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThreadData {
  final int meAccountId;
  final List<_MsgItem> items;

  const _ThreadData({required this.meAccountId, required this.items});
}

class _MsgItem {
  final int senderAccountId;
  final int receiverAccountId;
  final String body;
  final String createdAt;

  const _MsgItem({
    required this.senderAccountId,
    required this.receiverAccountId,
    required this.body,
    required this.createdAt,
  });

  factory _MsgItem.fromJson(Map<String, dynamic> json) {
    return _MsgItem(
      senderAccountId: (json['sender_account_id'] as num?)?.toInt() ?? 0,
      receiverAccountId: (json['receiver_account_id'] as num?)?.toInt() ?? 0,
      body: (json['body'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}
