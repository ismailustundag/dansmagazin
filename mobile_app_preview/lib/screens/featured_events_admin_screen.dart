import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/featured_events_api.dart';
import '../theme/app_theme.dart';

String _formatFeaturedDate(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return '';
  final dt = DateTime.tryParse(value) ?? DateTime.tryParse(value.replaceAll(' ', 'T'));
  if (dt == null) return value;
  final d = dt.day.toString().padLeft(2, '0');
  final m = dt.month.toString().padLeft(2, '0');
  final y = dt.year.toString();
  return '$d.$m.$y';
}

class FeaturedEventsAdminScreen extends StatefulWidget {
  final String sessionToken;

  const FeaturedEventsAdminScreen({
    super.key,
    required this.sessionToken,
  });

  @override
  State<FeaturedEventsAdminScreen> createState() => _FeaturedEventsAdminScreenState();
}

class _FeaturedEventsAdminScreenState extends State<FeaturedEventsAdminScreen> {
  bool _loading = true;
  bool _saving = false;
  String _error = '';
  List<FeaturedEventItem> _current = const <FeaturedEventItem>[];
  List<FeaturedEventItem> _candidates = const <FeaturedEventItem>[];
  final List<int> _selectedIds = <int>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final results = await Future.wait([
        FeaturedEventsApi.fetchCurrent(),
        FeaturedEventsApi.fetchCandidates(limit: 180),
      ]);
      final current = results[0] as List<FeaturedEventItem>;
      final candidates = results[1] as List<FeaturedEventItem>;
      if (!mounted) return;
      setState(() {
        _current = current;
        _candidates = candidates;
        _selectedIds
          ..clear()
          ..addAll(current.map((e) => e.id));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleSelection(FeaturedEventItem item) {
    if (_saving) return;
    setState(() {
      if (_selectedIds.contains(item.id)) {
        _selectedIds.remove(item.id);
      } else if (_selectedIds.length < 3) {
        _selectedIds.add(item.id);
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      final saved = await FeaturedEventsApi.saveCurrent(
        widget.sessionToken,
        eventIds: List<int>.from(_selectedIds),
      );
      if (!mounted) return;
      setState(() => _current = saved);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Öne çıkan etkinlikler güncellendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  FeaturedEventItem? _selectedItemAt(int index) {
    if (index >= _selectedIds.length) return null;
    final targetId = _selectedIds[index];
    for (final item in _candidates) {
      if (item.id == targetId) return item;
    }
    for (final item in _current) {
      if (item.id == targetId) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Öne Çıkan Etkinlikler'),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: AppTheme.panel(tone: AppTone.admin, radius: 20, elevated: true),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Haberler alanında dönecek 3 etkinliği seçin.',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Seçilen kartlar 3 saniyede bir değişir. Sıra burada seçtiğiniz sıraya göre kullanılır.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                        ),
                        const SizedBox(height: 16),
                        for (var i = 0; i < 3; i++) ...[
                          _SelectedSlotCard(
                            index: i,
                            item: _selectedItemAt(i),
                            onRemove: _selectedItemAt(i) == null
                                ? null
                                : () => _toggleSelection(_selectedItemAt(i)!),
                          ),
                          if (i < 2) const SizedBox(height: 10),
                        ],
                        if (_error.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(_error, style: const TextStyle(color: AppTheme.error)),
                        ],
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.auto_awesome_rounded),
                            label: Text(_saving ? 'Kaydediliyor...' : 'Seçimi Kaydet'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Mevcut Etkinlikler',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 10),
                  for (final item in _candidates) ...[
                    _FeaturedCandidateCard(
                      item: item,
                      selected: _selectedIds.contains(item.id),
                      disabled: !_selectedIds.contains(item.id) && _selectedIds.length >= 3,
                      onTap: () => _toggleSelection(item),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
      ),
    );
  }
}

class _SelectedSlotCard extends StatelessWidget {
  final int index;
  final FeaturedEventItem? item;
  final VoidCallback? onRemove;

  const _SelectedSlotCard({
    required this.index,
    required this.item,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceSecondary,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppTheme.borderSoft),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.violet.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${index + 1}',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item?.name ?? 'Bu slot boş',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  item == null
                      ? 'Aşağıdan bir etkinlik seçin'
                      : '${item.city} · ${_formatFeaturedDate(item.eventDate)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          if (item != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }
}

class _FeaturedCandidateCard extends StatelessWidget {
  final FeaturedEventItem item;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _FeaturedCandidateCard({
    required this.item,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius: BorderRadius.circular(20),
      child: Opacity(
        opacity: disabled ? 0.55 : 1,
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected ? AppTheme.surfaceElevated : AppTheme.surfaceSecondary,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected ? AppTheme.violet.withOpacity(0.55) : AppTheme.borderSoft,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: item.cover.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: item.cover,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(color: AppTheme.surfacePrimary),
                          placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
                        )
                      : Container(color: AppTheme.surfacePrimary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${item.city} · ${_formatFeaturedDate(item.eventDate)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.violet.withOpacity(0.18) : AppTheme.surfacePrimary,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  selected ? 'Seçildi' : 'Öne Çıkar',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
