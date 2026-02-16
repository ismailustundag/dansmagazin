import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';

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
    final items = (body['items'] as List<dynamic>? ?? [])
        .map((e) => _EventItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return items;
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
                    itemBuilder: (_, i) => _EventCard(item: items[i]),
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

  _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.startAt,
    required this.endAt,
    required this.entryFee,
  });

  factory _EventItem.fromJson(Map<String, dynamic> json) {
    return _EventItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      cover: (json['cover'] ?? '').toString(),
      startAt: (json['start_at'] ?? '').toString(),
      endAt: (json['end_at'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
    );
  }
}

class _EventCard extends StatelessWidget {
  final _EventItem item;

  const _EventCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
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
                if (item.description.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    item.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withOpacity(0.8)),
                  ),
                ],
                const SizedBox(height: 8),
                Text('Başlangıç: ${item.startAt.isEmpty ? "-" : item.startAt}'),
                Text('Bitiş: ${item.endAt.isEmpty ? "-" : item.endAt}'),
                Text('Giriş: ${item.entryFee.toStringAsFixed(2)} TL'),
              ],
            ),
          ),
        ],
      ),
    );
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
              _txt(_descCtrl, 'Etkinlik Hakkında', maxLines: 3),
              _dateField(_startCtrl, 'Başlangıç Tarih/Saat'),
              _dateField(_endCtrl, 'Bitiş Tarih/Saat'),
              _txt(_feeCtrl, 'Giriş Ücreti (TL)'),
              const SizedBox(height: 8),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () async {
                      final x = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
                      if (x != null) setState(() => _image = x);
                    },
                    icon: const Icon(Icons.image),
                    label: const Text('Fotoğraf Seç'),
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
