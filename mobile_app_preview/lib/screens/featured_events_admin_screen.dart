import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/featured_events_api.dart';
import '../services/store_api.dart';
import '../theme/app_theme.dart';
import '../widgets/verified_avatar.dart';

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
  bool _savingEvents = false;
  bool _savingStores = false;
  String _eventError = '';
  String _storeError = '';
  List<FeaturedEventItem> _currentEvents = const <FeaturedEventItem>[];
  List<FeaturedEventItem> _eventCandidates = const <FeaturedEventItem>[];
  final List<int> _selectedEventIds = <int>[];
  List<StoreSellerItem> _currentStores = const <StoreSellerItem>[];
  List<StoreSellerItem> _storeCandidates = const <StoreSellerItem>[];
  final List<int> _selectedStoreIds = <int>[];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _eventError = '';
      _storeError = '';
    });
    try {
      final results = await Future.wait([
        FeaturedEventsApi.fetchCurrent(),
        FeaturedEventsApi.fetchCandidates(limit: 180),
        StoreApi.featuredSellers(),
        StoreApi.sellers(limit: 180),
      ]);
      if (!mounted) return;
      final currentEvents = results[0] as List<FeaturedEventItem>;
      final eventCandidates = results[1] as List<FeaturedEventItem>;
      final currentStores = results[2] as List<StoreSellerItem>;
      final storeCandidates = results[3] as List<StoreSellerItem>;
      setState(() {
        _currentEvents = currentEvents;
        _eventCandidates = eventCandidates;
        _selectedEventIds
          ..clear()
          ..addAll(currentEvents.map((e) => e.id));
        _currentStores = currentStores;
        _storeCandidates = storeCandidates;
        _selectedStoreIds
          ..clear()
          ..addAll(currentStores.map((e) => e.accountId));
      });
    } catch (e) {
      if (!mounted) return;
      final message = e.toString();
      setState(() {
        _eventError = message;
        _storeError = message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleEventSelection(FeaturedEventItem item) {
    if (_savingEvents) return;
    setState(() {
      if (_selectedEventIds.contains(item.id)) {
        _selectedEventIds.remove(item.id);
      } else if (_selectedEventIds.length < 3) {
        _selectedEventIds.add(item.id);
      }
    });
  }

  void _toggleStoreSelection(StoreSellerItem item) {
    if (_savingStores) return;
    setState(() {
      if (_selectedStoreIds.contains(item.accountId)) {
        _selectedStoreIds.remove(item.accountId);
      } else if (_selectedStoreIds.length < 3) {
        _selectedStoreIds.add(item.accountId);
      }
    });
  }

  Future<void> _saveEvents() async {
    if (_savingEvents) return;
    setState(() {
      _savingEvents = true;
      _eventError = '';
    });
    try {
      final saved = await FeaturedEventsApi.saveCurrent(
        widget.sessionToken,
        eventIds: List<int>.from(_selectedEventIds),
      );
      if (!mounted) return;
      setState(() => _currentEvents = saved);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Öne çıkan etkinlikler güncellendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _eventError = e.toString());
    } finally {
      if (mounted) setState(() => _savingEvents = false);
    }
  }

  Future<void> _saveStores() async {
    if (_savingStores) return;
    setState(() {
      _savingStores = true;
      _storeError = '';
    });
    try {
      final saved = await StoreApi.saveFeaturedSellers(
        widget.sessionToken,
        accountIds: List<int>.from(_selectedStoreIds),
      );
      if (!mounted) return;
      setState(() => _currentStores = saved);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Öne çıkan mağazalar güncellendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _storeError = e.toString());
    } finally {
      if (mounted) setState(() => _savingStores = false);
    }
  }

  FeaturedEventItem? _selectedEventAt(int index) {
    if (index >= _selectedEventIds.length) return null;
    final targetId = _selectedEventIds[index];
    for (final item in _eventCandidates) {
      if (item.id == targetId) return item;
    }
    for (final item in _currentEvents) {
      if (item.id == targetId) return item;
    }
    return null;
  }

  StoreSellerItem? _selectedStoreAt(int index) {
    if (index >= _selectedStoreIds.length) return null;
    final targetId = _selectedStoreIds[index];
    for (final item in _storeCandidates) {
      if (item.accountId == targetId) return item;
    }
    for (final item in _currentStores) {
      if (item.accountId == targetId) return item;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Öne Çıkanları Düzenle'),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SectionIntroCard(
                    icon: Icons.auto_awesome_rounded,
                    title: 'Öne Çıkan Etkinlikler',
                    subtitle: 'Haberler alanında dönecek 3 etkinliği seçin.',
                    helper: 'Seçilen kartlar 3 saniyede bir değişir. Sıra burada seçtiğin dizilime göre kullanılır.',
                    child: Column(
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          _SelectedEventSlotCard(
                            index: i,
                            item: _selectedEventAt(i),
                            onRemove: _selectedEventAt(i) == null ? null : () => _toggleEventSelection(_selectedEventAt(i)!),
                          ),
                          if (i < 2) const SizedBox(height: 10),
                        ],
                        if (_eventError.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(_eventError, style: const TextStyle(color: AppTheme.error)),
                        ],
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _savingEvents ? null : _saveEvents,
                            icon: const Icon(Icons.auto_awesome_rounded),
                            label: Text(_savingEvents ? 'Kaydediliyor...' : 'Etkinlikleri Kaydet'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Etkinlik Adayları', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  for (final item in _eventCandidates) ...[
                    _FeaturedCandidateCard(
                      item: item,
                      selected: _selectedEventIds.contains(item.id),
                      disabled: !_selectedEventIds.contains(item.id) && _selectedEventIds.length >= 3,
                      onTap: () => _toggleEventSelection(item),
                    ),
                    const SizedBox(height: 10),
                  ],
                  const SizedBox(height: 20),
                  _SectionIntroCard(
                    icon: Icons.storefront_rounded,
                    title: 'Öne Çıkan Mağazalar',
                    subtitle: 'Mağaza alanında dönecek 3 mağazayı seçin.',
                    helper: 'Bu seçimler mağaza sekmesindeki döngülü vitrine düşer.',
                    child: Column(
                      children: [
                        for (var i = 0; i < 3; i++) ...[
                          _SelectedStoreSlotCard(
                            index: i,
                            item: _selectedStoreAt(i),
                            onRemove: _selectedStoreAt(i) == null ? null : () => _toggleStoreSelection(_selectedStoreAt(i)!),
                          ),
                          if (i < 2) const SizedBox(height: 10),
                        ],
                        if (_storeError.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(_storeError, style: const TextStyle(color: AppTheme.error)),
                        ],
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _savingStores ? null : _saveStores,
                            icon: const Icon(Icons.storefront_rounded),
                            label: Text(_savingStores ? 'Kaydediliyor...' : 'Mağazaları Kaydet'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text('Mağaza Adayları', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 10),
                  for (final item in _storeCandidates) ...[
                    _FeaturedStoreCandidateCard(
                      item: item,
                      selected: _selectedStoreIds.contains(item.accountId),
                      disabled: !_selectedStoreIds.contains(item.accountId) && _selectedStoreIds.length >= 3,
                      onTap: () => _toggleStoreSelection(item),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
      ),
    );
  }
}

class _SectionIntroCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final String helper;
  final Widget child;

  const _SectionIntroCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.helper,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 20, elevated: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: Colors.white70),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
            ],
          ),
          const SizedBox(height: 8),
          Text(subtitle, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 6),
          Text(helper, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11)),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}

