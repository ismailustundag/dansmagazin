import 'dart:async';
import 'dart:io';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_settings.dart';
import '../services/i18n.dart';
import '../services/legal_links.dart';
import '../services/profile_api.dart';
import '../services/push_notifications_service.dart';
import '../services/turkiye_cities.dart';
import 'chat_thread_screen.dart';

class SettingsScreen extends StatefulWidget {
  final String sessionToken;
  final bool isSuperAdmin;

  const SettingsScreen({
    super.key,
    required this.sessionToken,
    this.isSuperAdmin = false,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _kAvatarPath = 'settings.avatar_path';
  static const String _buildSha = String.fromEnvironment('APP_BUILD_SHA', defaultValue: 'local');
  static const String _defaultCity = 'İstanbul';
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

  final _picker = ImagePicker();
  final _usernameCtrl = TextEditingController();
  bool _notificationsEnabled = true;
  Map<String, bool> _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences);
  bool _notificationsExpanded = false;
  String _language = 'tr';
  double _textScale = 1.0;
  String _city = _defaultCity;
  String _birthDate = '';
  String _avatarPath = '';
  String _avatarUrl = '';
  String _email = '';
  bool _loading = true;
  bool _saving = false;
  bool _pickingAvatar = false;
  bool _deletingAccount = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final avatar = prefs.getString(_kAvatarPath) ?? '';
    try {
      _textScale = AppSettings.textScale.value;
      if (widget.sessionToken.trim().isNotEmpty) {
        final remote = await ProfileApi.settings(widget.sessionToken);
        _notificationsEnabled = remote.notificationsEnabled;
        _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences)
          ..addAll(remote.notificationPreferences);
        _language = remote.language == 'en' || remote.language == 'es' ? remote.language : 'tr';
        _city = remote.city.trim().isEmpty ? _defaultCity : remote.city.trim();
        _birthDate = remote.birthDate.trim();
        _avatarUrl = remote.avatarUrl;
        _email = remote.email;
        _usernameCtrl.text = remote.username;
        await AppSettings.setLanguage(_language);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _avatarPath = avatar;
      _loading = false;
    });
  }

  Future<bool> _saveRemote({
    String? username,
    String? city,
    String? birthDate,
    String? language,
    bool? notifications,
    Map<String, bool>? notificationPreferences,
    String? avatarUrl,
  }) async {
    if (widget.sessionToken.trim().isEmpty) return false;
    setState(() => _saving = true);
    try {
      final saved = await ProfileApi.updateSettings(
        sessionToken: widget.sessionToken,
        username: username,
        city: city,
        birthDate: birthDate,
        language: language,
        notificationsEnabled: notifications,
        notificationPreferences: notificationPreferences,
        avatarUrl: avatarUrl,
      );
      if (!mounted) return true;
      setState(() {
        _notificationsEnabled = saved.notificationsEnabled;
        _notificationPreferences = Map<String, bool>.from(_defaultNotificationPreferences)
          ..addAll(saved.notificationPreferences);
        _language = saved.language == 'en' || saved.language == 'es' ? saved.language : 'tr';
        _city = saved.city.trim().isEmpty ? _city : saved.city.trim();
        _birthDate = saved.birthDate.trim();
        _avatarUrl = saved.avatarUrl;
        _email = saved.email;
        if (username != null) _usernameCtrl.text = saved.username;
      });
      if (language != null) {
        await AppSettings.setLanguage(_language);
      }
      return true;
    } catch (e) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveLanguage(String v) async {
    setState(() => _language = v);
    await AppSettings.setLanguage(v);
    await _saveRemote(language: v);
  }

  Future<void> _saveTextScale(double v) async {
    final normalized = v.clamp(0.90, 1.35).toDouble();
    setState(() => _textScale = normalized);
    await AppSettings.setTextScale(normalized);
  }

  String _textScaleLabel(double v) {
    if (v <= 0.95) return I18n.t('small');
    if (v >= 1.22) return I18n.t('large');
    return I18n.t('normal');
  }

  Future<void> _saveCity(String v) async {
    setState(() => _city = v);
    await _saveRemote(city: v);
  }

  String _birthDateUi() {
    final raw = _birthDate.trim();
    if (raw.isEmpty) return I18n.t('not_selected');
    final dt = _parseBirthDate(raw);
    if (dt == null) return raw;
    return DateFormat('dd.MM.yyyy').format(dt);
  }

  DateTime? _parseBirthDate(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    try {
      return DateFormat('dd.MM.yyyy').parseStrict(v);
    } catch (_) {}
    try {
      return DateFormat('dd-MM-yyyy').parseStrict(v);
    } catch (_) {}
    try {
      return DateFormat('yyyy-MM-dd').parseStrict(v);
    } catch (_) {}
    return DateTime.tryParse(v);
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final first = DateTime(1900, 1, 1);
    final parsed = _parseBirthDate(_birthDate);
    final fallback = DateTime(now.year - 20, 1, 1);
    final base = (parsed != null && !parsed.isAfter(now)) ? parsed : fallback;
    final initial = base.isBefore(first) ? first : (base.isAfter(now) ? now : base);
    final picked = await _pickBirthDateManual(initial, first, now);
    if (picked == null) return;
    final apiDate = DateFormat('yyyy-MM-dd').format(picked);
    setState(() => _birthDate = apiDate);
    await _saveRemote(birthDate: apiDate);
  }

  Future<DateTime?> _pickBirthDateManual(DateTime initial, DateTime first, DateTime last) async {
    int year = initial.year;
    int month = initial.month;
    int day = initial.day;
    final years = [for (int y = last.year; y >= first.year; y--) y];
    final months = I18n.language == 'es'
        ? const [
            'Enero',
            'Febrero',
            'Marzo',
            'Abril',
            'Mayo',
            'Junio',
            'Julio',
            'Agosto',
            'Septiembre',
            'Octubre',
            'Noviembre',
            'Diciembre',
          ]
        : I18n.isEnglish
        ? const [
            'January',
            'February',
            'March',
            'April',
            'May',
            'June',
            'July',
            'August',
            'September',
            'October',
            'November',
            'December',
          ]
        : const [
            'Ocak',
            'Şubat',
            'Mart',
            'Nisan',
            'Mayıs',
            'Haziran',
            'Temmuz',
            'Ağustos',
            'Eylül',
            'Ekim',
            'Kasım',
            'Aralık',
          ];

    return showDialog<DateTime>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setModalState) {
            final maxDay = _daysInMonth(year, month);
            if (day > maxDay) day = maxDay;
            final days = [for (int d = 1; d <= maxDay; d++) d];
            return AlertDialog(
              backgroundColor: Colors.white,
              title: Text(I18n.t('birth_date_title'), style: const TextStyle(color: Colors.black)),
              content: SizedBox(
                width: 420,
                child: Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: day,
                        dropdownColor: Colors.white,
                        style: const TextStyle(color: Colors.black),
                        items: days
                            .map((d) => DropdownMenuItem<int>(value: d, child: Text(d.toString().padLeft(2, '0'))))
                            .toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setModalState(() => day = v);
                        },
                        decoration: InputDecoration(labelText: I18n.t('day'), border: const OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: month,
                        dropdownColor: Colors.white,
                        style: const TextStyle(color: Colors.black),
                        items: List.generate(
                          12,
                          (i) => DropdownMenuItem<int>(value: i + 1, child: Text(months[i])),
                        ),
                        onChanged: (v) {
                          if (v == null) return;
                          setModalState(() => month = v);
                        },
                        decoration: InputDecoration(labelText: I18n.t('month'), border: const OutlineInputBorder()),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: year,
                        dropdownColor: Colors.white,
                        style: const TextStyle(color: Colors.black),
                        items: years.map((y) => DropdownMenuItem<int>(value: y, child: Text(y.toString()))).toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setModalState(() => year = v);
                        },
                        decoration: InputDecoration(labelText: I18n.t('year'), border: const OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(I18n.t('cancel')),
                ),
                TextButton(
                  onPressed: () {
                    final selected = DateTime(year, month, day);
                    if (selected.isBefore(first) || selected.isAfter(last)) return;
                    Navigator.of(ctx).pop(selected);
                  },
                  child: Text(I18n.t('select')),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _saveNotif(bool v) async {
    final nextPrefs = v
        ? Map<String, bool>.from(_notificationPreferences)
        : Map<String, bool>.from(_notificationPreferences);
    setState(() {
      _notificationsEnabled = v;
      _notificationsExpanded = true;
      if (v) {
        for (final key in _defaultNotificationPreferences.keys) {
          nextPrefs[key] = true;
        }
        _notificationPreferences = nextPrefs;
      }
    });
    await _saveRemote(
      notifications: v,
      notificationPreferences: v ? nextPrefs : _notificationPreferences,
    );
    await PushNotificationsService.syncPreference(widget.sessionToken, v);
  }

  Future<void> _saveNotificationPreference(String key, bool value) async {
    final nextPrefs = Map<String, bool>.from(_notificationPreferences)..[key] = value;
    setState(() => _notificationPreferences = nextPrefs);
    await _saveRemote(notificationPreferences: nextPrefs);
  }

  Future<void> _saveUsername() async {
    final u = _usernameCtrl.text.trim();
    final ok = await _saveRemote(username: u);
    if (!ok) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(I18n.t('username_updated'))),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (ok || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(I18n.t('link_open_failed'))),
    );
  }

  Future<void> _openSupportChat() async {
    if (widget.sessionToken.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('login_required_for_support'))),
      );
      return;
    }

    try {
      final contact = await ProfileApi.supportContact(widget.sessionToken);
      final target = contact ??
          const SupportContact(
            accountId: 164,
            name: 'Dansmagazin',
            avatarUrl: '',
          );
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            sessionToken: widget.sessionToken,
            peerAccountId: target.accountId,
            peerName: target.name,
            peerAvatarUrl: target.avatarUrl,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('support_open_failed')}: $e')),
      );
    }
  }

  Future<void> _deleteAccountFlow() async {
    if (_deletingAccount || widget.sessionToken.trim().isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.t('delete_account')),
        content: Text(I18n.t('delete_account_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(I18n.t('cancel')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(I18n.t('delete_account_action')),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => _deletingAccount = true);
    try {
      await ProfileApi.deleteAccount(widget.sessionToken);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('delete_account_done'))),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _deletingAccount = false);
    }
  }

  Future<String?> _pickAvatarPathIOSSafe() async {
    if (!Platform.isIOS) return null;

    // iOS simulator ve bazi iOS surumlerinde PHPicker kitlenebildigi icin,
    // once Files tabanli secim denenir.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif'],
      allowMultiple: false,
      withData: false,
      withReadStream: false,
      lockParentWindow: true,
    );

    if (result == null || result.files.isEmpty) return null;
    return result.files.single.path;
  }

  Future<void> _pickAvatar() async {
    if (_pickingAvatar) return;
    setState(() => _pickingAvatar = true);
    FocusScope.of(context).unfocus();

    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));

      String? selectedPath;

      try {
        selectedPath = await _pickAvatarPathIOSSafe();
      } catch (_) {
        selectedPath = null;
      }

      if (selectedPath == null || selectedPath.isEmpty) {
        final img = await _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 90,
          requestFullMetadata: false,
          maxWidth: 1440,
        );
        if (img == null) return;
        selectedPath = img.path;
      }

      final path = selectedPath;
      if (path == null || path.isEmpty) return;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAvatarPath, path);
      if (!mounted) return;
      setState(() => _avatarPath = path);

      if (widget.sessionToken.trim().isNotEmpty) {
        final uploadedUrl = await ProfileApi.uploadAvatar(
          sessionToken: widget.sessionToken,
          filePath: path,
        );
        if (uploadedUrl.isNotEmpty) {
          if (!mounted) return;
          setState(() => _avatarUrl = uploadedUrl);
          await _saveRemote(avatarUrl: uploadedUrl);
        }
      }
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('photo_pick_failed')}: ${e.message ?? e.code}')),
      );
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('gallery_timeout'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('photo_pick_failed')}: $e')),
      );
    } finally {
      if (mounted) setState(() => _pickingAvatar = false);
    }
  }

  Future<void> _clearAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAvatarPath);
    if (!mounted) return;
    setState(() {
      _avatarPath = '';
      _avatarUrl = '';
    });
    await _saveRemote(avatarUrl: '');
  }

  Widget _avatar() {
    if (_avatarPath.isNotEmpty) {
      final f = File(_avatarPath);
      if (f.existsSync()) {
        return CircleAvatar(radius: 34, backgroundImage: FileImage(f));
      }
    }
    if (_avatarUrl.trim().isNotEmpty) {
      return CircleAvatar(radius: 34, backgroundImage: NetworkImage(_avatarUrl.trim()));
    }
    return const CircleAvatar(
      radius: 34,
      backgroundColor: Color(0xFFE53935),
      child: Icon(Icons.person, color: Colors.white, size: 28),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(t('settings')),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        _avatar(),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t('profile_photo'),
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  OutlinedButton(
                                    onPressed: (_saving || _pickingAvatar) ? null : _pickAvatar,
                                    child: Text(_pickingAvatar ? '...' : t('select')),
                                  ),
                                  if (_avatarPath.isNotEmpty || _avatarUrl.trim().isNotEmpty)
                                    OutlinedButton(
                                      onPressed: (_saving || _pickingAvatar) ? null : _clearAvatar,
                                      child: Text(t('remove')),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('username'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        if (_email.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(_email, style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12)),
                        ],
                        const SizedBox(height: 8),
                        TextField(
                          controller: _usernameCtrl,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            hintText: 'ornek_kullanici',
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ElevatedButton(
                            onPressed: _saving ? null : _saveUsername,
                            child: Text(t('save')),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(I18n.t('city_of_residence'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: kTurkiyeCities.contains(_city) ? _city : _defaultCity,
                          items: kTurkiyeCities
                              .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
                              .toList(),
                          onChanged: _saving
                              ? null
                              : (v) {
                                  if (v != null) _saveCity(v);
                                },
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(I18n.t('birth_date_label'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                        Text(
                          _birthDateUi(),
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _saving ? null : _pickBirthDate,
                          child: Text(I18n.t('select')),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('language'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: _language,
                          items: [
                            DropdownMenuItem(
                              value: 'tr',
                              child: Text(
                                I18n.language == 'es'
                                    ? 'Turco'
                                    : (I18n.isEnglish ? 'Turkish' : 'Türkçe'),
                              ),
                            ),
                            const DropdownMenuItem(value: 'en', child: Text('English')),
                            const DropdownMenuItem(value: 'es', child: Text('Español')),
                          ],
                          onChanged: _saving
                              ? null
                              : (v) {
                                  if (v != null) _saveLanguage(v);
                                },
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
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
                                I18n.t('message_text_size'),
                                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                              ),
                            ),
                            Text(
                              '${(_textScale * 100).round()}% (${_textScaleLabel(_textScale)})',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Slider(
                          value: _textScale,
                          min: 0.90,
                          max: 1.35,
                          divisions: 9,
                          label: '${(_textScale * 100).round()}%',
                          onChanged: _saving
                              ? null
                              : (v) {
                                  final normalized = v.clamp(0.90, 1.35).toDouble();
                                  setState(() => _textScale = normalized);
                                  AppSettings.textScale.value = normalized;
                                },
                          onChangeEnd: _saving ? null : _saveTextScale,
                        ),
                        Text(
                          I18n.t('example_messages_emojis'),
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 12 * _textScale,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      children: [
                        InkWell(
                          onTap: () => setState(() => _notificationsExpanded = !_notificationsExpanded),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(t('notifications'), style: const TextStyle(fontWeight: FontWeight.w700)),
                                    const SizedBox(height: 2),
                                    Text(
                                      I18n.t('notifications_toggle_all'),
                                      style: TextStyle(color: Colors.white.withOpacity(0.65), fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                _notificationsExpanded ? Icons.expand_less : Icons.expand_more,
                                color: Colors.white70,
                              ),
                              const SizedBox(width: 6),
                              Transform.scale(
                                scale: 0.80,
                                child: Switch(
                                  value: _notificationsEnabled,
                                  onChanged: _saving ? null : _saveNotif,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_notificationsExpanded) ...[
                          const Divider(height: 16, color: Colors.white12),
                          ..._notificationPreferenceLabels.map(
                            (entry) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      I18n.t(entry.value),
                                      style: TextStyle(
                                        color: _notificationsEnabled ? Colors.white : Colors.white38,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
                                  Transform.scale(
                                    scale: 0.80,
                                    child: Switch(
                                      value: _notificationPreferences[entry.key] ?? true,
                                      onChanged: (_saving || !_notificationsEnabled)
                                          ? null
                                          : (v) => _saveNotificationPreference(entry.key, v),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(I18n.t('legal'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () => _openLink(LegalLinks.privacyPolicy),
                              child: Text(I18n.t('privacy_policy')),
                            ),
                            OutlinedButton(
                              onPressed: () => _openLink(LegalLinks.kvkkNotice),
                              child: Text(I18n.t('kvkk_notice')),
                            ),
                            OutlinedButton(
                              onPressed: () => _openLink(LegalLinks.terms),
                              child: Text(I18n.t('terms_of_use')),
                            ),
                            OutlinedButton(
                              onPressed: _openSupportChat,
                              child: Text(I18n.t('support')),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextButton.icon(
                          onPressed: _deletingAccount ? null : _deleteAccountFlow,
                          icon: _deletingAccount
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Icon(Icons.delete_forever, color: Colors.redAccent),
                          label: Text(
                            I18n.t('delete_account'),
                            style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  Center(
                    child: Text(
                      'Build: $_buildSha',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
