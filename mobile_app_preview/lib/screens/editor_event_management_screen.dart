import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

class EditorEventManagementScreen extends StatelessWidget {
  final String sessionToken;

  const EditorEventManagementScreen({super.key, required this.sessionToken});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Etkinlik Yönetimi')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ActionCard(
            title: 'Etkinlik Oluştur',
            subtitle: 'Yeni etkinliği onaya gönder.',
            icon: Icons.add_circle_outline,
            onTap: () async {
              await showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                backgroundColor: const Color(0xFF0F172A),
                builder: (_) => _CreateEventSheet(sessionToken: sessionToken),
              );
            },
          ),
          const SizedBox(height: 10),
          _ActionCard(
            title: 'Etkinliği Yönet',
            subtitle: 'Etkinlik detaylarını panelden düzenleyin.',
            icon: Icons.edit_calendar_outlined,
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Etkinlik düzenleme paneli bir sonraki adımda eklenecek.')),
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
      body: RefreshIndicator(
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
                    subtitle: e.venue.isNotEmpty ? e.venue : (e.eventDate.isNotEmpty ? e.eventDate : 'Etkinlik #${e.submissionId}'),
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
  final _qrCtrl = TextEditingController();
  bool _loading = false;
  String _result = '';
  List<Map<String, dynamic>> _used = const [];

  @override
  void initState() {
    super.initState();
    _loadUsed();
  }

  @override
  void dispose() {
    _qrCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final token = _qrCtrl.text.trim();
    if (token.isEmpty) {
      setState(() => _result = 'QR token girin.');
      return;
    }
    setState(() => _loading = true);
    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_base/events/${widget.submissionId}/tickets/scan'))
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['qr_token'] = token;
      final res = await req.send();
      final body = await res.stream.bytesToString();
      final map = jsonDecode(body) as Map<String, dynamic>;
      final msg = (map['message'] ?? map['detail'] ?? 'İşlem tamamlandı').toString();
      setState(() => _result = msg);
      await _loadUsed();
    } catch (e) {
      setState(() => _result = 'Hata: $e');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Bilet Kontrol - ${widget.eventName}')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _qrCtrl,
            decoration: const InputDecoration(labelText: 'QR Token'),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            onPressed: _loading ? null : _scan,
            child: Text(_loading ? 'Kontrol ediliyor...' : 'QR Kontrol Et'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _loading ? null : _loadUsed,
            child: const Text('Kullanılmış Biletleri Yenile'),
          ),
          if (_result.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(_result, style: const TextStyle(fontWeight: FontWeight.w700)),
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
    final date = await showDatePicker(
      context: context,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 3650)),
      initialDate: DateTime.now(),
    );
    if (date == null || !mounted) return;
    ctrl.text = DateTime(date.year, date.month, date.day).toIso8601String();
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
        ..fields['organizer_name'] = _orgCtrl.text.trim()
        ..fields['event_date'] = _dateCtrl.text.trim()
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
              _txt(_orgCtrl, 'Organizatör'),
              _dateField(_dateCtrl, 'Etkinlik Tarihi'),
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
