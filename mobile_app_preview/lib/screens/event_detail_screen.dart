import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/checkout_api.dart';
import '../services/date_time_format.dart';
import '../services/event_social_api.dart';
import 'app_webview_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final int submissionId;
  final String title;
  final String cover;
  final String description;
  final String eventDate;
  final String venue;
  final String venueMapUrl;
  final String organizer;
  final String program;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;
  final bool ticketSalesEnabled;
  final String sessionToken;

  const EventDetailScreen({
    super.key,
    required this.submissionId,
    required this.title,
    required this.cover,
    required this.description,
    required this.eventDate,
    required this.venue,
    required this.venueMapUrl,
    required this.organizer,
    required this.program,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
    required this.ticketSalesEnabled,
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
    return formatDateTimeDdMmYyyyHmDot(raw);
  }

  String _buyUrl() {
    if (!widget.ticketSalesEnabled) return '';
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

  String? _extractFirstUrl(String raw) {
    final m = RegExp(r'https?://[^\s]+', caseSensitive: false).firstMatch(raw);
    return m?.group(0);
  }

  String _venueLabel() {
    final raw = widget.venue.trim();
    if (raw.isEmpty) return '';
    final url = _extractFirstUrl(raw);
    if (url == null) return raw;
    final cleaned = raw.replaceFirst(url, '').replaceAll(RegExp(r'\s+\n'), '\n').trim();
    return cleaned.isEmpty ? raw : cleaned;
  }

  Uri? _mapsUri() {
    final direct = widget.venueMapUrl.trim();
    if (direct.isNotEmpty) {
      final normalized = direct.startsWith('http://') || direct.startsWith('https://')
          ? direct
          : (direct.startsWith('www.') ? 'https://$direct' : direct);
      final directUri = Uri.tryParse(normalized);
      if (directUri != null && directUri.hasScheme) return directUri;
    }
    final sharedUrl = _extractFirstUrl(widget.venue.trim());
    if (sharedUrl != null) {
      return Uri.tryParse(sharedUrl);
    }
    final q = _venueLabel().trim();
    if (q.isEmpty) return null;
    return Uri.parse('https://www.google.com/maps/search/?api=1&query=${Uri.encodeComponent(q)}');
  }

  Future<void> _openVenueInMaps() async {
    final uri = _mapsUri();
    if (uri == null) {
      _showMsg('Konum linki bulunamadı.');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _showMsg('Harita açılamadı.');
  }

  DateTime? _parseEventDateForCalendar(String raw) {
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

    final dmy = RegExp(r'^(\d{1,2})[.\-](\d{1,2})[.\-](\d{4})$').firstMatch(v);
    if (dmy != null) {
      final d = int.tryParse(dmy.group(1)!);
      final m = int.tryParse(dmy.group(2)!);
      final y = int.tryParse(dmy.group(3)!);
      if (y != null && m != null && d != null) return DateTime(y, m, d);
    }
    return null;
  }

  bool _eventHasTime(String raw) {
    return RegExp(r'\d{1,2}:\d{1,2}').hasMatch(raw);
  }

  Uri? _calendarUri() {
    final start = _parseEventDateForCalendar(widget.eventDate);
    if (start == null) return null;
    final hasTime = _eventHasTime(widget.eventDate);
    String dates;
    if (hasTime) {
      final end = start.add(const Duration(hours: 2));
      final f = DateFormat("yyyyMMdd'T'HHmmss'Z'");
      dates = '${f.format(start.toUtc())}/${f.format(end.toUtc())}';
    } else {
      final dayStart = DateTime(start.year, start.month, start.day);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final f = DateFormat('yyyyMMdd');
      dates = '${f.format(dayStart)}/${f.format(dayEnd)}';
    }
    final details = widget.description.trim().isEmpty ? widget.title.trim() : widget.description.trim();
    return Uri.https('calendar.google.com', '/calendar/render', {
      'action': 'TEMPLATE',
      'text': widget.title.trim(),
      'dates': dates,
      'details': details,
      'location': _venueLabel().trim(),
    });
  }

  Future<void> _addToCalendar() async {
    final uri = _calendarUri();
    if (uri == null) {
      _showMsg('Etkinlik tarihi geçersiz.');
      return;
    }
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok) _showMsg('Takvim açılamadı.');
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
      final result = await EventSocialApi.addFriend(
        submissionId: widget.submissionId,
        targetAccountId: targetAccountId,
        sessionToken: token,
      );
      final status = (result['status'] ?? '').toString();
      if (mounted) {
        setState(() {
          _attendees = _attendees.map((a) {
            if (a.accountId != targetAccountId) return a;
            return EventAttendee(
              accountId: a.accountId,
              name: a.name,
              isMe: a.isMe,
              isFriend: status == 'already_friends' || status == 'friend',
              friendStatus: status == 'already_friends'
                  ? 'friend'
                  : (status.isEmpty ? EventSocialApi.statusPendingOutgoing : status),
              friendRequestId: (result['request_id'] as num?)?.toInt() ?? a.friendRequestId,
            );
          }).toList();
        });
      }
      _showMsg(status == 'already_friends' ? 'Zaten arkadaşsınız.' : 'Arkadaşlık isteği gönderildi.');
      await _loadAttendees();
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    }
  }

  String _contentText() {
    if (_tab == 1) return widget.program.trim().isEmpty ? 'Program bilgisi girilmedi.' : widget.program.trim();
    if (_tab == 2) return _venueLabel().trim().isEmpty ? 'Konum bilgisi girilmedi.' : _venueLabel().trim();
    return widget.description.trim().isEmpty ? 'Detay bilgisi girilmedi.' : widget.description.trim();
  }

  @override
  Widget build(BuildContext context) {
    final buyUrl = _buyUrl();
    final venueLabel = _venueLabel();
    final canOpenMaps = _mapsUri() != null;
    final canAddToCalendar = _calendarUri() != null;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: const Text('Etkinlik Detay'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
          if (widget.cover.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                widget.cover,
                height: 190,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(height: 190, color: const Color(0xFF1F2937)),
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line(Icons.calendar_month, _fmtDate(widget.eventDate)),
                if (venueLabel.isNotEmpty) _line(Icons.location_on, venueLabel),
                if (widget.organizer.trim().isNotEmpty) _line(Icons.public, widget.organizer.trim()),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (canAddToCalendar)
            SizedBox(
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _addToCalendar,
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.white24),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.event_available),
                label: const Text(
                  'Takvime Ekle',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          if (canAddToCalendar) const SizedBox(height: 12),
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
                      _joined ? 'Katılımı Geri Çek' : 'Etkinliğe Katılacağım',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          if (buyUrl.isNotEmpty)
            SizedBox(
              height: 50,
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
                    : const Text(
                        'Bilet Satın Al',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
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
                          if (!a.isMe && a.friendStatus == 'none')
                            TextButton(
                              onPressed: () => _addFriend(a.accountId),
                              child: const Text('Arkadaş Ekle'),
                            )
                          else if (!a.isMe && a.friendStatus == 'pending_outgoing')
                            const Text('Onay Bekleniyor', style: TextStyle(color: Color(0xFFF59E0B)))
                          else if (!a.isMe && a.friendStatus == 'pending_incoming')
                            const Text('Gelen İstek', style: TextStyle(color: Color(0xFF38BDF8)))
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              SizedBox(width: 110, child: _tabBtn(0, 'Detaylar')),
              SizedBox(width: 110, child: _tabBtn(1, 'Program')),
              SizedBox(width: 110, child: _tabBtn(2, 'Konum')),
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
            child: _tab == 2
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _contentText(),
                        style: TextStyle(color: Colors.white.withOpacity(0.92), height: 1.4),
                      ),
                      if (canOpenMaps) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _openVenueInMaps,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFE53935),
                              foregroundColor: Colors.white,
                            ),
                            child: const Text(
                              'HARITADA AÇ',
                              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8),
                            ),
                          ),
                        ),
                      ],
                    ],
                  )
                : Text(
                    _contentText(),
                    style: TextStyle(color: Colors.white.withOpacity(0.92), height: 1.4),
                  ),
          ),
          ],
        ),
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
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  Widget _tabBtn(int val, String title) {
    final active = _tab == val;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: active ? const Color(0xFF1C2436) : const Color(0xFF0F172A),
        side: BorderSide(color: active ? const Color(0xFFE53935) : Colors.white12),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () => setState(() => _tab = val),
      child: Text(title),
    );
  }
}
