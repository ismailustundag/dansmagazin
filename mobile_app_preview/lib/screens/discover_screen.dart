import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'event_detail_screen.dart';
import 'news_detail_screen.dart';
import 'screen_shell.dart';

String _formatEventDate(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return '';
  final dmy = RegExp(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$').firstMatch(v);
  if (dmy != null) return v;
  final dt = DateTime.tryParse(v) ?? DateTime.tryParse(v.replaceAll(' ', 'T'));
  if (dt == null) return v;
  final d = dt.day.toString().padLeft(2, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final y = dt.year.toString();
  return '$d.$m.$y';
}

String _normTr(String raw) {
  return raw
      .trim()
      .toLowerCase()
      .replaceAll('ı', 'i')
      .replaceAll('İ', 'i')
      .replaceAll('I', 'i')
      .replaceAll('ş', 's')
      .replaceAll('Ş', 's')
      .replaceAll('ğ', 'g')
      .replaceAll('Ğ', 'g')
      .replaceAll('ü', 'u')
      .replaceAll('Ü', 'u')
      .replaceAll('ö', 'o')
      .replaceAll('Ö', 'o')
      .replaceAll('ç', 'c')
      .replaceAll('Ç', 'c');
}

class DiscoverScreen extends StatefulWidget {
  final String sessionToken;

  const DiscoverScreen({super.key, required this.sessionToken});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  static const List<String> _tabs = ['all', 'dance_night', 'festival', 'competition', 'promo_lesson'];

  late Future<List<_EventItem>> _eventsFuture;
  late Future<List<_NewsItem>> _newsFuture;
  int _tabIndex = 0;
  String _selectedCity = 'Tümü';

  @override
  void initState() {
    super.initState();
    _eventsFuture = _fetchEvents();
    _newsFuture = _fetchNews();
  }

  Future<List<_EventItem>> _fetchEvents() async {
    final kind = _tabs[_tabIndex];
    final city = _selectedCity == 'Tümü' ? '' : _selectedCity;
    final qp = <String, String>{'limit': '300'};
    if (kind != 'all') qp['event_kind'] = kind;
    // Sehir filtresini client-side yapiyoruz; Turkce karakter/kollasyon farklarinda
    // backend tarafinda esitlik kacabiliyor.
    final uri = Uri.parse('$_base/events').replace(queryParameters: qp);
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      throw Exception('Etkinlikler alınamadı (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    var rows = (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_EventItem.fromJson)
        .toList();
    if (kind != 'all') {
      rows = rows.where((e) => e.eventKind.trim().toLowerCase() == kind).toList();
    }
    if (city.isNotEmpty) {
      final cityN = _normTr(city);
      rows = rows.where((e) => _normTr(e.city) == cityN).toList();
    }
    rows.sort((a, b) => a.sortKey.compareTo(b.sortKey));
    return rows;
  }

  Future<List<_NewsItem>> _fetchNews() async {
    final uri = Uri.parse('$_base/discover').replace(
      queryParameters: const {
        'news_limit': '60',
        'events_limit': '1',
        'albums_limit': '1',
      },
    );
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      throw Exception('Haberler alınamadı (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final rows = (body['news'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_NewsItem.fromJson)
        .toList();
    rows.sort((a, b) => b.sortKey.compareTo(a.sortKey));
    return rows;
  }

  Future<void> _refresh() async {
    if (_tabIndex == 0) {
      final f = _fetchNews();
      setState(() => _newsFuture = f);
      await f;
      return;
    }
    final f = _fetchEvents();
    setState(() => _eventsFuture = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return ScreenShell(
      title: 'Etkinlik Akışı',
      icon: Icons.local_activity,
      subtitle: '',
      onRefresh: _refresh,
      content: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _tabChip(0, 'Haberler'),
              const SizedBox(width: 8),
              _tabChip(1, 'Dans Geceleri'),
              const SizedBox(width: 8),
              _tabChip(2, 'Festivaller'),
              const SizedBox(width: 8),
              _tabChip(3, 'Yarışmalar'),
              const SizedBox(width: 8),
              _tabChip(4, 'Tanıtım Dersleri'),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (_tabIndex != 0)
          FutureBuilder<List<_EventItem>>(
            future: _eventsFuture,
            builder: (context, snapshot) {
              final data = snapshot.data ?? const <_EventItem>[];
              final cities = <String>{'Tümü'};
              for (final e in data) {
                if (e.city.trim().isNotEmpty) cities.add(e.city.trim());
              }
              return DropdownButtonFormField<String>(
                value: cities.contains(_selectedCity) ? _selectedCity : 'Tümü',
                items: cities.map((c) => DropdownMenuItem(value: c, child: Text('Şehir: $c'))).toList(),
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _selectedCity = v);
                  _refresh();
                },
                decoration: InputDecoration(
                  filled: true,
                  fillColor: const Color(0xFF111827),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              );
            },
          ),
        const SizedBox(height: 12),
        if (_tabIndex == 0)
          FutureBuilder<List<_NewsItem>>(
            future: _newsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _InfoCard(
                  text: 'Haberler yüklenemedi, tekrar deneyin.',
                  actionText: 'Yenile',
                  onTap: _refresh,
                );
              }
              final items = snapshot.data ?? const <_NewsItem>[];
              if (items.isEmpty) {
                return const _InfoCard(text: 'Henüz haber bulunamadı.');
              }
              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (_, i) => _NewsCard(
                  item: items[i],
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => NewsDetailScreen(
                          postId: items[i].id,
                          sessionToken: widget.sessionToken,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          )
        else
          FutureBuilder<List<_EventItem>>(
            future: _eventsFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 30),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              if (snapshot.hasError) {
                return _InfoCard(
                  text: 'Liste yüklenemedi, tekrar deneyin.',
                  actionText: 'Yenile',
                  onTap: _refresh,
                );
              }
              final items = snapshot.data ?? const <_EventItem>[];
              if (items.isEmpty) {
                return const _InfoCard(text: 'Filtreye uygun etkinlik bulunamadı.');
              }
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 0.72,
                ),
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
                          venueMapUrl: items[i].venueMapUrl,
                          organizer: items[i].organizer,
                          program: items[i].program,
                          entryFee: items[i].entryFee,
                          ticketUrl: items[i].ticketUrl,
                          wooProductId: items[i].wooProductId,
                          ticketSalesEnabled: items[i].ticketSalesEnabled,
                          sessionToken: widget.sessionToken,
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _tabChip(int index, String label) {
    final selected = _tabIndex == index;
    return ChoiceChip(
      selected: selected,
      label: Text(label),
      selectedColor: const Color(0xFFE53935),
      backgroundColor: const Color(0xFF121826),
      labelStyle: TextStyle(color: selected ? Colors.white : Colors.white70),
      onSelected: (_) {
        setState(() => _tabIndex = index);
        _refresh();
      },
    );
  }
}

class _EventItem {
  final int id;
  final String name;
  final String description;
  final String cover;
  final String eventDate;
  final String venue;
  final String venueMapUrl;
  final String organizer;
  final String program;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;
  final String city;
  final String eventKind;
  final bool ticketSalesEnabled;

  const _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.eventDate,
    required this.venue,
    required this.venueMapUrl,
    required this.organizer,
    required this.program,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
    required this.city,
    required this.eventKind,
    required this.ticketSalesEnabled,
  });

  DateTime get sortKey {
    final dt = DateTime.tryParse(eventDate.trim().replaceAll(' ', 'T'));
    if (dt == null) return DateTime.utc(9999, 1, 1);
    final now = DateTime.now();
    if (dt.isBefore(now)) return DateTime.utc(9999, 1, 1).add(now.difference(dt));
    return dt;
  }

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
      eventDate: (json['start_at'] ?? json['event_date'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
      venueMapUrl: (json['venue_map_url'] ?? '').toString(),
      organizer: (json['organizer_name'] ?? '').toString(),
      program: (json['program_text'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: absUrl(json['ticket_url'] ?? '', host: 'https://www.dansmagazin.net'),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      eventKind: (json['event_kind'] ?? '').toString(),
      ticketSalesEnabled: (json['ticket_sales_enabled'] == true) || (json['ticket_sales_enabled'] == 1),
    );
  }
}

class _NewsItem {
  final int id;
  final String title;
  final String excerpt;
  final String date;
  final String image;
  final String author;

  const _NewsItem({
    required this.id,
    required this.title,
    required this.excerpt,
    required this.date,
    required this.image,
    required this.author,
  });

  DateTime get sortKey => DateTime.tryParse(date.trim()) ?? DateTime.fromMillisecondsSinceEpoch(0);

  factory _NewsItem.fromJson(Map<String, dynamic> json) {
    return _NewsItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: (json['title'] ?? '').toString(),
      excerpt: (json['excerpt'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      image: (json['image'] ?? '').toString(),
      author: (json['author'] ?? '').toString(),
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
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: item.cover.isNotEmpty
                  ? Image.network(item.cover, width: double.infinity, fit: BoxFit.cover)
                  : Container(color: const Color(0xFF1F2937)),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  if (item.city.trim().isNotEmpty)
                    Text(item.city.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  Text(_formatEventDate(item.eventDate), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewsCard extends StatelessWidget {
  final _NewsItem item;
  final VoidCallback onTap;

  const _NewsCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.image.isNotEmpty)
              Image.network(
                item.image,
                width: double.infinity,
                height: 170,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 170,
                  color: const Color(0xFF1F2937),
                ),
              )
            else
              Container(height: 120, color: const Color(0xFF1F2937)),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  if (item.excerpt.trim().isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      item.excerpt.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '${_formatEventDate(item.date)}${item.author.trim().isNotEmpty ? ' • ${item.author.trim()}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final String text;
  final String? actionText;
  final VoidCallback? onTap;

  const _InfoCard({required this.text, this.actionText, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF121826),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: TextStyle(color: Colors.white.withOpacity(0.85))),
          if (actionText != null && onTap != null)
            TextButton(onPressed: onTap, child: Text(actionText!)),
        ],
      ),
    );
  }
}
