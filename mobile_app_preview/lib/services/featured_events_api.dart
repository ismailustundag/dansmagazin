import 'dart:convert';

import 'package:http/http.dart' as http;

import 'error_message.dart';

class FeaturedEventItem {
  final int id;
  final int slot;
  final String name;
  final String description;
  final String cover;
  final String eventDate;
  final String venue;
  final String venueMapUrl;
  final String organizerName;
  final String programText;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;
  final String city;
  final String eventKind;
  final bool ticketSalesEnabled;

  const FeaturedEventItem({
    required this.id,
    required this.slot,
    required this.name,
    required this.description,
    required this.cover,
    required this.eventDate,
    required this.venue,
    required this.venueMapUrl,
    required this.organizerName,
    required this.programText,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
    required this.city,
    required this.eventKind,
    required this.ticketSalesEnabled,
  });

  static String _absUrl(dynamic raw, {String host = 'https://api2.dansmagazin.net'}) {
    final v = (raw ?? '').toString().trim();
    if (v.isEmpty) return '';
    if (v.startsWith('http://') || v.startsWith('https://')) return v;
    if (v.startsWith('/')) return '$host$v';
    return '$host/$v';
  }

  factory FeaturedEventItem.fromJson(Map<String, dynamic> json) {
    return FeaturedEventItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      slot: (json['slot'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      cover: _absUrl(json['cover'] ?? json['cover_url'] ?? json['image']),
      eventDate: (json['start_at'] ?? json['event_date'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
      venueMapUrl: (json['venue_map_url'] ?? '').toString(),
      organizerName: (json['organizer_name'] ?? '').toString(),
      programText: (json['program_text'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: _absUrl(json['ticket_url'] ?? '', host: 'https://www.dansmagazin.net'),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      eventKind: (json['event_kind'] ?? '').toString(),
      ticketSalesEnabled: (json['ticket_sales_enabled'] == true) || (json['ticket_sales_enabled'] == 1),
    );
  }
}

class FeaturedEventsApi {
  static const _base = 'https://api2.dansmagazin.net';

  static Future<List<FeaturedEventItem>> fetchCurrent() async {
    final resp = await http.get(Uri.parse('$_base/profile/featured-events'));
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Öne çıkan etkinlikler alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(FeaturedEventItem.fromJson)
        .toList();
  }

  static Future<List<FeaturedEventItem>> fetchCandidates({int limit = 200}) async {
    final lim = limit < 1 ? 1 : (limit > 300 ? 300 : limit);
    final resp = await http.get(Uri.parse('$_base/events?limit=$lim'));
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Etkinlikler alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(FeaturedEventItem.fromJson)
        .toList();
  }

  static Future<List<FeaturedEventItem>> saveCurrent(
    String sessionToken, {
    required List<int> eventIds,
  }) async {
    final resp = await http.put(
      Uri.parse('$_base/profile/featured-events/admin'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'event_ids': eventIds}),
    );
    if (resp.statusCode != 200) {
      throw Exception(parseApiErrorBody(resp.body, fallback: 'Öne çıkan etkinlikler kaydedilemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(FeaturedEventItem.fromJson)
        .toList();
  }
}
