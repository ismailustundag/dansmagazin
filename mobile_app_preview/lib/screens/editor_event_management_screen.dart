import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/error_message.dart';
import '../services/event_social_api.dart';
import '../services/profile_api.dart';
import '../services/turkiye_cities.dart';
import '../theme/app_theme.dart';
import 'chat_thread_screen.dart';
import 'editor_news_management_screen.dart';

DateTime? _parseEventDate(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  final ddmmyyyy = RegExp(r'^(\d{1,2})[-\.](\d{1,2})[-\.](\d{4})$').firstMatch(v);
  if (ddmmyyyy != null) {
    final d = int.tryParse(ddmmyyyy.group(1)!);
    final m = int.tryParse(ddmmyyyy.group(2)!);
    final y = int.tryParse(ddmmyyyy.group(3)!);
    if (d != null && m != null && y != null) return DateTime(y, m, d);
  }
  final dt = DateTime.tryParse(v) ?? DateTime.tryParse(v.replaceAll(' ', 'T'));
  if (dt != null) return dt.isUtc ? dt.toLocal() : dt;
  final ymd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(v);
  if (ymd != null) {
    final y = int.tryParse(ymd.group(1)!);
    final m = int.tryParse(ymd.group(2)!);
    final d = int.tryParse(ymd.group(3)!);
    if (d != null && m != null && y != null) return DateTime(y, m, d);
  }
  return null;
}

