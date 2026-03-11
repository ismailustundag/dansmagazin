import 'dart:convert';
import 'dart:io';

import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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
                                'Durum: ${t.statusLabel}',
                                style: TextStyle(
                                  color: t.statusColor,
                                ),
                              ),
                              if (t.wooOrderStatus.isNotEmpty)
                                Text(
                                  'Sipariş durumu: ${t.wooOrderStatus}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              if (t.wooOrderId.isNotEmpty)
                                Text(
                                  'Sipariş: #${t.wooOrderId}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              if (t.eventDate.isNotEmpty)
                                Text(
                                  'Tarih: ${t.eventDateLabel}',
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

  DateTime? _parseEventDate(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    final normalized = v.replaceAll(' ', 'T');
    final direct = DateTime.tryParse(v) ?? DateTime.tryParse(normalized);
    if (direct != null) return direct;
    final yMd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(v);
    if (yMd != null) {
      final y = int.tryParse(yMd.group(1)!);
      final m = int.tryParse(yMd.group(2)!);
      final d = int.tryParse(yMd.group(3)!);
      if (y != null && m != null && d != null) return DateTime(y, m, d);
    }
    return null;
  }

  bool _hasTime(String raw) => RegExp(r'\d{1,2}:\d{1,2}').hasMatch(raw);

  Event? _calendarEvent() {
    final start = _parseEventDate(ticket.eventDate);
    if (start == null) return null;
    final hasTime = _hasTime(ticket.eventDate);
    final startDate = hasTime ? start : DateTime(start.year, start.month, start.day, 10, 0);
    final endDate = hasTime ? startDate.add(const Duration(hours: 2)) : startDate.add(const Duration(hours: 1));
    return Event(
      title: ticket.eventName.trim().isEmpty ? 'Etkinlik' : ticket.eventName.trim(),
      description: 'Bilet Kodu: ${ticket.ticketId}',
      location: ticket.venue.trim(),
      startDate: startDate,
      endDate: endDate,
      allDay: !hasTime,
      iosParams: const IOSParams(reminder: Duration(minutes: 30)),
      androidParams: const AndroidParams(emailInvites: <String>[]),
    );
  }

  String _walletUrl() {
    if (Platform.isIOS && ticket.appleWalletUrl.trim().isNotEmpty) {
      return ticket.appleWalletUrl.trim();
    }
    if (Platform.isAndroid && ticket.googleWalletUrl.trim().isNotEmpty) {
      return ticket.googleWalletUrl.trim();
    }
    final any = ticket.appleWalletUrl.trim().isNotEmpty
        ? ticket.appleWalletUrl.trim()
        : ticket.googleWalletUrl.trim();
    return any;
  }

  Future<void> _openCalendar(BuildContext context) async {
    final event = _calendarEvent();
    if (event == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Takvim için etkinlik tarihi bulunamadı.')),
      );
      return;
    }
    try {
      await Add2Calendar.addEvent2Cal(event);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Takvim açılamadı.')),
      );
    }
  }

  Future<void> _openWallet(BuildContext context) async {
    final url = _walletUrl();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Bu bilet için cüzdan bağlantısı henüz tanımlı değil.')),
      );
      return;
    }
    final uri = Uri.tryParse(url);
    if (uri == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cüzdan bağlantısı geçersiz.')),
      );
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Cüzdan bağlantısı açılamadı.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canOpenWallet = _walletUrl().isNotEmpty;
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
                ticket.isUsed ? 'Bu bilet kullanıldı' : ticket.statusLabel,
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
              if (ticket.eventDate.trim().isNotEmpty)
                Text(
                  'Etkinlik: ${ticket.eventDateLabel}',
                  style: const TextStyle(color: Colors.white70),
                ),
              if (ticket.usedAt.isNotEmpty)
                Text(
                  'Kullanım: ${ticket.usedAt}',
                  style: const TextStyle(color: Color(0xFFF59E0B)),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1D4ED8),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          textStyle: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        onPressed: () => _openCalendar(context),
                        icon: const Icon(Icons.event_available),
                        label: const Text('Takvime Ekle'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: SizedBox(
                      height: 48,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFE53935),
                          disabledBackgroundColor: const Color(0xFF374151),
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white70,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          textStyle: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        onPressed: canOpenWallet ? () => _openWallet(context) : null,
                        icon: const Icon(Icons.account_balance_wallet),
                        label: Text(canOpenWallet ? 'Cüzdana Ekle' : 'Cüzdan Yakında'),
                      ),
                    ),
                  ),
                ],
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
  final String wooOrderStatus;
  final String status;
  final String usedAt;
  final bool isUsed;
  final String eventDate;
  final String venue;
  final String googleWalletUrl;
  final String appleWalletUrl;

  _TicketItem({
    required this.ticketId,
    required this.submissionId,
    required this.eventName,
    required this.qrToken,
    required this.wooOrderId,
    required this.wooOrderStatus,
    required this.status,
    required this.usedAt,
    required this.isUsed,
    required this.eventDate,
    required this.venue,
    required this.googleWalletUrl,
    required this.appleWalletUrl,
  });

  factory _TicketItem.fromJson(Map<String, dynamic> json) {
    return _TicketItem(
      ticketId: (json['ticket_id'] as num?)?.toInt() ?? 0,
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      eventName: (json['event_name'] ?? '').toString(),
      qrToken: (json['qr_token'] ?? '').toString(),
      wooOrderId: (json['woo_order_id'] ?? '').toString(),
      wooOrderStatus: (json['woo_order_status'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
      usedAt: (json['used_at'] ?? '').toString(),
      isUsed: (json['is_used'] == true) || ((json['used_at'] ?? '').toString().trim().isNotEmpty),
      eventDate: (json['event_date'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
      googleWalletUrl: (json['google_wallet_url'] ?? '').toString(),
      appleWalletUrl: (json['apple_wallet_url'] ?? '').toString(),
    );
  }

  String get eventDateLabel {
    final raw = eventDate.trim();
    if (raw.isEmpty) return '-';
    final dt = DateTime.tryParse(raw) ?? DateTime.tryParse(raw.replaceAll(' ', 'T'));
    if (dt == null) return raw;
    final hasTime = raw.contains(':');
    return hasTime ? DateFormat('dd.MM.yyyy HH.mm').format(dt.toLocal()) : DateFormat('dd.MM.yyyy').format(dt.toLocal());
  }

  String get statusLabel {
    if (isUsed) return 'Kullanıldı';
    final woo = wooOrderStatus.trim().toLowerCase();
    if (woo.contains('hold') ||
        woo == 'pending' ||
        woo == 'checkout-draft' ||
        woo == 'pending-payment' ||
        woo == 'pending_payment') {
      return 'Ödeme Bekleniyor';
    }
    if (woo == 'failed' || woo == 'cancelled' || woo == 'refunded') {
      return 'İptal';
    }
    final s = status.trim().toLowerCase();
    if (s == 'active') return 'Aktif';
    if (s == 'payment_pending') return 'Ödeme Bekleniyor';
    if (s == 'cancelled') return 'İptal';
    return s.isEmpty ? 'Bilinmiyor' : s;
  }

  Color get statusColor {
    if (isUsed) return const Color(0xFFF59E0B);
    final woo = wooOrderStatus.trim().toLowerCase();
    if (woo.contains('hold') ||
        woo == 'pending' ||
        woo == 'checkout-draft' ||
        woo == 'pending-payment' ||
        woo == 'pending_payment') {
      return const Color(0xFFF59E0B);
    }
    if (woo == 'failed' || woo == 'cancelled' || woo == 'refunded') {
      return const Color(0xFFEF4444);
    }
    final s = status.trim().toLowerCase();
    if (s == 'active') return const Color(0xFF22C55E);
    if (s == 'payment_pending') return const Color(0xFFF59E0B);
    if (s == 'cancelled') return const Color(0xFFEF4444);
    return Colors.white70;
  }
}
