import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'app_webview_screen.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<List<_EventItem>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchEvents();
  }

  Future<List<_EventItem>> _fetchEvents() async {
    final resp = await http.get(Uri.parse('$_base/events'));
    if (resp.statusCode != 200) {
      throw Exception('Etkinlikler alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => _EventItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> _openCreateDialog() async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      builder: (_) => const _CreateEventSheet(),
    );
    if (ok == true) {
      setState(() => _future = _fetchEvents());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B1020), Color(0xFF080B14)],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.event, color: Color(0xFFE53935)),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Etkinlikler',
                      style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Etkinliğini Ekle',
                    onPressed: _openCreateDialog,
                    icon: const Icon(Icons.add_circle, size: 30, color: Color(0xFFE53935)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Onaylanmış etkinlikler listelenir. Sağ üstten etkinlik talebi oluşturabilirsiniz.',
                  style: TextStyle(color: Colors.white.withOpacity(0.75)),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: FutureBuilder<List<_EventItem>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: TextButton(
                        onPressed: () => setState(() => _future = _fetchEvents()),
                        child: const Text('Etkinlikler yüklenemedi, tekrar dene'),
                      ),
                    );
                  }
                  final items = snapshot.data ?? [];
                  if (items.isEmpty) {
                    return const Center(child: Text('Henüz onaylanmış etkinlik yok.'));
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _EventCard(
                      item: items[i],
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => _EventDetailScreen(item: items[i])),
                        );
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventItem {
  final int id;
  final String name;
  final String description;
  final String cover;
  final String startAt;
  final String endAt;
  final double entryFee;
  final String ticketUrl;
  final String venue;
  final String organizerName;
  final String programText;
  final String wooProductId;

  _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.startAt,
    required this.endAt,
    required this.entryFee,
    required this.ticketUrl,
    required this.venue,
    required this.organizerName,
    required this.programText,
    required this.wooProductId,
  });

  factory _EventItem.fromJson(Map<String, dynamic> json) {
    String absUrl(dynamic raw, {String fallbackHost = 'https://api2.dansmagazin.net'}) {
      final v = (raw ?? '').toString().trim();
      if (v.isEmpty) return '';
      if (v.startsWith('http://') || v.startsWith('https://')) return v;
      if (v.startsWith('/')) return '$fallbackHost$v';
      return '$fallbackHost/$v';
    }

    return _EventItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      cover: absUrl(json['cover'] ?? json['cover_url'] ?? json['cover_path'] ?? json['image'] ?? json['image_url']),
      startAt: (json['start_at'] ?? '').toString(),
      endAt: (json['end_at'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: absUrl(
        json['ticket_url'] ?? json['ticketUrl'] ?? json['link'] ?? json['url'] ?? json['permalink'],
        fallbackHost: 'https://www.dansmagazin.net',
      ),
      venue: (json['venue'] ?? '').toString(),
      organizerName: (json['organizer_name'] ?? json['organizer'] ?? '').toString(),
      programText: (json['program_text'] ?? json['program'] ?? '').toString(),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
    );
  }
}

class _EventCard extends StatelessWidget {
  final _EventItem item;
  final VoidCallback? onTap;

  const _EventCard({required this.item, this.onTap});