String _toDisplayDate(String raw) {
  final dt = _parseEventDate(raw);
  if (dt == null) return raw.trim();
  final d = dt.day.toString().padLeft(2, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final y = dt.year.toString();
  return '$d-$m-$y';
}

String _toApiDate(String raw) {
  final dt = _parseEventDate(raw);
  if (dt == null) return raw.trim();
  final d = dt.day.toString().padLeft(2, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final y = dt.year.toString();
  return '$y-$m-$d';
}

TimeOfDay? _parseTimeOfDay(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  final m = RegExp(r'^(\d{1,2})[.:](\d{1,2})$').firstMatch(v);
  if (m == null) return null;
  final hh = int.tryParse(m.group(1) ?? '');
  final mm = int.tryParse(m.group(2) ?? '');
  if (hh == null || mm == null) return null;
  if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return null;
  return TimeOfDay(hour: hh, minute: mm);
}

String _toDisplayTime(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  final direct = _parseTimeOfDay(v);
  if (direct != null) {
    final h = direct.hour.toString().padLeft(2, '0');
    final m = direct.minute.toString().padLeft(2, '0');
    return '$h.$m';
  }
  final isOnlyDate = RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$').hasMatch(v) ||
      RegExp(r'^\d{1,2}[-\.]\d{1,2}[-\.]\d{4}$').hasMatch(v);
  if (isOnlyDate) return '';
  final dt = _parseEventDate(v);
  if (dt == null) return '';
  final h = dt.hour.toString().padLeft(2, '0');
  final m = dt.minute.toString().padLeft(2, '0');
  return '$h.$m';
}

String _toApiDateTime(String dateRaw, String timeRaw) {
  final d = _parseEventDate(dateRaw.trim());
  if (d == null) return dateRaw.trim();
  final day = '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  final t = _parseTimeOfDay(timeRaw.trim());
  if (t == null) return day;
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '$day $hh:$mm:00';
}

DateTime? _combineDateAndTime(String dateRaw, String timeRaw) {
  final d = _parseEventDate(dateRaw.trim());
  if (d == null) return null;
  final t = _parseTimeOfDay(timeRaw.trim());
  return DateTime(d.year, d.month, d.day, t?.hour ?? 0, t?.minute ?? 0);
}

class _VenueParts {
  final String name;
  final String mapUrl;
  const _VenueParts({required this.name, required this.mapUrl});
}

const List<String> _weekdayLabels = <String>[
  'Her Pazartesi',
  'Her Salı',
  'Her Çarşamba',
  'Her Perşembe',
  'Her Cuma',
  'Her Cumartesi',
  'Her Pazar',
];

const List<String> _danceStyleValues = <String>[
  'salsa',
  'bachata',
  'kizomba',
  'tango',
  'lindy_hop',
  'hip_hop',
];

String _danceStyleLabel(String value) {
  switch (value) {
    case 'salsa':
      return 'Salsa';
    case 'bachata':
      return 'Bachata';
    case 'kizomba':
      return 'Kizomba';
    case 'tango':
      return 'Tango';
    case 'lindy_hop':
      return 'Lindy Hop';
    case 'hip_hop':
      return 'Hip Hop';
    default:
      return value;
  }
}

List<String> _normalizeDanceStyles(dynamic raw) {
  final List<String> parts;
  if (raw is List) {
    parts = raw.map((e) => e.toString().trim().toLowerCase()).toList();
  } else {
    final text = (raw ?? '').toString().trim();
    if (text.isEmpty) return const <String>[];
    parts = text.split(',').map((e) => e.trim().toLowerCase()).toList();
  }
  final out = <String>[];
  for (final value in _danceStyleValues) {
    if (parts.contains(value)) out.add(value);
  }
  return out;
}

String _danceStylesPayload(Iterable<String> styles) {
  final normalized = _normalizeDanceStyles(styles.toList());
  return normalized.join(',');
}

String _normalizeMapUrl(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  if (v.startsWith('http://') || v.startsWith('https://')) return v;
  if (v.startsWith('www.')) return 'https://$v';
  return '';
}

_VenueParts _splitVenue(String venue, {String mapUrl = ''}) {
  final explicit = _normalizeMapUrl(mapUrl);
  if (explicit.isNotEmpty) {
    return _VenueParts(name: venue.trim(), mapUrl: explicit);
  }
  final raw = venue.trim();
  if (raw.isEmpty) return const _VenueParts(name: '', mapUrl: '');
  final m = RegExp(r'https?://[^\s]+', caseSensitive: false).firstMatch(raw);
  if (m == null) {
    return _VenueParts(name: raw, mapUrl: '');
  }
  final link = (m.group(0) ?? '').trim();
  final name = raw.replaceFirst(link, '').replaceAll(RegExp(r'\s+\n'), '\n').trim();
  return _VenueParts(name: name, mapUrl: link);
}

Future<void> _openSupportChat(BuildContext context, String sessionToken) async {
  final token = sessionToken.trim();
  if (token.isEmpty) return;
  try {
    final contact = await ProfileApi.supportContact(token);
    final target = contact ??
        const SupportContact(
          accountId: 164,
          name: 'Dansmagazin',
          avatarUrl: '',
        );
    if (!context.mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          sessionToken: token,
          peerAccountId: target.accountId,
          peerName: target.name,
          peerAvatarUrl: target.avatarUrl,
        ),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Destek açılamadı: $e')),
    );
  }
}

class EditorEventManagementScreen extends StatelessWidget {
  final String sessionToken;

  const EditorEventManagementScreen({super.key, required this.sessionToken});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Etkinlik Yönetimi'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          _ActionCard(
            title: 'Etkinlik Oluştur',
            subtitle: 'Yeni etkinliği onaya gönder.',
            icon: Icons.add_circle_outline,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  fullscreenDialog: true,
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: const Text('Etkinlik Oluştur')),
                    body: SafeArea(
                      child: _CreateEventSheet(sessionToken: sessionToken),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          _ActionCard(
            title: 'Haber Oluştur',
            subtitle: 'Yeni haberi onaya gönder.',
            icon: Icons.newspaper_outlined,
            onTap: () async {
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EditorNewsCreateScreen(sessionToken: sessionToken),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          _ActionCard(
            title: 'Haberleri Yönet',
            subtitle: 'Haber taleplerini görüntüle ve düzenle.',
            icon: Icons.fact_check_outlined,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ManageNewsScreen(sessionToken: sessionToken),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          _ActionCard(
            title: 'Etkinliği Yönet',
            subtitle: 'Kendi etkinliklerini görüntüle ve düzenle.',
            icon: Icons.edit_calendar_outlined,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ManageEventsScreen(sessionToken: sessionToken),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          _ActionCard(
            title: 'Bilet Kontrol Et',
            subtitle: 'QR okut, kullanılmış biletleri listele.',
            icon: Icons.qr_code_scanner,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TicketScanEventListScreen(sessionToken: sessionToken),
                ),
              );
            },
          ),
          ],
        ),
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback onTap;

  const _ActionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
        child: Row(
          children: [
            Icon(icon, color: AppTheme.cyan),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13.5),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}

class _DanceStylesField extends StatelessWidget {
  final Set<String> selectedStyles;
  final void Function(String style)? onToggle;

  const _DanceStylesField({
    required this.selectedStyles,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Dans Türleri',
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _danceStyleValues
                .map(
                  (style) => FilterChip(
                    label: Text(_danceStyleLabel(style)),
                    selected: selectedStyles.contains(style),
                    onSelected: onToggle == null ? null : (_) => onToggle!(style),
                    selectedColor: const Color(0xFFE58B8B),
                    checkmarkColor: Colors.white,
                    backgroundColor: AppTheme.surfacePrimary,
                    labelStyle: TextStyle(
                      color: selectedStyles.contains(style) ? Colors.white : AppTheme.textSecondary,
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                    ),
                    side: BorderSide(
                      color: selectedStyles.contains(style) ? const Color(0x00FFFFFF) : Colors.white12,
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _TicketSalesHelpCard extends StatelessWidget {
  final String sessionToken;
  final bool busy;

  const _TicketSalesHelpCard({
    required this.sessionToken,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Etkinlik biletinizin satışa açılmasını istiyorsanız Dansmagazin ile iletişime geçin.',
            style: TextStyle(fontSize: 13.5, color: AppTheme.textSecondary, height: 1.35),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: busy ? null : () => _openSupportChat(context, sessionToken),
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text(
                'Mesaj Gönder',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TicketScanEventListScreen extends StatefulWidget {
  final String sessionToken;

  const TicketScanEventListScreen({super.key, required this.sessionToken});

  @override
  State<TicketScanEventListScreen> createState() => _TicketScanEventListScreenState();
}

class _TicketScanEventListScreenState extends State<TicketScanEventListScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_ScannableEvent>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<List<_ScannableEvent>> _fetch() async {
    final res = await http.get(
      Uri.parse('$_base/events/tickets/scannable-events'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
    );
    if (res.statusCode != 200) {
      throw Exception('Etkinlikler alınamadı (${res.statusCode})');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    return (map['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_ScannableEvent.fromJson)
        .toList();
  }

  Future<void> _refresh() async {
    final f = _fetch();
    setState(() => _future = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bilet Kontrol Et')),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<List<_ScannableEvent>>(
            future: _future,
            builder: (_, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 60),
                  Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('Etkinlik listesi alınamadı, tekrar dene'),
                    ),
                  ),
                ],
              );
            }
            final items = snap.data ?? [];
            if (items.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 60),
                  Center(child: Text('Bu kullanıcıya atanmış bilet kontrol yetkisi yok.')),
                ],
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final e = items[i];
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: _ActionCard(
                    title: e.eventName,
                    subtitle: e.venue.isNotEmpty
                        ? e.venue
                        : (e.eventDate.isNotEmpty ? _toDisplayDate(e.eventDate) : 'Etkinlik #${e.submissionId}'),
                    icon: Icons.event_available,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TicketScanScreen(
                            sessionToken: widget.sessionToken,
                            submissionId: e.submissionId,
                            eventName: e.eventName,
                          ),
                        ),
                      );
                    },
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

class _ScannableEvent {
  final int submissionId;
  final String eventName;
  final String eventDate;
  final String venue;

  _ScannableEvent({
    required this.submissionId,
    required this.eventName,
    required this.eventDate,
    required this.venue,
  });

  factory _ScannableEvent.fromJson(Map<String, dynamic> json) {
    return _ScannableEvent(
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      eventName: (json['event_name'] ?? '').toString(),
      eventDate: (json['start_at'] ?? json['event_date'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
    );
  }
}

class TicketScanScreen extends StatefulWidget {
  final String sessionToken;
  final int submissionId;
  final String eventName;

  const TicketScanScreen({
    super.key,
    required this.sessionToken,
    required this.submissionId,
    required this.eventName,
  });

  @override
  State<TicketScanScreen> createState() => _TicketScanScreenState();
}

class _TicketScanScreenState extends State<TicketScanScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  final MobileScannerController _scannerController = MobileScannerController(
    autoStart: false,
    detectionSpeed: DetectionSpeed.normal,
    facing: CameraFacing.back,
    torchEnabled: false,
  );

  bool _loading = false;
  bool _scannerOpen = false;
  String _result = '';
  Color _resultColor = const Color(0xFFB71C1C);
  bool _resultSuccess = false;
  List<Map<String, dynamic>> _used = const [];
  String _lastToken = '';
  DateTime _lastScanAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _scannerArmedAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _loadUsed();
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _scanToken(String token) async {
    final qrToken = token.trim();
    if (qrToken.isEmpty) {
      return;
    }

    final now = DateTime.now();
    if (_lastToken == qrToken && now.difference(_lastScanAt).inMilliseconds < 1500) {
      return;
    }
    _lastToken = qrToken;
    _lastScanAt = now;

    setState(() => _loading = true);
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_base/events/${widget.submissionId}/tickets/scan'))
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['qr_token'] = qrToken;
      final res = await req.send();
      final body = await res.stream.bytesToString();
      Map<String, dynamic> map = {};
      if (body.isNotEmpty) {
        final decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          map = decoded;
        }
      }
      final state = (map['state'] ?? '').toString();
      final msg = sanitizeErrorText(
        (map['message'] ?? map['detail'] ?? '').toString(),
        fallback: '',
      );
      if (res.statusCode == 200 && state == 'accepted') {
        setState(() {
          _result = msg.isNotEmpty ? msg : 'Bilet geçerli.';
          _resultColor = const Color(0xFF1B5E20);
          _resultSuccess = true;
        });
      } else if (res.statusCode == 200 && state == 'already_used') {
        setState(() {
          _result = msg.isNotEmpty ? msg : 'Bilet daha önce kullanılmış.';
          _resultColor = const Color(0xFFB71C1C);
          _resultSuccess = false;
        });
      } else if (res.statusCode == 404) {
        setState(() {
          _result = 'Geçersiz QR.';
          _resultColor = const Color(0xFFB71C1C);
          _resultSuccess = false;
        });
      } else {
        setState(() {
          _result = msg.isNotEmpty ? msg : 'Geçersiz QR.';
          _resultColor = const Color(0xFFB71C1C);
          _resultSuccess = false;
        });
      }
      await _loadUsed();
    } catch (_) {
      setState(() {
        _result = 'Geçersiz QR.';
        _resultColor = const Color(0xFFB71C1C);
        _resultSuccess = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadUsed() async {
    final res = await http.get(
      Uri.parse('$_base/events/${widget.submissionId}/tickets/used?limit=100'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
    );
    if (res.statusCode != 200) return;
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (map['items'] as List<dynamic>? ?? []).whereType<Map<String, dynamic>>().toList();
    if (!mounted) return;
    setState(() => _used = items);
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_loading || !_scannerOpen) return;
    if (DateTime.now().isBefore(_scannerArmedAt)) return;
    String token = '';
    for (final code in capture.barcodes) {
      final raw = (code.rawValue ?? '').trim();
      if (raw.isNotEmpty) {
        token = raw;
        break;
      }
    }
    if (token.isEmpty) return;
    setState(() => _scannerOpen = false);
    await _scannerController.stop();
    if (!mounted) return;
    await _scanToken(token);
  }

  Future<void> _openScanner() async {
    setState(() {
      _scannerOpen = true;
      _lastToken = '';
      _scannerArmedAt = DateTime.now().add(const Duration(milliseconds: 1300));
    });
    try {
      // MobileScanner widget'i cizildikten sonra start cagirmak Android'de daha stabil.
      await Future<void>.delayed(const Duration(milliseconds: 140));
      if (!mounted || !_scannerOpen) return;
      await _scannerController.start();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scannerOpen = false;
        _result = 'Kamera açılamadı. İzinleri kontrol edip tekrar dene.';
        _resultColor = const Color(0xFFB71C1C);
        _resultSuccess = false;
      });
    }
  }

  Future<void> _closeScanner() async {
    setState(() => _scannerOpen = false);
    try {
      await _scannerController.stop();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Bilet Kontrol - ${widget.eventName}')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
          Container(
            height: 220,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white24),
            ),
            clipBehavior: Clip.antiAlias,
            child: _scannerOpen
                ? Container(
                    color: const Color(0xFF070B14),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: 180,
                      height: 180,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: MobileScanner(
                              controller: _scannerController,
                              onDetect: _onDetect,
                            ),
                          ),
                          IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(color: Colors.white70, width: 2),
                              ),
                              child: const Center(
                                child: SizedBox(
                                  width: 126,
                                  height: 126,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      border: Border.fromBorderSide(
                                        BorderSide(color: Color(0xFFE53935), width: 2.6),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : Container(
                    color: const Color(0xFF0F172A),
                    alignment: Alignment.center,
                    child: SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _openScanner,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('QR Tara'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFD32F2F),
                          foregroundColor: Colors.white,
                          textStyle: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                      ),
                    ),
                  ),
          ),
          if (_scannerOpen) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: _loading ? null : _closeScanner,
              icon: const Icon(Icons.close),
              label: const Text('Taramayı Kapat'),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            _scannerOpen
                ? 'QR kodunu kırmızı çerçevenin içine getir. Kamera açıldıktan sonra kısa bir bekleme var.'
                : 'QR Tara butonuna basıp kodu okutun. Sonuç otomatik gösterilir.',
            style: TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            onPressed: _loading ? null : _loadUsed,
            child: const Text('Kullanılmış Biletleri Yenile'),
          ),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _resultColor,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _resultSuccess ? Icons.check_circle : Icons.cancel,
                    color: Colors.white,
                    size: 30,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _result,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        fontSize: 18,
                        height: 1.25,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 14),
          const Text('Kullanılmış Biletler', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          if (_used.isEmpty)
            const Text('Henüz kayıt yok.')
          else
            ..._used.map((x) {
              return Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF121826),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text((x['buyer_name'] ?? '').toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text((x['buyer_email'] ?? '').toString(), style: const TextStyle(color: Colors.white70)),
                    Text('Kullanım: ${(x['used_at'] ?? '').toString()}'),
                    Text('Okutan: ${(x['scanned_by'] ?? '').toString()}', style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class ManageEventsScreen extends StatefulWidget {
  final String sessionToken;

  const ManageEventsScreen({super.key, required this.sessionToken});

  @override
  State<ManageEventsScreen> createState() => _ManageEventsScreenState();
}

class _ManageEventsScreenState extends State<ManageEventsScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_ManagedEventItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<List<_ManagedEventItem>> _fetch() async {
    final res = await http.get(
      Uri.parse('$_base/events/manage/items'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
    );
    if (res.statusCode != 200) {
      throw Exception('Etkinlik listesi alınamadı (${res.statusCode})');
    }
    final map = jsonDecode(res.body) as Map<String, dynamic>;
    final items = (map['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_ManagedEventItem.fromJson)
        .where((item) => !item.isPast)
        .toList();
    items.sort((a, b) => a.sortKey.compareTo(b.sortKey));
    return items;
  }

  Future<void> _refresh() async {
    final f = _fetch();
    setState(() => _future = f);
    await f;
  }

  Future<void> _openEdit(_ManagedEventItem item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: AppTheme.bgPrimary,
          appBar: AppBar(
            backgroundColor: AppTheme.bgPrimary,
            title: const Text('Etkinliği Yönet'),
          ),
          body: SafeArea(
            top: false,
            child: _EditManagedEventSheet(
              sessionToken: widget.sessionToken,
              item: item,
            ),
          ),
        ),
      ),
    );
    if (changed == true && mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Etkinliği Yönet'),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<List<_ManagedEventItem>>(
            future: _future,
            builder: (_, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return ListView(
                  children: [
                    const SizedBox(height: 60),
                    Center(
                      child: TextButton(
                        onPressed: _refresh,
                        child: const Text('Etkinlikler alınamadı, tekrar dene'),
                      ),
                    ),
                  ],
                );
              }
              final items = snap.data ?? [];
              if (items.isEmpty) {
                return ListView(
                  children: const [
                    SizedBox(height: 60),
                    Center(child: Text('Düzenleyebileceğiniz etkinlik bulunamadı.')),
                  ],
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: items.length,
                itemBuilder: (_, i) {
                  final e = items[i];
                  final status = e.status.trim().isEmpty ? '-' : e.status;
                  return InkWell(
                    onTap: () => _openEdit(e),
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: AppTheme.panel(tone: AppTone.events, radius: 18, subtle: true),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (e.coverUrl.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                e.coverUrl,
                                width: 72,
                                height: 54,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 72,
                                  height: 54,
                                  color: const Color(0xFF1F2937),
                                ),
                              ),
                            )
                          else
                            Container(
                              width: 72,
                              height: 54,
                              decoration: BoxDecoration(
                                color: AppTheme.surfacePrimary,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.image_not_supported_outlined, color: AppTheme.textSecondary),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  e.eventDate.isEmpty ? 'Tarih yok' : _toDisplayDate(e.eventDate),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
                                ),
                                const SizedBox(height: 6),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: AppTheme.cyan.withOpacity(0.14),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text(
                                    'Durum: $status',
                                    style: const TextStyle(
                                      color: AppTheme.cyan,
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
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

class _ManagedEventItem {
  final int submissionId;
  final String name;
  final String description;
  final String eventDate;
  final String startAt;
  final String endAt;
  final String venue;
  final String venueMapUrl;
  final String city;
  final String eventKind;
  final List<String> danceStyles;
  final bool ticketSalesEnabled;
  final bool repeatWeekly;
  final int? repeatWeekday;
  final String organizerName;
  final String programText;
  final String entryFee;
  final String coverUrl;
  final String status;

  _ManagedEventItem({
    required this.submissionId,
    required this.name,
    required this.description,
    required this.eventDate,
    required this.startAt,
    required this.endAt,
    required this.venue,
    required this.venueMapUrl,
    required this.city,
    required this.eventKind,
    required this.danceStyles,
    required this.ticketSalesEnabled,
    required this.repeatWeekly,
    required this.repeatWeekday,
    required this.organizerName,
    required this.programText,
    required this.entryFee,
    required this.coverUrl,
    required this.status,
  });

  factory _ManagedEventItem.fromJson(Map<String, dynamic> json) {
    final startAt = (json['start_at'] ?? '').toString();
    final endAt = (json['end_at'] ?? '').toString();
    final eventDate = (json['event_date'] ?? '').toString();
    return _ManagedEventItem(
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      eventDate: startAt.isNotEmpty ? startAt : eventDate,
      startAt: startAt,
      endAt: endAt,
      venue: (json['venue'] ?? '').toString(),
      venueMapUrl: (json['venue_map_url'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      eventKind: (json['event_kind'] ?? '').toString(),
      danceStyles: _normalizeDanceStyles(json['dance_styles']),
      ticketSalesEnabled: (json['ticket_sales_enabled'] == true) || (json['ticket_sales_enabled'] == 1),
      repeatWeekly: (json['repeat_weekly'] == true) || (json['repeat_weekly'] == 1),
      repeatWeekday: (json['repeat_weekday'] as num?)?.toInt(),
      organizerName: (json['organizer_name'] ?? '').toString(),
      programText: (json['program_text'] ?? '').toString(),
      entryFee: (json['entry_fee'] ?? '0').toString(),
      coverUrl: (json['cover_url'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
    );
  }

  DateTime get sortKey {
    final raw = startAt.isNotEmpty ? startAt : eventDate;
    final parsed = DateTime.tryParse(raw.trim().replaceAll(' ', 'T'));
    final dt = parsed == null ? null : (parsed.isUtc ? parsed.toLocal() : parsed);
    if (dt == null) return DateTime.utc(9999, 1, 1);
    final now = DateTime.now();
    final itemDay = DateTime(dt.year, dt.month, dt.day);
    final today = DateTime(now.year, now.month, now.day);
    if (itemDay.isBefore(today)) {
      return DateTime.utc(9999, 1, 1).add(today.difference(itemDay));
    }
    return dt;
  }

  bool get isPast {
    final candidate = endAt.isNotEmpty
        ? endAt
        : (startAt.isNotEmpty ? startAt : eventDate);
    final parsed = DateTime.tryParse(candidate.trim().replaceAll(' ', 'T'));
    if (parsed == null) return false;
    final dt = parsed.isUtc ? parsed.toLocal() : parsed;
    return dt.isBefore(DateTime.now());
  }
}

class _EditManagedEventSheet extends StatefulWidget {
  final String sessionToken;
  final _ManagedEventItem item;

  const _EditManagedEventSheet({
    required this.sessionToken,
    required this.item,
  });

  @override
  State<_EditManagedEventSheet> createState() => _EditManagedEventSheetState();
}

class _EditManagedEventSheetState extends State<_EditManagedEventSheet> {
  static const String _base = 'https://api2.dansmagazin.net';
  late final TextEditingController _descCtrl;
  late final TextEditingController _startDateCtrl;
  late final TextEditingController _startTimeCtrl;
  late final TextEditingController _endDateCtrl;
  late final TextEditingController _endTimeCtrl;
  late final TextEditingController _venueNameCtrl;
  late final TextEditingController _venueMapCtrl;
  late final TextEditingController _orgCtrl;
  late final TextEditingController _programCtrl;
  final List<String> _cities = kTurkiyeCitiesWithUnknown;
  String _city = 'İstanbul';
  String _eventKind = 'dance_night';
  final Set<String> _danceStyles = <String>{};
  bool _repeatWeekly = false;
  int _repeatWeekday = 0;
  bool _saving = false;
  String? _error;
  bool get _isPromoLesson => _eventKind == 'promo_lesson';

  @override
  void initState() {
    super.initState();
    final parts = _splitVenue(widget.item.venue, mapUrl: widget.item.venueMapUrl);
    final parsedDate = _parseEventDate(widget.item.startAt.isNotEmpty ? widget.item.startAt : widget.item.eventDate);
    final endSource = widget.item.endAt.isNotEmpty
        ? widget.item.endAt
        : (widget.item.startAt.isNotEmpty ? widget.item.startAt : widget.item.eventDate);
    _descCtrl = TextEditingController(text: widget.item.description);
    _startDateCtrl = TextEditingController(
      text: _toDisplayDate(widget.item.startAt.isNotEmpty ? widget.item.startAt : widget.item.eventDate),
    );
    _startTimeCtrl = TextEditingController(
      text: _toDisplayTime(widget.item.startAt.isNotEmpty ? widget.item.startAt : widget.item.eventDate),
    );
    _endDateCtrl = TextEditingController(text: _toDisplayDate(endSource));
    _endTimeCtrl = TextEditingController(text: _toDisplayTime(endSource));
    _venueNameCtrl = TextEditingController(text: parts.name);
    _venueMapCtrl = TextEditingController(text: parts.mapUrl);
    _orgCtrl = TextEditingController(text: widget.item.organizerName);
    _programCtrl = TextEditingController(text: widget.item.programText);
    _city = widget.item.city.trim().isEmpty ? 'Belirtilmedi' : widget.item.city.trim();
    _eventKind = _normalizeKind(widget.item.eventKind);
    _danceStyles.addAll(_normalizeDanceStyles(widget.item.danceStyles));
    _repeatWeekly = widget.item.repeatWeekly;
    final fallbackWeekday = (parsedDate ?? DateTime.now()).weekday - 1;
    final itemWeekday = widget.item.repeatWeekday;
    _repeatWeekday = (itemWeekday != null && itemWeekday >= 0 && itemWeekday <= 6)
        ? itemWeekday
        : fallbackWeekday.clamp(0, 6).toInt();
    if (_isPromoLesson) {
      _repeatWeekly = false;
    }
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _startDateCtrl.dispose();
    _startTimeCtrl.dispose();
    _endDateCtrl.dispose();
    _endTimeCtrl.dispose();
    _venueNameCtrl.dispose();
    _venueMapCtrl.dispose();
    _orgCtrl.dispose();
    _programCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final startMoment = _combineDateAndTime(_startDateCtrl.text.trim(), _startTimeCtrl.text.trim());
    final endMoment = _combineDateAndTime(_endDateCtrl.text.trim(), _endTimeCtrl.text.trim());
    if (startMoment == null) {
      setState(() => _error = 'Başlangıç tarihi ve saati zorunlu.');
      return;
    }
    if (endMoment == null) {
      setState(() => _error = 'Bitiş tarihi ve saati zorunlu.');
      return;
    }
    if (endMoment.isBefore(startMoment)) {
      setState(() => _error = 'Bitiş tarihi başlangıçtan önce olamaz.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final effectiveRepeatWeekly = !_isPromoLesson && _repeatWeekly;
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/events/manage/items/${widget.item.submissionId}/update'),
      )
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['description'] = _descCtrl.text.trim()
        ..fields['event_date'] = _toApiDate(_startDateCtrl.text.trim())
        ..fields['start_at'] = _toApiDateTime(_startDateCtrl.text.trim(), _startTimeCtrl.text.trim())
        ..fields['end_at'] = _toApiDateTime(_endDateCtrl.text.trim(), _endTimeCtrl.text.trim())
        ..fields['venue'] = _venueNameCtrl.text.trim()
        ..fields['venue_map_url'] = _normalizeMapUrl(_venueMapCtrl.text.trim())
        ..fields['city'] = _city
        ..fields['event_kind'] = _eventKind
        ..fields['dance_styles'] = _danceStylesPayload(_danceStyles)
        ..fields['repeat_weekly'] = effectiveRepeatWeekly ? '1' : '0'
        ..fields['repeat_weekday'] = effectiveRepeatWeekly ? _repeatWeekday.toString() : ''
        ..fields['organizer_name'] = _orgCtrl.text.trim()
        ..fields['program_text'] = _programCtrl.text.trim();
      final res = await req.send();
      final body = await res.stream.bytesToString();
      if (res.statusCode != 200) {
        setState(() => _error = parseApiErrorBody(body, fallback: 'Kaydetme başarısız'));
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Hata: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.panel(tone: AppTone.events, radius: 20, elevated: true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.item.eventDate.isEmpty ? 'Tarih bilgisi yok' : _toDisplayDate(widget.item.eventDate),
                  style: const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(
                  widget.item.city.trim().isEmpty ? 'Şehir belirtilmedi' : widget.item.city,
                  style: const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _section(
            'Genel Bilgiler',
            [
              _txt(_descCtrl, 'Detaylar', maxLines: 3),
              _txt(_programCtrl, 'Program', maxLines: 3),
              _txt(_orgCtrl, 'Organizatör'),
            ],
          ),
          _section(
            'Mekan ve Tür',
            [
              _txt(_venueNameCtrl, 'Mekan Adı'),
              _txt(_venueMapCtrl, 'Konum Linki', keyboardType: TextInputType.url),
              DropdownButtonFormField<String>(
                value: _cities.contains(_city) ? _city : 'Belirtilmedi',
                items: _cities
                    .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
                    .toList(),
                onChanged: _saving ? null : (v) => setState(() => _city = v ?? _city),
                decoration: _fieldDecoration('Şehir'),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _eventKind,
                items: const [
                  DropdownMenuItem(value: 'dance_night', child: Text('Dans Gecesi')),
                  DropdownMenuItem(value: 'festival', child: Text('Festival')),
                  DropdownMenuItem(value: 'competition', child: Text('Yarışma')),
                  DropdownMenuItem(value: 'promo_lesson', child: Text('Tanıtım Dersi')),
                ],
                onChanged: _saving
                    ? null
                    : (v) => setState(() {
                          _eventKind = v ?? _eventKind;
                          if (_isPromoLesson) {
                            _repeatWeekly = false;
                          }
                        }),
                decoration: _fieldDecoration('Etkinlik Türü'),
              ),
              const SizedBox(height: 4),
              _DanceStylesField(
                selectedStyles: _danceStyles,
                onToggle: _saving
                    ? null
                    : (style) => setState(() {
                          if (_danceStyles.contains(style)) {
                            _danceStyles.remove(style);
                          } else {
                            _danceStyles.add(style);
                          }
                        }),
              ),
            ],
          ),
          _section(
            'Tarih ve Tekrar',
            [
              _dateTimeBlock(
                title: 'Başlangıç',
                dateCtrl: _startDateCtrl,
                timeCtrl: _startTimeCtrl,
                dateLabel: 'Başlangıç Tarihi',
                timeLabel: 'Başlangıç Saati',
                updateRepeatWeekday: true,
              ),
              _dateTimeBlock(
                title: 'Bitiş',
                dateCtrl: _endDateCtrl,
                timeCtrl: _endTimeCtrl,
                dateLabel: 'Bitiş Tarihi',
                timeLabel: 'Bitiş Saati',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tekrarlayan Etkinlik'),
                subtitle: Text(
                  _isPromoLesson
                      ? 'Tanıtım derslerinde tekrarlayan etkinlik kapalıdır'
                      : 'Açıkken tarihi geçen etkinlik kapanır, aynı etkinliğin yenisi otomatik açılır.',
                ),
                value: _isPromoLesson ? false : _repeatWeekly,
                onChanged: (_saving || _isPromoLesson) ? null : (v) => setState(() => _repeatWeekly = v),
              ),
              if (!_isPromoLesson && _repeatWeekly)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<int>(
                    value: _repeatWeekday,
                    items: List.generate(
                      _weekdayLabels.length,
                      (i) => DropdownMenuItem<int>(value: i, child: Text(_weekdayLabels[i])),
                    ),
                    onChanged: _saving ? null : (v) => setState(() => _repeatWeekday = v ?? _repeatWeekday),
                    decoration: _fieldDecoration('Tekrar Günü'),
                  ),
                ),
            ],
          ),
          _EventRaffleSection(
            sessionToken: widget.sessionToken,
            submissionId: widget.item.submissionId,
            eventName: widget.item.name,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Kaydediliyor...' : 'Değişiklikleri Kaydet'),
            ),
          ),
          const SizedBox(height: 12),
          _section(
            'Bilet Desteği',
            [
              _TicketSalesHelpCard(
                sessionToken: widget.sessionToken,
                busy: _saving,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.events, radius: 20, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _txt(
    TextEditingController c,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: keyboardType ?? (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
        textInputAction: maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
        enableInteractiveSelection: true,
        decoration: _fieldDecoration(label),
      ),
    );
  }

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: AppTheme.surfacePrimary,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.borderSoft),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
      ),
    );
  }

  String _normalizeKind(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'festival' || v == 'competition' || v == 'dance_night' || v == 'promo_lesson') return v;
    return 'dance_night';
  }

  Future<void> _pickDate(TextEditingController ctrl, {bool updateRepeatWeekday = false}) async {
    final initial = _parseEventDate(ctrl.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    ctrl.text = _toDisplayDate(date.toIso8601String());
    if (updateRepeatWeekday && _repeatWeekly && !_isPromoLesson) {
      setState(() => _repeatWeekday = date.weekday - 1);
    }
  }

  Future<void> _pickTime(TextEditingController ctrl) async {
    final initial = _parseTimeOfDay(ctrl.text) ?? const TimeOfDay(hour: 21, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final h = picked.hour.toString().padLeft(2, '0');
    final m = picked.minute.toString().padLeft(2, '0');
    ctrl.text = '$h.$m';
  }

  Widget _dateTimeBlock({
    required String title,
    required TextEditingController dateCtrl,
    required TextEditingController timeCtrl,
    required String dateLabel,
    required String timeLabel,
    bool updateRepeatWeekday = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _dateField(dateCtrl, dateLabel, updateRepeatWeekday: updateRepeatWeekday),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _timeField(timeCtrl, timeLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _timeField(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickTime(c),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: AppTheme.surfacePrimary,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppTheme.borderSoft),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
          ),
          suffixIcon: const Icon(Icons.access_time),
        ),
      ),
    );
  }

  Widget _dateField(TextEditingController c, String label, {bool updateRepeatWeekday = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickDate(c, updateRepeatWeekday: updateRepeatWeekday),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: AppTheme.surfacePrimary,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppTheme.borderSoft),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
          ),
          suffixIcon: const Icon(Icons.calendar_month),
        ),
      ),
    );
  }
}

class _EventRaffleSection extends StatefulWidget {
  final String sessionToken;
  final int submissionId;
  final String eventName;

  const _EventRaffleSection({
    required this.sessionToken,
    required this.submissionId,
    required this.eventName,
  });

  @override
  State<_EventRaffleSection> createState() => _EventRaffleSectionState();
}

class _EventRaffleSectionState extends State<_EventRaffleSection> {
  bool _loading = true;
  bool _drawing = false;
  bool _opening = false;
  bool _closing = false;
  String? _error;
  EventRaffleDetail? _raffle;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await EventSocialApi.raffle(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() {
        _raffle = result.raffle;
        _error = null;
      });
    } on EventSocialApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Çekiliş bilgisi alınamadı: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openEditor() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _EventRaffleEditorScreen(
          sessionToken: widget.sessionToken,
          submissionId: widget.submissionId,
          eventName: widget.eventName,
          raffle: _raffle,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _load();
    }
  }

  Future<void> _draw() async {
    final raffle = _raffle;
    if (raffle == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceSecondary,
        title: const Text('Kazananları Belirle'),
        content: Text(
          '${raffle.entryCount} katılımcı arasından ${raffle.winnerCount} asıl ve ${raffle.reserveCount} yedek talihli seçilecek. Bu işlemden sonra sonuçlar değiştirilemez.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Belirle'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _drawing = true);
    try {
      final updated = await EventSocialApi.drawRaffle(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() => _raffle = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kazananlar belirlendi.')),
      );
    } on EventSocialApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _drawing = false);
    }
  }

  Future<void> _openEntries() async {
    if (_opening) return;
    setState(() => _opening = true);
    try {
      final updated = await EventSocialApi.openRaffle(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() => _raffle = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Başvurular açıldı.')),
      );
    } on EventSocialApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _closeEntries() async {
    if (_closing) return;
    setState(() => _closing = true);
    try {
      final updated = await EventSocialApi.closeRaffle(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() => _raffle = updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Başvurular durduruldu.')),
      );
    } on EventSocialApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _closing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final raffle = _raffle;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.events, radius: 20, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Etkinlik İçi Çekiliş',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (_loading)
            const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()))
          else if ((_error ?? '').trim().isNotEmpty) ...[
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(onPressed: _load, child: const Text('Tekrar Dene')),
            ),
          ] else if (raffle == null) ...[
            const Text(
              'Bu etkinlik için henüz çekiliş hazırlanmamış.',
              style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _openEditor,
                icon: const Icon(Icons.celebration_outlined),
                label: const Text('Çekilişi Hazırla'),
              ),
            ),
          ] else ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _RaffleMetaChip(label: _raffleStateLabel(raffle.state)),
                _RaffleMetaChip(label: '${raffle.entryCount} katılımcı'),
                _RaffleMetaChip(label: '${raffle.winnerCount} asıl'),
                _RaffleMetaChip(label: '${raffle.reserveCount} yedek'),
              ],
            ),
            const SizedBox(height: 12),
            if (raffle.startsAt.trim().isNotEmpty)
              _RaffleInfoRow(label: 'Başvurular Açıldı', value: _toDisplayRaffleMoment(raffle.startsAt)),
            if (raffle.endsAt.trim().isNotEmpty)
              _RaffleInfoRow(label: 'Başvurular Durdu', value: _toDisplayRaffleMoment(raffle.endsAt)),
            if (raffle.drawnAt.trim().isNotEmpty)
              _RaffleInfoRow(label: 'Çekiliş Sonucu', value: _toDisplayRaffleMoment(raffle.drawnAt)),
            if (raffle.primaryWinners.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Asıl Talihliler', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...raffle.primaryWinners.map(
                (winner) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: AppTheme.glassPanel(tone: AppTone.events, radius: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.orange.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          winner.position.toString(),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          winner.name.trim().isEmpty ? 'Kullanıcı' : winner.name.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (raffle.reserveWinners.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text('Yedek Talihliler', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              ...raffle.reserveWinners.map(
                (winner) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: AppTheme.glassPanel(tone: AppTone.events, radius: 16),
                  child: Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.info.withOpacity(0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          winner.position.toString(),
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          winner.name.trim().isEmpty ? 'Kullanıcı' : winner.name.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: raffle.canEdit ? _openEditor : null,
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: Text(raffle.canEdit ? 'Çekilişi Düzenle' : 'Sonuçlandı'),
                ),
                if (raffle.canOpen)
                  ElevatedButton.icon(
                    onPressed: _opening ? null : _openEntries,
                    icon: _opening
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.play_circle_outline),
                    label: Text(_opening ? 'Açılıyor...' : 'Başvuruları Aç'),
                  ),
                if (raffle.canClose)
                  OutlinedButton.icon(
                    onPressed: _closing ? null : _closeEntries,
                    icon: _closing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.pause_circle_outline),
                    label: Text(_closing ? 'Durduruluyor...' : 'Başvuruları Durdur'),
                  ),
                if (raffle.canDraw)
                  ElevatedButton.icon(
                    onPressed: _drawing ? null : _draw,
                    icon: _drawing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(_drawing ? 'Belirleniyor...' : 'Çekiliş Yap'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EventRaffleEditorScreen extends StatefulWidget {
  final String sessionToken;
  final int submissionId;
  final String eventName;
  final EventRaffleDetail? raffle;

  const _EventRaffleEditorScreen({
    required this.sessionToken,
    required this.submissionId,
    required this.eventName,
    required this.raffle,
  });

  @override
  State<_EventRaffleEditorScreen> createState() => _EventRaffleEditorScreenState();
}

class _EventRaffleEditorScreenState extends State<_EventRaffleEditorScreen> {
  late final TextEditingController _winnerCountCtrl;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final raffle = widget.raffle;
    _winnerCountCtrl = TextEditingController(text: raffle == null ? '1' : raffle.winnerCount.toString());
  }

  @override
  void dispose() {
    _winnerCountCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final winnerCount = int.tryParse(_winnerCountCtrl.text.trim());
    if (winnerCount == null || winnerCount < 1 || winnerCount > 100) {
      setState(() => _error = 'Talihli sayısı 1 ile 100 arasında olmalı.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await EventSocialApi.upsertRaffle(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
        winnerCount: winnerCount,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on EventSocialApiException catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Etkinlik İçi Çekiliş'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: AppTheme.panel(tone: AppTone.events, radius: 20, elevated: true),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.eventName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Talihli sayısını belirle. Başvuruları istediğin anda açıp durdurabilir, ardından aynı sayı kadar asıl ve yedek talihli seçebilirsin.',
                    style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: AppTheme.panel(tone: AppTone.events, radius: 20, subtle: true),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Çekiliş Ayarı', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _winnerCountCtrl,
                    keyboardType: TextInputType.number,
                    decoration: _raffleFieldDecoration('Kaç Kişi (Asıl + Yedek)'),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Örnek: 3 girersen çekiliş yapıldığında 3 asıl ve 3 yedek talihli belirlenir.',
                    style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
                  ),
                ],
              ),
            ),
            if ((_error ?? '').trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Kaydediliyor...' : 'Çekilişi Kaydet'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RaffleDateTimeBlock extends StatelessWidget {
  final String title;
  final TextEditingController dateCtrl;
  final TextEditingController timeCtrl;
  final String dateLabel;
  final String timeLabel;
  final Future<void> Function(TextEditingController controller) onPickDate;
  final Future<void> Function(TextEditingController controller) onPickTime;

  const _RaffleDateTimeBlock({
    required this.title,
    required this.dateCtrl,
    required this.timeCtrl,
    required this.dateLabel,
    required this.timeLabel,
    required this.onPickDate,
    required this.onPickTime,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: dateCtrl,
                  readOnly: true,
                  onTap: () => onPickDate(dateCtrl),
                  decoration: _raffleFieldDecoration(dateLabel, suffixIcon: Icons.calendar_month),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: timeCtrl,
                  readOnly: true,
                  onTap: () => onPickTime(timeCtrl),
                  decoration: _raffleFieldDecoration(timeLabel, suffixIcon: Icons.access_time),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _RaffleMetaChip extends StatelessWidget {
  final String label;

  const _RaffleMetaChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.cyan.withOpacity(0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.cyan,
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _RaffleInfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _RaffleInfoRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

InputDecoration _raffleFieldDecoration(String label, {IconData? suffixIcon}) {
  return InputDecoration(
    labelText: label,
    filled: true,
    fillColor: AppTheme.surfacePrimary,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppTheme.borderSoft),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
    ),
    suffixIcon: suffixIcon == null ? null : Icon(suffixIcon),
  );
}

String _raffleStateLabel(String state) {
  switch (state.trim().toLowerCase()) {
    case 'draft':
      return 'Başvuru Kapalı';
    case 'scheduled':
      return 'Başvuru Kapalı';
    case 'active':
      return 'Katılıma Açık';
    case 'closed':
      return 'Başvuru Durdu';
    case 'drawn':
      return 'Sonuçlandı';
    default:
      return 'Çekiliş';
  }
}

String _toDisplayRaffleMoment(String raw) {
  final date = _toDisplayDate(raw);
  final time = _toDisplayTime(raw);
  if (time.trim().isEmpty) return date;
  return '$date • $time';
}

class _CreateEventSheet extends StatefulWidget {
  final String sessionToken;

  const _CreateEventSheet({required this.sessionToken});

  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  static const String _submitUrl = 'https://api2.dansmagazin.net/events/submissions';

  final _eventCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _programCtrl = TextEditingController();
  final _venueNameCtrl = TextEditingController();
  final _venueMapCtrl = TextEditingController();
  final _orgCtrl = TextEditingController();
  final _startDateCtrl = TextEditingController();
  final _startTimeCtrl = TextEditingController();
  final _endDateCtrl = TextEditingController();
  final _endTimeCtrl = TextEditingController();
  final _feeCtrl = TextEditingController(text: '0');
  final List<String> _cities = kTurkiyeCities;
  String _city = 'İstanbul';
  String _eventKind = 'dance_night';
  final Set<String> _danceStyles = <String>{};
  bool _repeatWeekly = false;
  int _repeatWeekday = DateTime.now().weekday - 1;

  final _picker = ImagePicker();
  XFile? _image;
  bool _sending = false;
  String? _error;
  bool get _isPromoLesson => _eventKind == 'promo_lesson';

  @override
  void dispose() {
    _eventCtrl.dispose();
    _descCtrl.dispose();
    _programCtrl.dispose();
    _venueNameCtrl.dispose();
    _venueMapCtrl.dispose();
    _orgCtrl.dispose();
    _startDateCtrl.dispose();
    _startTimeCtrl.dispose();
    _endDateCtrl.dispose();
    _endTimeCtrl.dispose();
    _feeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController ctrl, {bool updateRepeatWeekday = false}) async {
    final initial = _parseEventDate(ctrl.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    ctrl.text = _toDisplayDate(date.toIso8601String());
    if (updateRepeatWeekday && _repeatWeekly && !_isPromoLesson) {
      setState(() => _repeatWeekday = date.weekday - 1);
    }
  }

  Future<void> _pickTime(TextEditingController ctrl) async {
    final initial = _parseTimeOfDay(ctrl.text) ?? const TimeOfDay(hour: 21, minute: 0);
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked == null || !mounted) return;
    final h = picked.hour.toString().padLeft(2, '0');
    final m = picked.minute.toString().padLeft(2, '0');
    ctrl.text = '$h.$m';
  }

  Future<void> _submit() async {
    if (_eventCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Etkinlik adı zorunlu.');
      return;
    }
    final startMoment = _combineDateAndTime(_startDateCtrl.text.trim(), _startTimeCtrl.text.trim());
    final endMoment = _combineDateAndTime(_endDateCtrl.text.trim(), _endTimeCtrl.text.trim());
    if (startMoment == null) {
      setState(() => _error = 'Başlangıç tarihi ve saati zorunlu.');
      return;
    }
    if (endMoment == null) {
      setState(() => _error = 'Bitiş tarihi ve saati zorunlu.');
      return;
    }
    if (endMoment.isBefore(startMoment)) {
      setState(() => _error = 'Bitiş tarihi başlangıçtan önce olamaz.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final effectiveRepeatWeekly = !_isPromoLesson && _repeatWeekly;
      final req = http.MultipartRequest('POST', Uri.parse(_submitUrl))
        ..fields['event_name'] = _eventCtrl.text.trim()
        ..fields['description'] = _descCtrl.text.trim()
        ..fields['program_text'] = _programCtrl.text.trim()
        ..fields['venue'] = _venueNameCtrl.text.trim()
        ..fields['venue_map_url'] = _normalizeMapUrl(_venueMapCtrl.text.trim())
        ..fields['city'] = _city
        ..fields['event_kind'] = _eventKind
        ..fields['dance_styles'] = _danceStylesPayload(_danceStyles)
        ..fields['ticket_sales_enabled'] = '0'
        ..fields['repeat_weekly'] = effectiveRepeatWeekly ? '1' : '0'
        ..fields['repeat_weekday'] = effectiveRepeatWeekly ? _repeatWeekday.toString() : ''
        ..fields['organizer_name'] = _orgCtrl.text.trim()
        ..fields['event_date'] = _toApiDate(_startDateCtrl.text.trim())
        ..fields['start_at'] = _toApiDateTime(_startDateCtrl.text.trim(), _startTimeCtrl.text.trim())
        ..fields['end_at'] = _toApiDateTime(_endDateCtrl.text.trim(), _endTimeCtrl.text.trim())
        ..fields['entry_fee'] = _feeCtrl.text.trim();
      final token = widget.sessionToken.trim();
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      if (_image != null) {
        req.files.add(await http.MultipartFile.fromPath('cover_image', _image!.path));
      }
      final streamed = await req.send();
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        setState(() => _error = parseApiErrorBody(body, fallback: 'Gönderim başarısız'));
        return;
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = 'Hata: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text('Etkinliğini Ekle', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  ),
                  TextButton(
                    onPressed: _sending ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Vazgeç'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _txt(_eventCtrl, 'Etkinlik Adı'),
              _txt(_descCtrl, 'Detaylar', maxLines: 3),
              _txt(_programCtrl, 'Program', maxLines: 3),
              _txt(_venueNameCtrl, 'Mekan Adı'),
              _txt(_venueMapCtrl, 'Konum Linki', keyboardType: TextInputType.url),
              DropdownButtonFormField<String>(
                value: _city,
                items: _cities
                    .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
                    .toList(),
                onChanged: _sending ? null : (v) => setState(() => _city = v ?? _city),
                decoration: InputDecoration(
                  labelText: 'Şehir',
                  filled: true,
                  fillColor: const Color(0xFF111827),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _eventKind,
                items: const [
                  DropdownMenuItem(value: 'dance_night', child: Text('Dans Gecesi')),
                  DropdownMenuItem(value: 'festival', child: Text('Festival')),
                  DropdownMenuItem(value: 'competition', child: Text('Yarışma')),
                  DropdownMenuItem(value: 'promo_lesson', child: Text('Tanıtım Dersi')),
                ],
                onChanged: _sending
                    ? null
                    : (v) => setState(() {
                          _eventKind = v ?? _eventKind;
                          if (_isPromoLesson) {
                            _repeatWeekly = false;
                          }
                        }),
                decoration: InputDecoration(
                  labelText: 'Etkinlik Türü',
                  filled: true,
                  fillColor: const Color(0xFF111827),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 4),
              _DanceStylesField(
                selectedStyles: _danceStyles,
                onToggle: _sending
                    ? null
                    : (style) => setState(() {
                          if (_danceStyles.contains(style)) {
                            _danceStyles.remove(style);
                          } else {
                            _danceStyles.add(style);
                          }
                        }),
              ),
              _txt(_orgCtrl, 'Organizatör'),
              _dateTimeBlock(
                title: 'Başlangıç',
                dateCtrl: _startDateCtrl,
                timeCtrl: _startTimeCtrl,
                dateLabel: 'Başlangıç Tarihi',
                timeLabel: 'Başlangıç Saati',
                updateRepeatWeekday: true,
              ),
              _dateTimeBlock(
                title: 'Bitiş',
                dateCtrl: _endDateCtrl,
                timeCtrl: _endTimeCtrl,
                dateLabel: 'Bitiş Tarihi',
                timeLabel: 'Bitiş Saati',
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Tekrarlayan Etkinlik'),
                subtitle: Text(
                  _isPromoLesson
                      ? 'Tanıtım derslerinde tekrarlayan etkinlik kapalıdır'
                      : 'Açıkken tarihi geçen etkinlik kapanır, aynı etkinliğin yenisi otomatik açılır.',
                ),
                value: _isPromoLesson ? false : _repeatWeekly,
                onChanged: (_sending || _isPromoLesson) ? null : (v) => setState(() => _repeatWeekly = v),
              ),
              if (!_isPromoLesson && _repeatWeekly)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<int>(
                    value: _repeatWeekday,
                    items: List.generate(
                      _weekdayLabels.length,
                      (i) => DropdownMenuItem<int>(value: i, child: Text(_weekdayLabels[i])),
                    ),
                    onChanged: _sending ? null : (v) => setState(() => _repeatWeekday = v ?? _repeatWeekday),
                    decoration: InputDecoration(
                      labelText: 'Tekrar Günü',
                      filled: true,
                      fillColor: const Color(0xFF111827),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              _txt(_feeCtrl, 'Bilet Ücreti (TL)'),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _sending
                        ? null
                        : () async {
                            try {
                              final x = await _picker
                                  .pickImage(
                                    source: ImageSource.gallery,
                                    imageQuality: 85,
                                    requestFullMetadata: false,
                                    maxWidth: 1440,
                                  )
                                  .timeout(const Duration(seconds: 25));
                              if (x != null && mounted) {
                                setState(() => _image = x);
                              }
                            } on TimeoutException {
                              if (!mounted) return;
                              setState(() => _error = 'Galeri yanıt vermedi, tekrar deneyin.');
                            } catch (e) {
                              if (!mounted) return;
                              setState(() => _error = 'Fotoğraf seçilemedi: $e');
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size(120, 42),
                    ),
                    icon: const Icon(Icons.image),
                    label: const Text('Kapak Seç'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_image == null ? 'Seçilmedi' : _image!.name, overflow: TextOverflow.ellipsis)),
                ],
              ),
              if (_image != null) ...[
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(_image!.path), height: 120, fit: BoxFit.cover),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _sending ? null : _submit,
                  child: Text(_sending ? 'Gönderiliyor...' : 'Onaya Gönder'),
                ),
              ),
              const SizedBox(height: 12),
              _TicketSalesHelpCard(
                sessionToken: widget.sessionToken,
                busy: _sending,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _txt(
    TextEditingController c,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: keyboardType ?? (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
        textInputAction: maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
        enableInteractiveSelection: true,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF111827),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _dateTimeBlock({
    required String title,
    required TextEditingController dateCtrl,
    required TextEditingController timeCtrl,
    required String dateLabel,
    required String timeLabel,
    bool updateRepeatWeekday = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: _dateField(dateCtrl, dateLabel, updateRepeatWeekday: updateRepeatWeekday),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _timeField(timeCtrl, timeLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _timeField(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickTime(c),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF111827),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          suffixIcon: const Icon(Icons.access_time),
        ),
      ),
    );
  }

  Widget _dateField(TextEditingController c, String label, {bool updateRepeatWeekday = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickDate(c, updateRepeatWeekday: updateRepeatWeekday),
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF111827),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          suffixIcon: const Icon(Icons.calendar_month),
        ),
      ),
    );
  }
}
