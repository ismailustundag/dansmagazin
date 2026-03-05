import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../services/turkiye_cities.dart';

DateTime? _parseEventDate(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  final ddmmyyyy = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(v);
  if (ddmmyyyy != null) {
    final d = int.tryParse(ddmmyyyy.group(1)!);
    final m = int.tryParse(ddmmyyyy.group(2)!);
    final y = int.tryParse(ddmmyyyy.group(3)!);
    if (d != null && m != null && y != null) return DateTime(y, m, d);
  }
  final dt = DateTime.tryParse(v) ?? DateTime.tryParse(v.replaceAll(' ', 'T'));
  if (dt != null) return dt;
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
  return '$d.$m.$y';
}

String _toApiDate(String raw) {
  final dt = _parseEventDate(raw);
  if (dt == null) return raw.trim();
  final d = dt.day.toString().padLeft(2, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final y = dt.year.toString();
  return '$y-$m-$d';
}

class EditorEventManagementScreen extends StatelessWidget {
  final String sessionToken;

  const EditorEventManagementScreen({super.key, required this.sessionToken});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Etkinlik Yönetimi')),
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
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            Icon(icon, color: const Color(0xFFE53935)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: const TextStyle(color: Colors.white70)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: Colors.white54),
          ],
        ),
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
      eventDate: (json['event_date'] ?? '').toString(),
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
  Color _resultColor = Colors.white;
  List<Map<String, dynamic>> _used = const [];
  String _lastToken = '';
  DateTime _lastScanAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _scannerArmedAt = DateTime.fromMillisecondsSinceEpoch(0);
  String _pendingToken = '';

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
      final msg = (map['message'] ?? map['detail'] ?? '').toString();
      if (res.statusCode == 200 && state == 'accepted') {
        setState(() {
          _result = msg.isNotEmpty ? msg : 'Bilet geçerli.';
          _resultColor = Colors.greenAccent;
        });
      } else if (res.statusCode == 200 && state == 'already_used') {
        setState(() {
          _result = msg.isNotEmpty ? msg : 'Bilet daha önce kullanılmış.';
          _resultColor = Colors.amberAccent;
        });
      } else if (res.statusCode == 404) {
        setState(() {
          _result = 'Geçersiz QR.';
          _resultColor = Colors.redAccent;
        });
      } else {
        setState(() {
          _result = msg.isNotEmpty ? msg : 'Geçersiz QR.';
          _resultColor = Colors.redAccent;
        });
      }
      await _loadUsed();
    } catch (_) {
      setState(() {
        _result = 'Geçersiz QR.';
        _resultColor = Colors.redAccent;
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
    if (_loading || !_scannerOpen || _pendingToken.isNotEmpty) return;
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
    setState(() => _pendingToken = token);
  }

  Future<void> _openScanner() async {
    setState(() {
      _scannerOpen = true;
      _pendingToken = '';
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
        _resultColor = Colors.redAccent;
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
                      width: 180,
                      height: 48,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _openScanner,
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('QR Tara'),
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
                : 'Bilet doğrulamak için QR Tara butonuna basın.',
            style: TextStyle(color: Colors.white70),
          ),
          if (_pendingToken.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF1F2937),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white24),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('QR algılandı', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    _pendingToken.length > 40 ? '${_pendingToken.substring(0, 40)}...' : _pendingToken,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _loading
                            ? null
                            : () async {
                                final t = _pendingToken;
                                setState(() => _pendingToken = '');
                                await Future<void>.delayed(const Duration(milliseconds: 350));
                                await _scanToken(t);
                              },
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Doğrula'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _loading
                            ? null
                            : () async {
                                setState(() => _pendingToken = '');
                                await _openScanner();
                              },
                        icon: const Icon(Icons.refresh),
                        label: const Text('Yeniden Tara'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
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
                color: _resultColor.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _resultColor.withOpacity(0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    _resultColor == Colors.greenAccent
                        ? Icons.check_circle
                        : (_resultColor == Colors.amberAccent ? Icons.warning_amber_rounded : Icons.cancel),
                    color: _resultColor,
                    size: 30,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _result,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _resultColor,
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
    return (map['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_ManagedEventItem.fromJson)
        .toList();
  }

  Future<void> _refresh() async {
    final f = _fetch();
    setState(() => _future = f);
    await f;
  }

  Future<void> _openEdit(_ManagedEventItem item) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      builder: (_) => _EditManagedEventSheet(
        sessionToken: widget.sessionToken,
        item: item,
      ),
    );
    if (changed == true && mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Etkinliği Yönet')),
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
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121826),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          if (e.coverUrl.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
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
                                color: const Color(0xFF1F2937),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(Icons.image_not_supported_outlined, color: Colors.white54),
                            ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  e.eventDate.isEmpty ? 'Tarih yok' : _toDisplayDate(e.eventDate),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  'Durum: $status',
                                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                                ),
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
  final String venue;
  final String city;
  final String eventKind;
  final bool ticketSalesEnabled;
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
    required this.venue,
    required this.city,
    required this.eventKind,
    required this.ticketSalesEnabled,
    required this.organizerName,
    required this.programText,
    required this.entryFee,
    required this.coverUrl,
    required this.status,
  });

  factory _ManagedEventItem.fromJson(Map<String, dynamic> json) {
    return _ManagedEventItem(
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      eventDate: (json['event_date'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      eventKind: (json['event_kind'] ?? '').toString(),
      ticketSalesEnabled: (json['ticket_sales_enabled'] == true) || (json['ticket_sales_enabled'] == 1),
      organizerName: (json['organizer_name'] ?? '').toString(),
      programText: (json['program_text'] ?? '').toString(),
      entryFee: (json['entry_fee'] ?? '0').toString(),
      coverUrl: (json['cover_url'] ?? '').toString(),
      status: (json['status'] ?? '').toString(),
    );
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
  late final TextEditingController _dateCtrl;
  late final TextEditingController _venueCtrl;
  late final TextEditingController _orgCtrl;
  late final TextEditingController _programCtrl;
  final List<String> _cities = kTurkiyeCitiesWithUnknown;
  String _city = 'İstanbul';
  String _eventKind = 'dance_night';
  bool _ticketSalesEnabled = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _descCtrl = TextEditingController(text: widget.item.description);
    _dateCtrl = TextEditingController(text: _toDisplayDate(widget.item.eventDate));
    _venueCtrl = TextEditingController(text: widget.item.venue);
    _orgCtrl = TextEditingController(text: widget.item.organizerName);
    _programCtrl = TextEditingController(text: widget.item.programText);
    _city = widget.item.city.trim().isEmpty ? 'Belirtilmedi' : widget.item.city.trim();
    _eventKind = _normalizeKind(widget.item.eventKind);
    _ticketSalesEnabled = widget.item.ticketSalesEnabled;
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _dateCtrl.dispose();
    _venueCtrl.dispose();
    _orgCtrl.dispose();
    _programCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/events/manage/items/${widget.item.submissionId}/update'),
      )
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['description'] = _descCtrl.text.trim()
        ..fields['event_date'] = _toApiDate(_dateCtrl.text.trim())
        ..fields['venue'] = _venueCtrl.text.trim()
        ..fields['city'] = _city
        ..fields['event_kind'] = _eventKind
        ..fields['ticket_sales_enabled'] = _ticketSalesEnabled ? '1' : '0'
        ..fields['organizer_name'] = _orgCtrl.text.trim()
        ..fields['program_text'] = _programCtrl.text.trim();
      final res = await req.send();
      final body = await res.stream.bytesToString();
      if (res.statusCode != 200) {
        setState(() => _error = 'Kaydetme başarısız: ${res.statusCode} $body');
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
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                  ),
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(false),
                    child: const Text('Kapat'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              _txt(_descCtrl, 'Detaylar', maxLines: 3),
              _txt(_programCtrl, 'Program', maxLines: 3),
              _txt(_venueCtrl, 'Konum / Mekan'),
              DropdownButtonFormField<String>(
                value: _cities.contains(_city) ? _city : 'Belirtilmedi',
                items: _cities
                    .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
                    .toList(),
                onChanged: _saving ? null : (v) => setState(() => _city = v ?? _city),
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
                ],
                onChanged: _saving ? null : (v) => setState(() => _eventKind = v ?? _eventKind),
                decoration: InputDecoration(
                  labelText: 'Etkinlik Türü',
                  filled: true,
                  fillColor: const Color(0xFF111827),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bilet Satışına Aç'),
                subtitle: const Text('Kapalıysa etkinlik yalnızca uygulamada görünür'),
                value: _ticketSalesEnabled,
                onChanged: _saving ? null : (v) => setState(() => _ticketSalesEnabled = v),
              ),
              _txt(_orgCtrl, 'Organizatör'),
              _dateField(_dateCtrl, 'Etkinlik Tarihi'),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Kaydediliyor...' : 'Değişiklikleri Kaydet'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _txt(TextEditingController c, String label, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF111827),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  String _normalizeKind(String raw) {
    final v = raw.trim().toLowerCase();
    if (v == 'festival' || v == 'competition' || v == 'dance_night') return v;
    return 'dance_night';
  }

  Future<void> _pickDate(TextEditingController ctrl) async {
    final initial = _parseEventDate(ctrl.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    ctrl.text = _toDisplayDate(date.toIso8601String());
  }

  Widget _dateField(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickDate(c),
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
  final _venueCtrl = TextEditingController();
  final _orgCtrl = TextEditingController();
  final _dateCtrl = TextEditingController();
  final _feeCtrl = TextEditingController(text: '0');
  final List<String> _cities = kTurkiyeCities;
  String _city = 'İstanbul';
  String _eventKind = 'dance_night';
  bool _ticketSalesEnabled = true;

  final _picker = ImagePicker();
  XFile? _image;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _eventCtrl.dispose();
    _descCtrl.dispose();
    _programCtrl.dispose();
    _venueCtrl.dispose();
    _orgCtrl.dispose();
    _dateCtrl.dispose();
    _feeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDate(TextEditingController ctrl) async {
    final initial = _parseEventDate(ctrl.text) ?? DateTime.now();
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: initial,
    );
    if (date == null || !mounted) return;
    ctrl.text = _toDisplayDate(date.toIso8601String());
  }

  Future<void> _submit() async {
    if (_eventCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Etkinlik adı zorunlu.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final req = http.MultipartRequest('POST', Uri.parse(_submitUrl))
        ..fields['event_name'] = _eventCtrl.text.trim()
        ..fields['description'] = _descCtrl.text.trim()
        ..fields['program_text'] = _programCtrl.text.trim()
        ..fields['venue'] = _venueCtrl.text.trim()
        ..fields['city'] = _city
        ..fields['event_kind'] = _eventKind
        ..fields['ticket_sales_enabled'] = _ticketSalesEnabled ? '1' : '0'
        ..fields['organizer_name'] = _orgCtrl.text.trim()
        ..fields['event_date'] = _toApiDate(_dateCtrl.text.trim())
        ..fields['entry_fee'] = _feeCtrl.text.trim();
      final token = widget.sessionToken.trim();
      if (token.isNotEmpty) req.headers['Authorization'] = 'Bearer $token';
      if (_image != null) {
        req.files.add(await http.MultipartFile.fromPath('cover_image', _image!.path));
      }
      final streamed = await req.send();
      final body = await streamed.stream.bytesToString();
      if (streamed.statusCode != 200) {
        setState(() => _error = 'Gönderim başarısız: ${streamed.statusCode} $body');
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
              _txt(_venueCtrl, 'Konum / Mekan'),
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
                ],
                onChanged: _sending ? null : (v) => setState(() => _eventKind = v ?? _eventKind),
                decoration: InputDecoration(
                  labelText: 'Etkinlik Türü',
                  filled: true,
                  fillColor: const Color(0xFF111827),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 4),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Bilet Satışına Aç'),
                subtitle: const Text('Kapalıysa etkinlik sadece uygulamada görünür'),
                value: _ticketSalesEnabled,
                onChanged: _sending ? null : (v) => setState(() => _ticketSalesEnabled = v),
              ),
              _txt(_orgCtrl, 'Organizatör'),
              _dateField(_dateCtrl, 'Etkinlik Tarihi'),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _txt(TextEditingController c, String label, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF111827),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _dateField(TextEditingController c, String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        readOnly: true,
        onTap: () => _pickDate(c),
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
