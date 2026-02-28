import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

import 'event_detail_screen.dart';

class EventsScreen extends StatefulWidget {
  final String sessionToken;
  final bool canCreateEvent;

  const EventsScreen({
    super.key,
    required this.sessionToken,
    required this.canCreateEvent,
  });

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
    if (resp.statusCode != 200) throw Exception('Etkinlikler alınamadı');
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => _EventItem.fromJson(e as Map<String, dynamic>))
        .toList();
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
                  const Expanded(
                    child: Text(
                      'Etkinlikler',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
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
                  if (items.isEmpty) return const Center(child: Text('Henüz onaylanmış etkinlik yok.'));
                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: items.length,
                    itemBuilder: (_, i) => _EventCard(
                      item: items[i],
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => EventDetailScreen(
                              title: items[i].name,
                              submissionId: items[i].id,
                              cover: items[i].cover,
                              description: items[i].description,
                              eventDate: items[i].eventDate,
                              venue: items[i].venue,
                              organizer: items[i].organizer,
                              program: items[i].program,
                              entryFee: items[i].entryFee,
                              ticketUrl: items[i].ticketUrl,
                              wooProductId: items[i].wooProductId,
                              sessionToken: widget.sessionToken,
                            ),
                          ),
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
  final String eventDate;
  final double entryFee;
  final String ticketUrl;
  final String venue;
  final String organizer;
  final String program;
  final String wooProductId;

  _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.eventDate,
    required this.entryFee,
    required this.ticketUrl,
    required this.venue,
    required this.organizer,
    required this.program,
    required this.wooProductId,
  });

  factory _EventItem.fromJson(Map<String, dynamic> json) {
    String absUrl(dynamic raw, {String host = 'https://api2.dansmagazin.net'}) {
      final v = (raw ?? '').toString().trim();
      if (v.isEmpty) return '';
      if (v.startsWith('http://') || v.startsWith('https://')) return v;
      if (v.startsWith('/')) return '$host$v';
      return '$host/$v';
    }

    return _EventItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      cover: absUrl(json['cover'] ?? json['cover_url'] ?? json['image']),
      eventDate: (json['event_date'] ?? json['start_at'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: absUrl(json['ticket_url'] ?? json['link'] ?? '', host: 'https://www.dansmagazin.net'),
      venue: (json['venue'] ?? '').toString(),
      organizer: (json['organizer_name'] ?? '').toString(),
      program: (json['program_text'] ?? '').toString(),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
    );
  }
}

class _EventCard extends StatelessWidget {
  final _EventItem item;
  final VoidCallback onTap;

  const _EventCard({required this.item, required this.onTap});

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
              child: Text(item.name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
          ],
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
      if (token.isNotEmpty) {
        req.headers['Authorization'] = 'Bearer $token';
      }

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
