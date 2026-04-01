import 'dart:async';
import 'dart:convert';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/featured_events_api.dart';
import '../services/i18n.dart';
import '../services/turkiye_cities.dart';
import '../theme/app_theme.dart';
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

Alignment _coverAlignment(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'top':
      return Alignment.topCenter;
    case 'bottom':
      return Alignment.bottomCenter;
    default:
      return Alignment.center;
  }
}

class DiscoverScreen extends StatefulWidget {
  final String sessionToken;
  final bool canAddToFeed;

  const DiscoverScreen({
    super.key,
    required this.sessionToken,
    required this.canAddToFeed,
  });

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  static const List<String> _eventKinds = ['dance_night', 'festival', 'competition', 'promo_lesson'];
  static const List<String> _danceStyles = ['salsa', 'bachata', 'kizomba', 'tango', 'lindy_hop', 'hip_hop'];

  late Future<List<_EventItem>> _eventsFuture;
  late Future<List<_NewsItem>> _newsFuture;
  late Future<List<_EventItem>> _featuredEventsFuture;
  int _tabIndex = 1;
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
    _featuredEventsFuture = _fetchFeaturedEvents();
  }

  Future<List<_EventItem>> _fetchFeaturedEvents() async {
    final items = await FeaturedEventsApi.fetchCurrent();
    return items.map(_EventItem.fromFeatured).toList();
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
    final featured = _fetchFeaturedEvents();
    setState(() {
      _eventsFuture = f;
      _featuredEventsFuture = featured;
    });
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

  Future<String?> _pickSingleOptionSheet({
    required String title,
    required List<MapEntry<String, String>> options,
    required String currentValue,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: false,
      backgroundColor: AppTheme.surfaceSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.62,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.borderStrong,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    itemCount: options.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final option = options[index];
                      final selected = option.key == currentValue;
                      return Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => Navigator.of(context).pop(option.key),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                            decoration: BoxDecoration(
                              color: selected ? AppTheme.surfaceElevated : AppTheme.surfacePrimary,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: selected ? AppTheme.orange.withOpacity(0.45) : AppTheme.borderSoft,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    option.value,
                                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                          fontWeight: FontWeight.w500,
                                        ),
                                  ),
                                ),
                                if (selected)
                                  const Icon(Icons.check_rounded, color: AppTheme.orange, size: 18),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openEventFilters() async {
    var tempCity = _selectedEventCity;
    var tempKind = _selectedEventKind;
    final tempDanceStyles = <String>{..._selectedDanceStyles};
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surfaceSecondary,
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
                          Expanded(
                            child: Text(
                              'Etkinlikleri Filtrele',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: Text(t('cancel')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () async {
                          final choice = await _pickSingleOptionSheet(
                            title: t('city_filter'),
                            currentValue: tempCity,
                            options: <MapEntry<String, String>>[
                              MapEntry('', t('all_cities')),
                              ...kTurkiyeCitiesWithUnknown.map((city) => MapEntry(city, city)),
                            ],
                          );
                          if (choice == null) return;
                          setSheetState(() => tempCity = choice);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceElevated,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppTheme.borderSoft),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t('city_filter'),
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: AppTheme.textSecondary,
                                            fontSize: 11,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      tempCity.isEmpty ? t('all_cities') : tempCity,
                                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textSecondary),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () async {
                          final choice = await _pickSingleOptionSheet(
                            title: t('event_type'),
                            currentValue: tempKind,
                            options: <MapEntry<String, String>>[
                              MapEntry('', t('all_event_types')),
                              ..._eventKinds.map((kind) => MapEntry(kind, _kindLabel(kind))),
                            ],
                          );
                          if (choice == null) return;
                          setSheetState(() => tempKind = choice);
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                          decoration: BoxDecoration(
                            color: AppTheme.surfaceElevated,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: AppTheme.borderSoft),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      t('event_type'),
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: AppTheme.textSecondary,
                                            fontSize: 11,
                                          ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      tempKind.isEmpty ? t('all_event_types') : _kindLabel(tempKind),
                                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.keyboard_arrow_down_rounded, color: AppTheme.textSecondary),
                            ],
                          ),
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
                                selectedColor: AppTheme.violet.withOpacity(0.28),
                                checkmarkColor: AppTheme.textPrimary,
                                backgroundColor: AppTheme.surfaceElevated,
                                labelStyle: TextStyle(
                                  color: tempDanceStyles.contains(style)
                                      ? AppTheme.textPrimary
                                      : AppTheme.textSecondary,
                                  fontWeight: FontWeight.w600,
                                ),
                                side: BorderSide(
                                  color: tempDanceStyles.contains(style)
                                      ? Colors.transparent
                                      : AppTheme.borderSoft,
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

  void _openEventDetail(_EventItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => EventDetailScreen(
          title: item.name,
          submissionId: item.id,
          cover: item.cover,
          description: item.description,
          eventDate: item.eventDate,
          endAt: item.endAt,
          venue: item.venue,
          venueMapUrl: item.venueMapUrl,
          organizer: item.organizer,
          program: item.program,
          entryFee: item.entryFee,
          ticketUrl: item.ticketUrl,
          wooProductId: item.wooProductId,
          ticketSalesEnabled: item.ticketSalesEnabled,
          sessionToken: widget.sessionToken,
          canAddToFeed: widget.canAddToFeed,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return ScreenShell(
      title: '',
      icon: Icons.local_activity,
      subtitle: '',
      showHeader: false,
      tone: _tabIndex == 0 ? AppTone.discover : AppTone.events,
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
        if (_tabIndex != 0)
          FutureBuilder<List<_EventItem>>(
            future: _featuredEventsFuture,
            builder: (context, snapshot) {
              final items = snapshot.data ?? const <_EventItem>[];
              if (snapshot.connectionState == ConnectionState.waiting && items.isEmpty) {
                return const SizedBox.shrink();
              }
              if (items.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _FeaturedEventsCarousel(
                  items: items,
                  onTap: _openEventDetail,
                ),
              );
            },
          ),
        if (_tabIndex != 0)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(14),
            decoration: AppTheme.panel(tone: AppTone.events, radius: 20),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _openEventFilters,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.orange,
                  foregroundColor: AppTheme.textPrimary,
                ),
                icon: const Icon(Icons.filter_alt_outlined, size: 18),
                label: Text(
                  _activeEventFilterCount > 0 ? '${t('filter')} ($_activeEventFilterCount)' : t('filter'),
                ),
              ),
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
                          canAddToFeed: widget.canAddToFeed,
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
                  onTap: () => _openEventDetail(items[i]),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _tabChip(int index, String label) {
    final selected = _tabIndex == index;
    final tone = index == 0 ? AppTone.discover : AppTone.events;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        setState(() => _tabIndex = index);
        _refresh();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: selected
              ? LinearGradient(
                  colors: [AppTheme.tonePrimary(tone), AppTheme.toneSecondary(tone)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: selected ? null : AppTheme.surfaceSecondary,
          border: Border.all(
            color: selected ? Colors.transparent : AppTheme.borderSoft,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: AppTheme.tonePrimary(tone).withOpacity(0.18),
                    blurRadius: 18,
                    offset: const Offset(0, 10),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
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
  final String endAt;
  final String venue;
  final String venueMapUrl;
  final String organizer;
  final String program;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;
  final String city;
  final String eventKind;
  final String coverCrop;
  final bool ticketSalesEnabled;

  const _EventItem({
    required this.id,
    required this.name,
    required this.description,
    required this.cover,
    required this.eventDate,
    required this.endAt,
    required this.venue,
    required this.venueMapUrl,
    required this.organizer,
    required this.program,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
    required this.city,
    required this.eventKind,
    required this.coverCrop,
    required this.ticketSalesEnabled,
  });

  DateTime get sortKey {
    final parsed = DateTime.tryParse(eventDate.trim().replaceAll(' ', 'T'));
    final dt = parsed == null ? null : (parsed.isUtc ? parsed.toLocal() : parsed);
    if (dt == null) return DateTime.utc(9999, 1, 1);
    final now = DateTime.now();
    final eventDay = DateTime(dt.year, dt.month, dt.day);
    final today = DateTime(now.year, now.month, now.day);
    if (eventDay.isBefore(today)) {
      return DateTime.utc(9999, 1, 1).add(today.difference(eventDay));
    }
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
      endAt: (json['end_at'] ?? '').toString(),
      venue: (json['venue'] ?? '').toString(),
      venueMapUrl: (json['venue_map_url'] ?? '').toString(),
      organizer: (json['organizer_name'] ?? '').toString(),
      program: (json['program_text'] ?? '').toString(),
      entryFee: (json['entry_fee'] as num?)?.toDouble() ?? 0.0,
      ticketUrl: absUrl(json['ticket_url'] ?? '', host: 'https://www.dansmagazin.net'),
      wooProductId: (json['woo_product_id'] ?? '').toString(),
      city: (json['city'] ?? '').toString(),
      eventKind: (json['event_kind'] ?? '').toString(),
      coverCrop: (json['cover_crop'] ?? 'center').toString(),
      ticketSalesEnabled: (json['ticket_sales_enabled'] == true) || (json['ticket_sales_enabled'] == 1),
    );
  }

  factory _EventItem.fromFeatured(FeaturedEventItem item) {
    return _EventItem(
      id: item.id,
      name: item.name,
      description: item.description,
      cover: item.cover,
      eventDate: item.eventDate,
      endAt: item.endAt,
      venue: item.venue,
      venueMapUrl: item.venueMapUrl,
      organizer: item.organizerName,
      program: item.programText,
      entryFee: item.entryFee,
      ticketUrl: item.ticketUrl,
      wooProductId: item.wooProductId,
      city: item.city,
      eventKind: item.eventKind,
      coverCrop: item.coverCrop,
      ticketSalesEnabled: item.ticketSalesEnabled,
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
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 116,
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.panel(tone: AppTone.events, radius: 22, elevated: true),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 96,
                height: 96,
                child: item.cover.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.cover,
                        fit: BoxFit.cover,
                        alignment: _coverAlignment(item.coverCrop),
                        fadeInDuration: Duration.zero,
                        placeholderFadeInDuration: Duration.zero,
                        errorWidget: (_, __, ___) => Container(color: AppTheme.surfaceElevated),
                        placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
                      )
                    : Container(color: AppTheme.surfaceElevated),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: AppTheme.orange.withOpacity(0.16),
                    ),
                    child: Text(
                      item.city.trim().isNotEmpty ? item.city.trim() : 'Etkinlik',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppTheme.orange,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 16),
                  ),
                  Text(
                    _formatEventDate(item.eventDate),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
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
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 116,
        padding: const EdgeInsets.all(10),
        decoration: AppTheme.panel(tone: AppTone.discover, radius: 22, elevated: true),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: SizedBox(
                width: 96,
                height: 96,
                child: item.image.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: item.image,
                        fit: BoxFit.cover,
                        fadeInDuration: Duration.zero,
                        placeholderFadeInDuration: Duration.zero,
                        errorWidget: (_, __, ___) => Container(color: AppTheme.surfaceElevated),
                        placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
                      )
                    : Container(color: AppTheme.surfaceElevated),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(fontSize: 16),
                  ),
                  Text(
                    _formatEventDate(item.date),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
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
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.panel(tone: AppTone.neutral, radius: 18, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w600)),
          if (actionText != null && onTap != null)
            TextButton(onPressed: onTap, child: Text(actionText!)),
        ],
      ),
    );
  }
}

class _FeaturedEventsCarousel extends StatefulWidget {
  final List<_EventItem> items;
  final ValueChanged<_EventItem> onTap;

  const _FeaturedEventsCarousel({
    required this.items,
    required this.onTap,
  });

  @override
  State<_FeaturedEventsCarousel> createState() => _FeaturedEventsCarouselState();
}

class _FeaturedEventsCarouselState extends State<_FeaturedEventsCarousel> {
  late final PageController _controller;
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = PageController(viewportFraction: 0.94);
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant _FeaturedEventsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length) {
      if (_index >= widget.items.length) _index = 0;
      _syncTimer();
    }
  }

  void _syncTimer() {
    _timer?.cancel();
    if (widget.items.length <= 1) return;
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || !_controller.hasClients || widget.items.isEmpty) return;
      final next = (_index + 1) % widget.items.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
      setState(() => _index = next);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 172,
          child: PageView.builder(
            controller: _controller,
            itemCount: widget.items.length,
            onPageChanged: (value) => setState(() => _index = value),
            itemBuilder: (context, index) => Padding(
              padding: EdgeInsets.only(right: index == widget.items.length - 1 ? 0 : 8),
              child: _FeaturedEventBanner(
                item: widget.items[index],
                onTap: () => widget.onTap(widget.items[index]),
              ),
            ),
          ),
        ),
        if (widget.items.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(
              widget.items.length,
              (index) => AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: index == _index ? 20 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: index == _index ? AppTheme.orange : AppTheme.borderStrong,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _FeaturedEventBanner extends StatelessWidget {
  final _EventItem item;
  final VoidCallback onTap;

  const _FeaturedEventBanner({
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        decoration: AppTheme.panel(tone: AppTone.events, radius: 24, elevated: true),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: item.cover.isNotEmpty
                  ? CachedNetworkImage(
                      imageUrl: item.cover,
                      fit: BoxFit.cover,
                      alignment: _coverAlignment(item.coverCrop),
                      placeholder: (_, __) => const SizedBox.shrink(),
                      errorWidget: (_, __, ___) => DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppTheme.surfacePrimary,
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              AppTheme.surfaceElevated,
                              AppTheme.surfacePrimary,
                            ],
                          ),
                        ),
                      ),
                    )
                  : DecoratedBox(
                      decoration: BoxDecoration(
                        color: AppTheme.surfacePrimary,
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            AppTheme.surfaceElevated,
                            AppTheme.surfacePrimary,
                          ],
                        ),
                      ),
                    ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.12),
                    Colors.black.withOpacity(0.28),
                    Colors.black.withOpacity(0.68),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.orange.withOpacity(0.16),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: AppTheme.orange.withOpacity(0.28)),
                    ),
                    child: const Text(
                      'Öne Çıkan',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontSize: 18),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${item.city} · ${_formatEventDate(item.eventDate)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontSize: 11,
                          color: AppTheme.textPrimary.withOpacity(0.86),
                        ),
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
