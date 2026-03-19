import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/i18n.dart';
import '../services/turkiye_cities.dart';
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

class DiscoverScreen extends StatefulWidget {
  final String sessionToken;

  const DiscoverScreen({super.key, required this.sessionToken});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  static const List<String> _eventKinds = ['dance_night', 'festival', 'competition', 'promo_lesson'];
  static const List<String> _danceStyles = ['salsa', 'bachata', 'kizomba', 'tango', 'lindy_hop', 'hip_hop'];

  late Future<List<_EventItem>> _eventsFuture;
  late Future<List<_NewsItem>> _newsFuture;
  int _tabIndex = 0;
  String _selectedEventCity = '';
  String _selectedEventKind = '';
  final Set<String> _selectedDanceStyles = <String>{};

  @override
  void initState() {
    super.initState();
    _eventsFuture = _fetchEvents(
      city: _selectedEventCity,
      eventKind: _selectedEventKind,
      danceStyles: _selectedDanceStyles.toList(),
    );
    _newsFuture = _fetchNews();
  }

  Future<List<_EventItem>> _fetchEvents({
    String city = '',
    String eventKind = '',
    List<String> danceStyles = const <String>[],
  }) async {
    final params = <String, String>{'limit': '300'};
    if (city.trim().isNotEmpty) params['city'] = city.trim();
    if (eventKind.trim().isNotEmpty) params['event_kind'] = eventKind.trim();
    if (danceStyles.isNotEmpty) params['dance_styles'] = danceStyles.join(',');
    final uri = Uri.parse('$_base/events').replace(queryParameters: params);
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

  void _reloadEvents() {
    _eventsFuture = _fetchEvents(
      city: _selectedEventCity,
      eventKind: _selectedEventKind,
      danceStyles: _selectedDanceStyles.toList(),
    );
  }

  Future<List<_NewsItem>> _fetchNews() async {
    final uri = Uri.parse('$_base/discover').replace(
      queryParameters: const {
        'news_limit': '24',
        'events_limit': '0',
        'albums_limit': '0',
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
    final f = _fetchEvents(
      city: _selectedEventCity,
      eventKind: _selectedEventKind,
      danceStyles: _selectedDanceStyles.toList(),
    );
    setState(() => _eventsFuture = f);
    await f;
  }

  int get _activeEventFilterCount {
    var count = 0;
    if (_selectedEventCity.trim().isNotEmpty) count += 1;
    if (_selectedEventKind.trim().isNotEmpty) count += 1;
    if (_selectedDanceStyles.isNotEmpty) count += 1;
    return count;
  }

  String _kindLabel(String kind) {
    switch (kind) {
      case 'dance_night':
        return I18n.t('discover_dance_nights_tab');
      case 'festival':
        return I18n.t('discover_festivals_tab');
      case 'competition':
        return I18n.t('discover_competitions_tab');
      case 'promo_lesson':
        return I18n.t('discover_promo_lessons_tab');
      default:
        return I18n.t('all');
    }
  }

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

  Future<void> _openEventFilters() async {
    var tempCity = _selectedEventCity;
    var tempKind = _selectedEventKind;
    final tempDanceStyles = <String>{..._selectedDanceStyles};
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (context) {
        final t = I18n.t;
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Etkinlikleri Filtrele',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(t('cancel')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<String>(
                        value: tempCity,
                        items: <DropdownMenuItem<String>>[
                          DropdownMenuItem(value: '', child: Text(t('all_cities'))),
                          ...kTurkiyeCitiesWithUnknown
                              .map((city) => DropdownMenuItem<String>(value: city, child: Text(city))),
                        ],
                        onChanged: (value) => setSheetState(() => tempCity = value ?? ''),
                        decoration: InputDecoration(
                          labelText: t('city_filter'),
                          filled: true,
                          fillColor: const Color(0xFF111827),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        value: tempKind,
                        items: <DropdownMenuItem<String>>[
                          DropdownMenuItem(value: '', child: Text(t('all_event_types'))),
                          ..._eventKinds.map(
                            (kind) => DropdownMenuItem<String>(
                              value: kind,
                              child: Text(_kindLabel(kind)),
                            ),
                          ),
                        ],
                        onChanged: (value) => setSheetState(() => tempKind = value ?? ''),
                        decoration: InputDecoration(
                          labelText: t('event_type'),
                          filled: true,
                          fillColor: const Color(0xFF111827),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        t('dance_styles_filter'),
                        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _danceStyles
                            .map(
                              (style) => FilterChip(
                                label: Text(_danceStyleLabel(style)),
                                selected: tempDanceStyles.contains(style),
                                selectedColor: const Color(0xFFE58B8B),
                                checkmarkColor: Colors.white,
                                backgroundColor: const Color(0xFF111827),
                                labelStyle: TextStyle(
                                  color: tempDanceStyles.contains(style) ? Colors.white : Colors.white70,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: BorderSide(
                                  color: tempDanceStyles.contains(style)
                                      ? const Color(0x00FFFFFF)
                                      : Colors.white12,
                                ),
                                onSelected: (_) {
                                  setSheetState(() {
                                    if (tempDanceStyles.contains(style)) {
                                      tempDanceStyles.remove(style);
                                    } else {
                                      tempDanceStyles.add(style);
                                    }
                                  });
                                },
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => setSheetState(() {
                                tempCity = '';
                                tempKind = '';
                                tempDanceStyles.clear();
                              }),
                              child: Text(t('clear_filters')),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: () {
                                Navigator.of(context).pop(<String, dynamic>{
                                  'city': tempCity,
                                  'kind': tempKind,
                                  'styles': tempDanceStyles.toList(),
                                });
                              },
                              icon: const Icon(Icons.filter_alt_outlined),
                              label: Text(t('apply_filters')),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );

    if (!mounted || result == null) return;
    setState(() {
      _selectedEventCity = (result['city'] ?? '').toString();
      _selectedEventKind = (result['kind'] ?? '').toString();
      _selectedDanceStyles
        ..clear()
        ..addAll(
          (result['styles'] as List<dynamic>? ?? const <dynamic>[])
              .map((e) => e.toString())
              .where((e) => _danceStyles.contains(e)),
        );
      _reloadEvents();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return ScreenShell(
      title: t('discover_title'),
      icon: Icons.local_activity,
      subtitle: '',
      onRefresh: _refresh,
      content: [
        Row(
          children: [
            Expanded(child: _tabChip(0, t('news'))),
            const SizedBox(width: 10),
            Expanded(child: _tabChip(1, t('events'))),
          ],
        ),
        const SizedBox(height: 14),
        if (_tabIndex == 0)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            alignment: Alignment.centerLeft,
            child: Text(
              t('news'),
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          )
        else
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    t('events'),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: _openEventFilters,
                  icon: const Icon(Icons.filter_alt_outlined, size: 18),
                  label: Text(
                    _activeEventFilterCount > 0 ? '${t('filter')} ($_activeEventFilterCount)' : t('filter'),
                  ),
                ),
              ],
            ),
          ),
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
                  text: t('news_load_error'),
                  actionText: t('retry'),
                  onTap: _refresh,
                );
              }
              final items = snapshot.data ?? const <_NewsItem>[];
              if (items.isEmpty) {
                return _InfoCard(text: t('no_news_found'));
              }
              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
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
                  text: t('list_load_error'),
                  actionText: t('retry'),
                  onTap: _refresh,
                );
              }
              final items = snapshot.data ?? const <_EventItem>[];
              if (items.isEmpty) {
                return _InfoCard(text: t('no_filtered_events_found'));
              }
              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
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
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        setState(() => _tabIndex = index);
        _refresh();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: selected
              ? const LinearGradient(
                  colors: [Color(0xFFE58B8B), Color(0xFFB45F13)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: selected ? null : const Color(0xFF121826),
          border: Border.all(
            color: selected ? const Color(0x00FFFFFF) : Colors.white12,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? Colors.white : Colors.white70,
            fontWeight: FontWeight.w700,
          ),
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
        height: 108,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 92,
                height: 92,
                child: item.cover.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.cover,
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        placeholderFadeInDuration: Duration.zero,
                        errorWidget: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                        placeholder: (_, __) => Container(color: const Color(0xFF111827)),
                      )
                    : Container(color: const Color(0xFF1F2937)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 6),
                  if (item.city.trim().isNotEmpty)
                    Text(
                      item.city.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  Text(
                    _formatEventDate(item.eventDate),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
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
        height: 108,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: const Color(0xFF121826),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white12),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 92,
                height: 92,
                child: item.image.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.image,
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        placeholderFadeInDuration: Duration.zero,
                        errorWidget: (_, __, ___) => Container(color: const Color(0xFF1F2937)),
                        placeholder: (_, __) => Container(color: const Color(0xFF111827)),
                      )
                    : Container(color: const Color(0xFF1F2937)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
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
