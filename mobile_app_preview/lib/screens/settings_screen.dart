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

  const SettingsScreen({super.key, required this.sessionToken});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _kAvatarPath = 'settings.avatar_path';
  static const String _buildSha = String.fromEnvironment('APP_BUILD_SHA', defaultValue: 'local');

  final _picker = ImagePicker();
  final _usernameCtrl = TextEditingController();
  bool _notificationsEnabled = true;
  String _language = 'tr';
  String _city = 'İstanbul';
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
      if (widget.sessionToken.trim().isNotEmpty) {
        final remote = await ProfileApi.settings(widget.sessionToken);
        _notificationsEnabled = remote.notificationsEnabled;
        _language = remote.language == 'en' ? 'en' : 'tr';
        _city = remote.city.trim().isEmpty ? 'İstanbul' : remote.city.trim();
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
        avatarUrl: avatarUrl,
      );
      if (!mounted) return true;
      setState(() {
        _notificationsEnabled = saved.notificationsEnabled;
        _language = saved.language == 'en' ? 'en' : 'tr';
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

  Future<void> _saveCity(String v) async {
    setState(() => _city = v);
    await _saveRemote(city: v);
  }

  String _birthDateUi() {
    final raw = _birthDate.trim();
    if (raw.isEmpty) return 'Seçilmedi';
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
    const months = [
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
              title: const Text('Doğum Tarihi', style: TextStyle(color: Colors.black)),
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
                        decoration: const InputDecoration(labelText: 'Gün', border: OutlineInputBorder()),
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
                        decoration: const InputDecoration(labelText: 'Ay', border: OutlineInputBorder()),
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
                        decoration: const InputDecoration(labelText: 'Yıl', border: OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Vazgeç'),
                ),
                TextButton(
                  onPressed: () {
                    final selected = DateTime(year, month, day);
                    if (selected.isBefore(first) || selected.isAfter(last)) return;
                    Navigator.of(ctx).pop(selected);
                  },
                  child: const Text('Seç'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _saveNotif(bool v) async {
    setState(() => _notificationsEnabled = v);
    await _saveRemote(notifications: v);
    await PushNotificationsService.syncPreference(widget.sessionToken, v);
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
      const SnackBar(content: Text('Bağlantı açılamadı')),
    );
  }

  Future<void> _openSupportChat() async {
    if (widget.sessionToken.trim().isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Destek için önce giriş yapın')),
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
        SnackBar(content: Text('Destek açılamadı: $e')),
      );
    }
  }

  Future<void> _deleteAccountFlow() async {
    if (_deletingAccount || widget.sessionToken.trim().isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hesabımı Sil'),
        content: const Text(
          'Bu işlem hesabınızı pasife alır ve bu cihazdaki oturumunuz kapanır. Devam etmek istiyor musunuz?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Hesabı Sil'),
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
        const SnackBar(content: Text('Hesabınız pasife alındı')),
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
                        const Text('Yaşadığınız Şehir', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: kTurkiyeCities.contains(_city) ? _city : 'İstanbul',
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
                        const Expanded(
                          child: Text('Doğum Tarihiniz', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        ),
                        Text(
                          _birthDateUi(),
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        const SizedBox(width: 8),
                        OutlinedButton(
                          onPressed: _saving ? null : _pickBirthDate,
                          child: const Text('Seç'),
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
                          items: const [
                            DropdownMenuItem(value: 'tr', child: Text('Türkçe')),
                            DropdownMenuItem(value: 'en', child: Text('English')),
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
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(t('notifications'), style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
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
                        const Text('Yasal', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: () => _openLink(LegalLinks.privacyPolicy),
                              child: const Text('Gizlilik Politikası'),
                            ),
                            OutlinedButton(
                              onPressed: () => _openLink(LegalLinks.kvkkNotice),
                              child: const Text('KVKK Aydınlatma'),
                            ),
                            OutlinedButton(
                              onPressed: () => _openLink(LegalLinks.terms),
                              child: const Text('Kullanım Şartları'),
                            ),
                            OutlinedButton(
                              onPressed: _openSupportChat,
                              child: const Text('Destek'),
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
                          label: const Text(
                            'Hesabımı Sil',
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
