import 'dart:async';

import 'package:flutter/material.dart';

import '../services/date_time_format.dart';
import '../services/i18n.dart';
import '../services/notification_center.dart';
import '../services/notifications_api.dart';
import '../services/profile_api.dart';
import '../services/push_notifications_service.dart';

class NotificationsScreen extends StatefulWidget {
  final String sessionToken;
  final Future<void> Function(String route)? onOpenRoute;

  const NotificationsScreen({
    super.key,
    required this.sessionToken,
    this.onOpenRoute,
  });

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  static const Map<String, bool> _defaultNotificationPreferences = {
    'news': true,
    'dance_night': true,
    'festival': true,
    'competition': true,
    'promo_lesson': true,
    'system': true,
  };

  static const List<MapEntry<String, String>> _notificationPreferenceLabels = [
    MapEntry('news', 'notification_news'),
    MapEntry('dance_night', 'notification_dance_night'),
    MapEntry('festival', 'notification_festival'),
    MapEntry('competition', 'notification_competition'),
    MapEntry('promo_lesson', 'notification_promo_lesson'),
    MapEntry('system', 'notification_system'),
  ];

  NotificationSummary _summary = const NotificationSummary(
    totalCount: 0,
    incomingFriendRequestsCount: 0,
    unreadMessagesCount: 0,
  );
  List<NotificationFeedItem> _feed = const [];
  bool _notificationsEnabled = true;
  Map<String, bool> _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences);
  bool _loading = true;
  bool _savingSettings = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    NotificationCenter.summary.addListener(_onExternalSummary);
    _summary = NotificationCenter.summary.value;
    _loading = false;
    unawaited(PushNotificationsService.clearBadge());
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 8), (_) => _refresh(silent: true));
  }

  @override
  void dispose() {
    _timer?.cancel();
    NotificationCenter.summary.removeListener(_onExternalSummary);
    super.dispose();
  }

  void _onExternalSummary() {
    if (!mounted) return;
    setState(() {
      _summary = NotificationCenter.summary.value;
      _loading = false;
      _error = null;
    });
  }

  Future<void> _refresh({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<dynamic>([
        NotificationsApi.fetchSummary(widget.sessionToken),
        NotificationsApi.fetchFeed(widget.sessionToken, limit: 100),
        ProfileApi.settings(widget.sessionToken),
      ]);
      final summary = results[0] as NotificationSummary;
      final feed = results[1] as List<NotificationFeedItem>;
      final settings = results[2] as ProfileSettingsData;
      if (!mounted) return;
      NotificationCenter.setSummary(summary);
      setState(() {
        _summary = summary;
        _feed = feed;
        _notificationsEnabled = settings.notificationsEnabled;
        _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences)
          ..addAll(settings.notificationPreferences);
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _saveNotif(bool value) async {
    if (_savingSettings) return;
    final nextPrefs = Map<String, bool>.from(_notificationPreferences);
    if (value) {
      for (final key in _defaultNotificationPreferences.keys) {
        nextPrefs[key] = true;
      }
    }
    setState(() {
      _savingSettings = true;
      _notificationsEnabled = value;
      if (value) {
        _notificationPreferences = nextPrefs;
      }
    });
    try {
      final saved = await ProfileApi.updateSettings(
        sessionToken: widget.sessionToken,
        notificationsEnabled: value,
        notificationPreferences: value ? nextPrefs : _notificationPreferences,
      );
      if (!mounted) return;
      setState(() {
        _notificationsEnabled = saved.notificationsEnabled;
        _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences)
          ..addAll(saved.notificationPreferences);
      });
      await PushNotificationsService.syncPreference(widget.sessionToken, value);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _savingSettings = false);
      }
    }
  }

  Future<void> _saveNotificationPreference(String key, bool value) async {
    if (_savingSettings) return;
    final nextPrefs = Map<String, bool>.from(_notificationPreferences)..[key] = value;
    setState(() {
      _savingSettings = true;
      _notificationPreferences = nextPrefs;
    });
    try {
      final saved = await ProfileApi.updateSettings(
        sessionToken: widget.sessionToken,
        notificationPreferences: nextPrefs,
      );
      if (!mounted) return;
      setState(() {
        _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences)
          ..addAll(saved.notificationPreferences);
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _savingSettings = false);
      }
    }
  }

  Future<void> _openSettingsSheet() async {
    final t = I18n.t;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            void syncSheet() => setSheetState(() {});
            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 18),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          t('notification_settings'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                        const Spacer(),
                        if (_savingSettings)
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121826),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  t('notifications'),
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  t('notifications_toggle_all'),
                                  style: TextStyle(color: Colors.white.withOpacity(0.66), fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          Transform.scale(
                            scale: 0.82,
                            child: Switch(
                              value: _notificationsEnabled,
                              onChanged: _savingSettings
                                  ? null
                                  : (value) async {
                                      syncSheet();
                                      await _saveNotif(value);
                                      syncSheet();
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    ..._notificationPreferenceLabels.map(
                      (entry) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF121826),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                I18n.t(entry.value),
                                style: TextStyle(
                                  color: _notificationsEnabled ? Colors.white : Colors.white38,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Transform.scale(
                              scale: 0.82,
                              child: Switch(
                                value: _notificationPreferences[entry.key] ?? true,
                                onChanged: (_savingSettings || !_notificationsEnabled)
                                    ? null
                                    : (value) async {
                                        syncSheet();
                                        await _saveNotificationPreference(entry.key, value);
                                        syncSheet();
                                      },
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(t('notifications')),
        actions: [
          IconButton(
            tooltip: t('notification_settings'),
            onPressed: _openSettingsSheet,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: Text(t('notifications_load_error')),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(14),
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t('notifications_latest'),
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                            ),
                          ),
                          TextButton.icon(
                            onPressed: _feed.isEmpty
                                ? null
                                : () async {
                                    final ok = await showDialog<bool>(
                                      context: context,
                                      builder: (_) => AlertDialog(
                                        title: Text(t('clear_all_confirm_title')),
                                        content: Text(t('clear_all_confirm_body')),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.of(context).pop(false),
                                            child: Text(I18n.t('cancel')),
                                          ),
                                          ElevatedButton(
                                            onPressed: () => Navigator.of(context).pop(true),
                                            child: Text(t('clear_all')),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (ok != true) return;
                                    try {
                                      await NotificationsApi.clearFeed(widget.sessionToken);
                                      if (!mounted) return;
                                      setState(() => _feed = const []);
                                      await _refresh(silent: true);
                                    } catch (e) {
                                      if (!mounted) return;
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text(e.toString())),
                                      );
                                    }
                                  },
                            icon: const Icon(Icons.delete_sweep, size: 18),
                            label: Text(t('clear_all')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      if (_feed.isEmpty)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF121826),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Text(
                            t('notifications_empty'),
                            style: TextStyle(color: Colors.white.withOpacity(0.75)),
                          ),
                        )
                      else
                        ..._feed.map(
                          (n) {
                            final route = n.route.trim();
                            final canOpen = route.startsWith('/') && widget.onOpenRoute != null;
                            final item = Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: const Color(0xFF121826),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white12),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          n.title.trim().isEmpty ? t('notifications') : n.title.trim(),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        _fmtDate(n.createdAt),
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    n.body,
                                    style: const TextStyle(color: Colors.white70),
                                  ),
                                  if (n.sentByName.trim().isNotEmpty) ...[
                                    const SizedBox(height: 6),
                                    Text(
                                      '${t('sender_label')}: ${n.sentByName}',
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            );
                            if (!canOpen) return item;
                            return InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: () async {
                                await widget.onOpenRoute?.call(route);
                              },
                              child: item,
                            );
                          },
                        ),
                    ],
                  ),
      ),
    );
  }

  String _fmtDate(String raw) {
    return formatDateTimeDdMmYyyyHmDot(raw);
  }
}
