import 'package:flutter/material.dart';

import 'app_webview_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final String title;
  final String cover;
  final String description;
  final String eventDate;
  final String venue;
  final String organizer;
  final String program;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;

  const EventDetailScreen({
    super.key,
    required this.title,
    required this.cover,
    required this.description,
    required this.eventDate,
    required this.venue,
    required this.organizer,
    required this.program,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
  });

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  int _tab = 0;

  String _fmtDate(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '-';
    final dt = DateTime.tryParse(v) ?? DateTime.tryParse(v.replaceAll(' ', 'T'));
    if (dt == null) return v;
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yy = (dt.year % 100).toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mn = dt.minute.toString().padLeft(2, '0');
    return '$dd.$mm.$yy  $hh:$mn';
  }

  String _buyUrl() {
    final t = widget.ticketUrl.trim();
    if (t.isNotEmpty) {
      final u = Uri.tryParse(t);
      if (u != null) {
        final parsedPid =
            u.queryParameters['p'] ?? u.queryParameters['product_id'] ?? u.queryParameters['add-to-cart'];
        if (parsedPid != null && parsedPid.trim().isNotEmpty) {
          return 'https://www.dansmagazin.net/?post_type=product&p=${parsedPid.trim()}';
        }
      }
      return t;
    }
    final pid = widget.wooProductId.trim();
    if (pid.isNotEmpty) {
      return 'https://www.dansmagazin.net/?post_type=product&p=$pid';
    }
    return '';
  }

  String _contentText() {
    if (_tab == 1) return widget.program.trim().isEmpty ? 'Program bilgisi girilmedi.' : widget.program.trim();
    if (_tab == 2) return widget.venue.trim().isEmpty ? 'Konum bilgisi girilmedi.' : widget.venue.trim();
    return widget.description.trim().isEmpty ? 'Detay bilgisi girilmedi.' : widget.description.trim();
  }

  @override
  Widget build(BuildContext context) {
    final buyUrl = _buyUrl();
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: const Text('Etkinlik Detay'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (widget.cover.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                widget.cover,
                height: 220,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(height: 220, color: const Color(0xFF1F2937)),
              ),
            ),
          Container(
            margin: const EdgeInsets.only(top: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              children: [
                _line(Icons.calendar_month, _fmtDate(widget.eventDate)),
                if (widget.venue.trim().isNotEmpty) _line(Icons.location_on, widget.venue.trim()),
                if (widget.organizer.trim().isNotEmpty) _line(Icons.public, widget.organizer.trim()),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (buyUrl.isNotEmpty)
            SizedBox(
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE21C2A),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AppWebViewScreen(url: buyUrl, title: widget.title),
                    ),
                  );
                },
                child: Text(
                  'BILET SATIN AL  ₺${widget.entryFee.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              _tabBtn(0, 'Detaylar'),
              const SizedBox(width: 8),
              _tabBtn(1, 'Program'),
              const SizedBox(width: 8),
              _tabBtn(2, 'Konum'),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(
              _contentText(),
              style: TextStyle(color: Colors.white.withOpacity(0.92), height: 1.4),
            ),
          ),
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.white70),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 16))),
        ],
      ),
    );
  }

  Widget _tabBtn(int val, String title) {
    final active = _tab == val;
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: active ? const Color(0xFF1C2436) : const Color(0xFF0F172A),
          side: BorderSide(color: active ? const Color(0xFFE53935) : Colors.white12),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        onPressed: () => setState(() => _tab = val),
        child: Text(title),
      ),
    );
  }
}
