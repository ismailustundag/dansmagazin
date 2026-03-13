import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/i18n.dart';
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
    final resp = await http.get(Uri.parse('$_base/events?limit=300'));
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
                  Expanded(
                    child: Text(
                      I18n.t('events'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
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
                        child: Text(I18n.t('events_load_error')),
                      ),
                    );
                  }
                  final items = snapshot.data ?? [];
                  if (items.isEmpty) {
                    return Center(
                      child: Text(I18n.t('no_approved_events')),
                    );
                  }
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
  final String venueMapUrl;
  final String organizer;
  final String program;
  final String wooProductId;
  final String city;
  final String eventKind;
  final bool ticketSalesEnabled;

  _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.eventDate,
    required this.entryFee,
    required this.ticketUrl,
    required this.venue,
    required this.venueMapUrl,
    required this.organizer,
    required this.program,
    required this.wooProductId,
    required this.city,
    required this.eventKind,
    required this.ticketSalesEnabled,
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
      eventDate: (json['start_at'] ?? json['event_date'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: absUrl(json['ticket_url'] ?? json['link'] ?? '', host: 'https://www.dansmagazin.net'),
      venue: (json['venue'] ?? '').toString(),
      venueMapUrl: (json['venue_map_url'] ?? '').toString(),
      organizer: (json['organizer_name'] ?? '').toString(),
      program: (json['program_text'] ?? '').toString(),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      eventKind: (json['event_kind'] ?? '').toString(),
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
                height: 150,
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
                  Text(item.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      if (item.city.trim().isNotEmpty)
                        Text(item.city.trim(), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                    ],
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