class _SelectedEventSlotCard extends StatelessWidget {
  final int index;
  final FeaturedEventItem? item;
  final VoidCallback? onRemove;

  const _SelectedEventSlotCard({
    required this.index,
    required this.item,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final currentItem = item;
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
            child: Text('${index + 1}', style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentItem?.name ?? 'Bu slot boş',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  currentItem == null
                      ? 'Aşağıdan bir etkinlik seçin'
                      : '${currentItem.city} · ${_formatFeaturedDate(currentItem.eventDate)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          if (currentItem != null)
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, color: AppTheme.textSecondary),
            ),
        ],
      ),
    );
  }
}

class _SelectedStoreSlotCard extends StatelessWidget {
  final int index;
  final StoreSellerItem? item;
  final VoidCallback? onRemove;

  const _SelectedStoreSlotCard({
    required this.index,
    required this.item,
    this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final currentItem = item;
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
              color: AppTheme.cyan.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text('${index + 1}', style: Theme.of(context).textTheme.labelLarge),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentItem?.storeTitle ?? 'Bu slot boş',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 3),
                Text(
                  currentItem == null
                      ? 'Aşağıdan bir mağaza seçin'
                      : '${currentItem.name} · ${currentItem.productCount} ürün',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                ),
              ],
            ),
          ),
          if (currentItem != null)
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

class _FeaturedStoreCandidateCard extends StatelessWidget {
  final StoreSellerItem item;
  final bool selected;
  final bool disabled;
  final VoidCallback onTap;

  const _FeaturedStoreCandidateCard({
    required this.item,
    required this.selected,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final coverUrl = item.coverImageUrl.trim();
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
              color: selected ? AppTheme.cyan.withOpacity(0.55) : AppTheme.borderSoft,
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: coverUrl.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: coverUrl,
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(color: AppTheme.surfacePrimary),
                          placeholder: (_, __) => Container(color: AppTheme.surfacePrimary),
                        )
                      : Container(
                          color: AppTheme.surfacePrimary,
                          alignment: Alignment.center,
                          child: const Icon(Icons.storefront_rounded, color: Colors.white38),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.storeTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        VerifiedAvatar(
                          imageUrl: item.avatarUrl,
                          label: item.name,
                          isVerified: item.isVerified,
                          radius: 12,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${item.name} · ${item.productCount} ürün',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? AppTheme.cyan.withOpacity(0.18) : AppTheme.surfacePrimary,
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
