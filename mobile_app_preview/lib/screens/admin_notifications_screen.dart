import 'package:flutter/material.dart';

import '../services/notifications_api.dart';
import '../services/date_time_format.dart';

class AdminNotificationsScreen extends StatefulWidget {
  final String sessionToken;

  const AdminNotificationsScreen({super.key, required this.sessionToken});

  @override
  State<AdminNotificationsScreen> createState() => _AdminNotificationsScreenState();
}

class _AdminNotificationsScreenState extends State<AdminNotificationsScreen> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();

  bool _sendToAll = true;
  bool _sending = false;
  bool _loadingUsers = false;
  bool _loadingSent = false;
  String _error = '';
  final Set<int> _selected = <int>{};
  List<NotificationUserCandidate> _users = const [];
  List<NotificationFeedItem> _sent = const [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadSent();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    setState(() => _loadingUsers = true);
    try {
      final items = await NotificationsApi.searchUsers(
        widget.sessionToken,
        query: _searchCtrl.text,
        limit: 100,
      );
      if (!mounted) return;
      setState(() => _users = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  Future<void> _loadSent() async {
    setState(() => _loadingSent = true);
    try {
      final items = await NotificationsApi.fetchSent(widget.sessionToken, limit: 200);
      if (!mounted) return;
      setState(() => _sent = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingSent = false);
    }
  }

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _error = 'Başlık ve içerik zorunludur.');
      return;
    }
    if (!_sendToAll && _selected.isEmpty) {
      setState(() => _error = 'En az bir kullanıcı seçin veya Tümüne gönder açın.');
      return;
    }
    setState(() {
      _sending = true;
      _error = '';
    });
    try {
      final sentCount = await NotificationsApi.sendNotification(
        widget.sessionToken,
        title: title,
        body: body,
        sendToAll: _sendToAll,
        targetAccountIds: _selected.toList()..sort(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Bildirim gönderildi. Alıcı: $sentCount')),
      );
      _titleCtrl.clear();
      _bodyCtrl.clear();
      _selected.clear();
      await _loadSent();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _fmtDate(String raw) {
    return formatDateTimeDdMmYyyyHmDot(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('Bildirim Gönder (Super Admin)'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Yeni Bildirim', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _titleCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Başlık',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _bodyCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: 'İçerik',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sendToAll,
                    title: const Text('Tüm kullanıcılara gönder'),
                    onChanged: (v) => setState(() => _sendToAll = v),
                  ),
                  if (!_sendToAll) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: (_) => _loadUsers(),
                            decoration: const InputDecoration(
                              hintText: 'Kullanıcı ara',
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _loadingUsers ? null : _loadUsers,
                          child: const Text('Ara'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_loadingUsers)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      ..._users.map(
                        (u) => CheckboxListTile(
                          value: _selected.contains(u.accountId),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(u.accountId);
                              } else {
                                _selected.remove(u.accountId);
                              }
                            });
                          },
                          title: Text(u.name.trim().isEmpty ? 'user' : u.name),
                          subtitle: u.email.trim().isEmpty ? null : Text(u.email),
                          controlAffinity: ListTileControlAffinity.leading,
                          dense: true,
                        ),
                      ),
                  ],
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_error, style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                    label: Text(_sending ? 'Gönderiliyor...' : 'Bildirimi Gönder'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Gönderilen Bildirimler', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (_loadingSent)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_sent.isEmpty)
                    Text('Henüz gönderim yok.', style: TextStyle(color: Colors.white.withOpacity(0.75)))
                  else
                    ..._sent.map(
                      (n) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    n.title.trim().isEmpty ? 'Bildirim' : n.title,
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Text(_fmtDate(n.createdAt), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(n.body, style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
