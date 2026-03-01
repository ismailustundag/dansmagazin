import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

class TicketsScreen extends StatefulWidget {
  final String sessionToken;

  const TicketsScreen({super.key, required this.sessionToken});

  @override
  State<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends State<TicketsScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_TicketItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchTickets();
  }

  Future<List<_TicketItem>> _fetchTickets() async {
    final res = await http.get(
      Uri.parse('$_base/profile/tickets'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
    );
    if (res.statusCode != 200) {
      throw Exception('Biletler alınamadı (${res.statusCode})');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_TicketItem.fromJson)
        .toList();
    return items;
  }

  Future<void> _refresh() async {
    final f = _fetchTickets();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Biletlerim')),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<List<_TicketItem>>(
            future: _future,
            builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 60),
                  Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('Biletler yüklenemedi, tekrar dene'),
                    ),
                  ),
                ],
              );
            }
            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  Center(child: Text('Henüz bilet bulunmuyor.')),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final t = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => TicketQrScreen(ticket: t),
                      ),
                    );
                  },
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t.eventName,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                t.isUsed ? 'Durum: Kullanıldı' : 'Durum: Aktif',
                                style: TextStyle(
                                  color: t.isUsed ? const Color(0xFFF59E0B) : const Color(0xFF22C55E),
                                ),
                              ),
                              if (t.wooOrderId.isNotEmpty)
                                Text(
                                  'Sipariş: #${t.wooOrderId}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                            ],
                          ),
                        ),
                        const Icon(Icons.qr_code_2, size: 30, color: Color(0xFFE53935)),
                      ],
                    ),
                  ),
                );
              },
            );
            },
          ),
        ),
      ),
    );
  }
}

class TicketQrScreen extends StatelessWidget {
  final _TicketItem ticket;

  const TicketQrScreen({super.key, required this.ticket});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(ticket.eventName)),
      body: SafeArea(
        top: false,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
              Text(
                ticket.isUsed ? 'Bu bilet kullanıldı' : 'Etkinlik Giriş Bileti',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: ticket.qrToken,
                  version: QrVersions.auto,
                  size: 260,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Bilet Kodu: ${ticket.ticketId}',
                style: const TextStyle(color: Colors.white70),
              ),
              if (ticket.usedAt.isNotEmpty)
                Text(
                  'Kullanım: ${ticket.usedAt}',
                  style: const TextStyle(color: Color(0xFFF59E0B)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TicketItem {
  final int ticketId;
  final int submissionId;
  final String eventName;
  final String qrToken;
  final String wooOrderId;
  final String usedAt;
  final bool isUsed;

  _TicketItem({
    required this.ticketId,
    required this.submissionId,
    required this.eventName,
    required this.qrToken,
    required this.wooOrderId,
    required this.usedAt,
    required this.isUsed,
  });

  factory _TicketItem.fromJson(Map<String, dynamic> json) {
    return _TicketItem(
      ticketId: (json['ticket_id'] as num?)?.toInt() ?? 0,
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      eventName: (json['event_name'] ?? '').toString(),
      qrToken: (json['qr_token'] ?? '').toString(),
      wooOrderId: (json['woo_order_id'] ?? '').toString(),
      usedAt: (json['used_at'] ?? '').toString(),
      isUsed: (json['is_used'] == true) || ((json['used_at'] ?? '').toString().trim().isNotEmpty),
    );
  }
}
