import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'event_detail_screen.dart';
import 'screen_shell.dart';

class DiscoverScreen extends StatefulWidget {
  final String sessionToken;

  const DiscoverScreen({super.key, required this.sessionToken});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  static const List<String> _tabs = ['all', 'dance_night', 'festival'];

  late Future<List<_EventItem>> _future;
  int _tabIndex = 0;
  String _selectedCity = 'Tümü';

  @override
  void initState() {
    super.initState();
    _future = _fetchEvents();
  }

  Future<List<_EventItem>> _fetchEvents() async {
    final kind = _tabs[_tabIndex];
    final city = _selectedCity == 'Tümü' ? '' : _selectedCity;
    final qp = <String, String>{'limit': '300'};
    if (kind != 'all') qp['event_kind'] = kind;
    if (city.isNotEmpty) qp['city'] = city;
    final uri = Uri.parse('$_base/events').replace(queryParameters: qp);
    final resp = await http.get(uri);
    if (resp.statusCode != 200) {
      throw Exception('Etkinlikler alınamadı (${resp.statusCode})');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final rows = (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_EventItem.fromJson)
        .toList();
    rows.sort((a, b) => a.sortKey.compareTo(b.sortKey));
    return rows;
  }

  Future<void> _refresh() async {
    final f = _fetchEvents();
    setState(() => _future = f);
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
            ],
          ),
        ),
        const SizedBox(height: 10),
        FutureBuilder<List<_EventItem>>(
          future: _future,
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
        FutureBuilder<List<_EventItem>>(
          future: _future,
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
  final String organizer;
  final String program;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;
  final String city;
  final bool ticketSalesEnabled;

  const _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.eventDate,
    required this.venue,
    required this.organizer,
    required this.program,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
    required this.city,
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
      eventDate: (json['event_date'] ?? json['start_at'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
      organizer: (json['organizer_name'] ?? '').toString(),
      program: (json['program_text'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: absUrl(json['ticket_url'] ?? '', host: 'https://www.dansmagazin.net'),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      ticketSalesEnabled: (json['ticket_sales_enabled'] == true) || (json['ticket_sales_enabled'] == 1),
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
                  Text(item.eventDate.trim(), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 12)),
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
