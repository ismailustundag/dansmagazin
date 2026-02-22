import 'package:flutter/material.dart';

import '../services/checkout_api.dart';
import '../services/event_social_api.dart';
import 'app_webview_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final int submissionId;
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
  final String sessionToken;

  const EventDetailScreen({
    super.key,
    required this.submissionId,
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
    required this.sessionToken,
  });

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  int _tab = 0;
  bool _openingCheckout = false;
  bool _loadingAttendees = true;
  bool _changingAttendance = false;
  bool _joined = false;
  List<EventAttendee> _attendees = const [];

  @override
  void initState() {
    super.initState();
    _loadAttendees();
  }

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

  Future<void> _openCheckout() async {
    final directUrl = _buyUrl();
    if (directUrl.isEmpty) return;

    var targetUrl = directUrl;
    if (widget.sessionToken.trim().isNotEmpty) {
      try {
        targetUrl = await CheckoutApi.buildAutoLoginUrl(
          sessionToken: widget.sessionToken.trim(),
          targetUrl: directUrl,
        );
      } catch (_) {
        // Auto-login link üretimi başarısızsa normal ürün sayfasına düş.
      }
    }

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppWebViewScreen(url: targetUrl, title: widget.title),
      ),
    );
  }

  Future<void> _loadAttendees() async {
    if (!mounted) return;
    setState(() => _loadingAttendees = true);
    try {
      final items = await EventSocialApi.attendees(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() {
        _attendees = items;
        _joined = items.any((e) => e.isMe);
      });
    } catch (_) {
      // liste yüklenemezse ekran akışı bozulmasın
    } finally {
      if (mounted) setState(() => _loadingAttendees = false);
    }
  }

  void _showMsg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _toggleAttend() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Katılım için önce giriş yapmalısın.');
      return;
    }
    setState(() => _changingAttendance = true);
    try {
      if (_joined) {
        await EventSocialApi.leave(submissionId: widget.submissionId, sessionToken: token);
      } else {
        await EventSocialApi.attend(submissionId: widget.submissionId, sessionToken: token);
      }
      await _loadAttendees();
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    } finally {
      if (mounted) setState(() => _changingAttendance = false);
    }
  }

  Future<void> _addFriend(int targetAccountId) async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Arkadaş eklemek için önce giriş yapmalısın.');
      return;
    }
    try {
      await EventSocialApi.addFriend(
        submissionId: widget.submissionId,
        targetAccountId: targetAccountId,
        sessionToken: token,
      );
      _showMsg('Arkadaş olarak eklendi.');
      await _loadAttendees();
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    }
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
          SizedBox(
            height: 52,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: _joined ? const Color(0xFF16A34A) : const Color(0xFFE53935)),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _changingAttendance ? null : _toggleAttend,
              child: _changingAttendance
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      _joined ? 'KATILIMI GERI CEK' : 'ETKINLIGE KATILACAGIM',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
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
                onPressed: _openingCheckout
                    ? null
                    : () async {
                        setState(() => _openingCheckout = true);
                        try {
                          await _openCheckout();
                        } finally {
                          if (mounted) setState(() => _openingCheckout = false);
                        }
                      },
                child: _openingCheckout
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : Text(
                        'BILET SATIN AL  ₺${widget.entryFee.toStringAsFixed(0)}',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                      ),
              ),
            ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF121826),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Etkinliğe Katılacaklar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 10),
                if (_loadingAttendees)
                  const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                else if (_attendees.isEmpty)
                  const Text('Henüz katılımcı yok.')
                else
                  ..._attendees.map((a) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              a.isMe ? '${a.name} (Sen)' : a.name,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          if (!a.isMe && !a.isFriend)
                            TextButton(
                              onPressed: () => _addFriend(a.accountId),
                              child: const Text('Arkadaş Ekle'),
                            )
                          else if (a.isFriend && !a.isMe)
                            const Text('Arkadaş', style: TextStyle(color: Color(0xFF22C55E))),
                        ],
                      ),
                    );
                  }),
              ],
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