  String _fmtDate(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '-';
    DateTime? dt = DateTime.tryParse(v) ?? DateTime.tryParse(v.replaceAll(' ', 'T'));
    if (dt == null) return v;
    return '${dt.day.toString().padLeft(2, '0')}.${dt.month.toString().padLeft(2, '0')}.${(dt.year % 100).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.cover.isNotEmpty)
              SizedBox(
                height: 170,
                width: double.infinity,
                child: Image.network(
                  item.cover,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text('${_fmtDate(item.startAt)} - ${_fmtDate(item.endAt)}', style: TextStyle(color: Colors.white.withOpacity(0.82))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EventDetailScreen extends StatefulWidget {
  final _EventItem item;

  const _EventDetailScreen({required this.item});

  @override
  State<_EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<_EventDetailScreen> {
  int _tab = 0;

  String _fmtDate(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return '-';
    DateTime? dt = DateTime.tryParse(v) ?? DateTime.tryParse(v.replaceAll(' ', 'T'));
    if (dt == null) return v;
    final dd = dt.day.toString().padLeft(2, '0');
    final mm = dt.month.toString().padLeft(2, '0');
    final yy = (dt.year % 100).toString().padLeft(2, '0');
    final hh = dt.hour.toString().padLeft(2, '0');
    final mn = dt.minute.toString().padLeft(2, '0');
    return '$dd.$mm.$yy  $hh:$mn';
  }

  String _cartUrl() {
    final item = widget.item;
    final pid = item.wooProductId.trim();
    if (pid.isNotEmpty) {
      return 'https://www.dansmagazin.net/sepet/?add-to-cart=$pid';
    }
    final t = item.ticketUrl.trim();
    if (t.isEmpty) return '';
    final u = Uri.tryParse(t);
    if (u == null) return t;
    final p = u.queryParameters['p'] ?? u.queryParameters['product_id'] ?? u.queryParameters['add-to-cart'];
    if (p != null && p.trim().isNotEmpty) {
      return 'https://www.dansmagazin.net/sepet/?add-to-cart=${p.trim()}';
    }
    return t;
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final buyUrl = _cartUrl();

    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: const Text('Etkinlik Detay'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (item.cover.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.network(
                item.cover,
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
                _line(Icons.calendar_month, '${_fmtDate(item.startAt)} - ${_fmtDate(item.endAt)}'),
                if (item.venue.trim().isNotEmpty) _line(Icons.location_on, item.venue.trim()),
                if (item.organizerName.trim().isNotEmpty) _line(Icons.public, item.organizerName.trim()),
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
                    MaterialPageRoute(builder: (_) => AppWebViewScreen(url: buyUrl, title: item.name)),
                  );
                },
                child: Text(
                  'BILET SATIN AL  ₺${item.entryFee.toStringAsFixed(0)}',
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
              _contentText(item),
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

  String _contentText(_EventItem item) {
    if (_tab == 1) return item.programText.trim().isEmpty ? 'Program bilgisi girilmedi.' : item.programText.trim();
    if (_tab == 2) return item.venue.trim().isEmpty ? 'Konum bilgisi girilmedi.' : item.venue.trim();
    return item.description.trim().isEmpty ? 'Detay bilgisi girilmedi.' : item.description.trim();
  }
}

class _CreateEventSheet extends StatefulWidget {
  const _CreateEventSheet();

  @override
  State<_CreateEventSheet> createState() => _CreateEventSheetState();
}

class _CreateEventSheetState extends State<_CreateEventSheet> {
  static const String _submitUrl = 'https://api2.dansmagazin.net/events/submissions';

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _eventCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _venueCtrl = TextEditingController();
  final _orgCtrl = TextEditingController();
  final _programCtrl = TextEditingController();
  final _startCtrl = TextEditingController();
  final _endCtrl = TextEditingController();
  final _feeCtrl = TextEditingController(text: '0');

  final _picker = ImagePicker();
  XFile? _image;
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _eventCtrl.dispose();
    _descCtrl.dispose();
    _venueCtrl.dispose();
    _orgCtrl.dispose();
    _programCtrl.dispose();
    _startCtrl.dispose();
    _endCtrl.dispose();
    _feeCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime(TextEditingController ctrl) async {
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (time == null) return;
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    ctrl.text = dt.toIso8601String();
  }

  Future<void> _submit() async {
    if (_eventCtrl.text.trim().isEmpty || _nameCtrl.text.trim().isEmpty || _emailCtrl.text.trim().isEmpty) {
      setState(() => _error = 'Ad, e-posta ve etkinlik adı zorunlu.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final req = http.MultipartRequest('POST', Uri.parse(_submitUrl))
        ..fields['submitter_name'] = _nameCtrl.text.trim()
        ..fields['submitter_email'] = _emailCtrl.text.trim()
        ..fields['event_name'] = _eventCtrl.text.trim()
        ..fields['description'] = _descCtrl.text.trim()
        ..fields['venue'] = _venueCtrl.text.trim()
        ..fields['organizer_name'] = _orgCtrl.text.trim()
        ..fields['program_text'] = _programCtrl.text.trim()
        ..fields['start_at'] = _startCtrl.text.trim()
        ..fields['end_at'] = _endCtrl.text.trim()
        ..fields['entry_fee'] = _feeCtrl.text.trim();

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
              const Text('Etkinliğini Ekle', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              _txt(_nameCtrl, 'Ad Soyad'),
              _txt(_emailCtrl, 'E-posta'),
              _txt(_eventCtrl, 'Etkinlik Adı'),
              _txt(_descCtrl, 'Detaylar', maxLines: 3),
              _txt(_programCtrl, 'Program', maxLines: 3),
              _txt(_venueCtrl, 'Konum / Mekan'),
              _txt(_orgCtrl, 'Organizatör'),
              _dateField(_startCtrl, 'Başlangıç Tarih/Saat'),
              _dateField(_endCtrl, 'Bitiş Tarih/Saat'),
              _txt(_feeCtrl, 'Bilet Ücreti (TL)'),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
                      if (x != null) setState(() => _image = x);
                    },
                    icon: const Icon(Icons.image),
                    label: const Text('Kapak Seç'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _image == null ? 'Seçilmedi' : _image!.name,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
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
        onTap: () => _pickDateTime(c),
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
