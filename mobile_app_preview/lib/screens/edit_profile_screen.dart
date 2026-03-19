import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/i18n.dart';
import '../services/profile_api.dart';
import '../services/turkiye_cities.dart';

class EditProfileScreen extends StatefulWidget {
  final String sessionToken;

  const EditProfileScreen({
    super.key,
    required this.sessionToken,
  });

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const _kAvatarPath = 'settings.avatar_path';
  static const String _defaultCity = 'İstanbul';
  static const List<String> _genderValues = ['female', 'male', 'unspecified'];

  final _picker = ImagePicker();
  final _usernameCtrl = TextEditingController();
  final _danceInterestsCtrl = TextEditingController();
  final _danceSchoolCtrl = TextEditingController();
  final _aboutCtrl = TextEditingController();

  String _city = _defaultCity;
  String _birthDate = '';
  String _gender = 'unspecified';
  String _avatarPath = '';
  String _avatarUrl = '';
  bool _loading = true;
  bool _saving = false;
  bool _pickingAvatar = false;

  String _resolveAvatarUrl(String url, String updatedAt) {
    final raw = url.trim();
    if (raw.isEmpty) return '';
    final bust = updatedAt.trim().isEmpty ? DateTime.now().millisecondsSinceEpoch.toString() : updatedAt.trim();
    final separator = raw.contains('?') ? '&' : '?';
    return '$raw${separator}v=${Uri.encodeQueryComponent(bust)}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _danceInterestsCtrl.dispose();
    _danceSchoolCtrl.dispose();
    _aboutCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final avatar = prefs.getString(_kAvatarPath) ?? '';
    try {
      final remote = await ProfileApi.settings(widget.sessionToken);
      if (!mounted) return;
      setState(() {
        _usernameCtrl.text = remote.username;
        _danceInterestsCtrl.text = remote.danceInterests;
        _danceSchoolCtrl.text = remote.danceSchool;
        _aboutCtrl.text = remote.about;
        _city = remote.city.trim().isEmpty ? _defaultCity : remote.city.trim();
        _birthDate = remote.birthDate.trim();
        _gender = _genderValues.contains(remote.gender.trim()) ? remote.gender.trim() : 'unspecified';
        _avatarUrl = _resolveAvatarUrl(remote.avatarUrl, remote.updatedAt);
        _avatarPath = avatar;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _avatarPath = avatar;
        _loading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
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

  String _birthDateUi() {
    final raw = _birthDate.trim();
    if (raw.isEmpty) return I18n.t('not_selected');
    final dt = _parseBirthDate(raw);
    if (dt == null) return raw;
    return DateFormat('dd.MM.yyyy').format(dt);
  }

  int _daysInMonth(int year, int month) => DateTime(year, month + 1, 0).day;

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
            'Subat',
            'Mart',
            'Nisan',
            'Mayis',
            'Haziran',
            'Temmuz',
            'Agustos',
            'Eylul',
            'Ekim',
            'Kasim',
            'Aralik',
          ];

    return showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: const Color(0xFF101522),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final maxDay = _daysInMonth(year, month);
            if (day > maxDay) day = maxDay;
            final days = [for (int d = 1; d <= maxDay; d++) d];
            return SafeArea(
              top: false,
              child: SizedBox(
                height: 320,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            child: Text(I18n.t('cancel')),
                          ),
                          const Spacer(),
                          Text(
                            I18n.t('birth_date_title'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(DateTime(year, month, day)),
                            child: Text(I18n.t('save')),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Row(
                        children: [
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: FixedExtentScrollController(initialItem: days.indexOf(day)),
                              itemExtent: 36,
                              onSelectedItemChanged: (i) => setSheet(() => day = days[i]),
                              children: days.map((d) => Center(child: Text('$d'))).toList(),
                            ),
                          ),
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: FixedExtentScrollController(initialItem: month - 1),
                              itemExtent: 36,
                              onSelectedItemChanged: (i) => setSheet(() => month = i + 1),
                              children: months.map((m) => Center(child: Text(m))).toList(),
                            ),
                          ),
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: FixedExtentScrollController(initialItem: years.indexOf(year)),
                              itemExtent: 36,
                              onSelectedItemChanged: (i) => setSheet(() => year = years[i]),
                              children: years.map((y) => Center(child: Text('$y'))).toList(),
                            ),
                          ),
                        ],
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

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final first = DateTime(1900, 1, 1);
    final parsed = _parseBirthDate(_birthDate);
    final fallback = DateTime(now.year - 20, 1, 1);
    final base = (parsed != null && !parsed.isAfter(now)) ? parsed : fallback;
    final initial = base.isBefore(first) ? first : (base.isAfter(now) ? now : base);
    final picked = await _pickBirthDateManual(initial, first, now);
    if (picked == null || !mounted) return;
    setState(() => _birthDate = DateFormat('yyyy-MM-dd').format(picked));
  }

  Future<String?> _pickAvatarPathIOSSafe() async {
    if (!Platform.isIOS) return null;
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

      final uploadedUrl = await ProfileApi.uploadAvatar(
        sessionToken: widget.sessionToken,
        filePath: path,
      );
      if (!mounted) return;
      await prefs.remove(_kAvatarPath);
      setState(() {
        _avatarPath = '';
        _avatarUrl = uploadedUrl;
      });
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
  }

  Widget _avatar() {
    if (_avatarUrl.trim().isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Image.network(_avatarUrl.trim(), width: 118, height: 118, fit: BoxFit.cover),
      );
    }
    if (_avatarPath.isNotEmpty) {
      final f = File(_avatarPath);
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: Image.file(f, width: 118, height: 118, fit: BoxFit.cover),
        );
      }
    }
    return Container(
      width: 118,
      height: 118,
      decoration: BoxDecoration(
        color: const Color(0xFFB45F13),
        borderRadius: BorderRadius.circular(26),
      ),
      child: const Icon(Icons.person, color: Colors.white, size: 46),
    );
  }

  Future<void> _saveProfile() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      await ProfileApi.updateSettings(
        sessionToken: widget.sessionToken,
        username: _usernameCtrl.text.trim(),
        city: _city.trim(),
        birthDate: _birthDate.trim(),
        gender: _gender.trim(),
        danceInterests: _danceInterestsCtrl.text.trim(),
        danceSchool: _danceSchoolCtrl.text.trim(),
        about: _aboutCtrl.text.trim(),
        avatarUrl: _avatarUrl.trim(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('saved'))),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _card({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF151B28),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return Scaffold(
      backgroundColor: const Color(0xFF0C111B),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111827),
        title: Text(t('edit_profile')),
      ),
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(14),
                children: [
                  _card(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _avatar(),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                t('profile_photo'),
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
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
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('username'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _usernameCtrl,
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                            hintText: 'ornek_kullanici',
                          ),
                        ),
                      ],
                    ),
                  ),
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('city_of_residence'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: kTurkiyeCities.contains(_city) ? _city : _defaultCity,
                          items: kTurkiyeCities
                              .map((c) => DropdownMenuItem<String>(value: c, child: Text(c)))
                              .toList(),
                          onChanged: _saving ? null : (v) => setState(() => _city = v ?? _defaultCity),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t('birth_date_label'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                                  const SizedBox(height: 4),
                                  Text(
                                    _birthDateUi(),
                                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                                  ),
                                  const SizedBox(height: 10),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: OutlinedButton(
                                      onPressed: _saving ? null : _pickBirthDate,
                                      child: Text(t('select')),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        Text(t('gender'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: _genderValues.contains(_gender) ? _gender : 'unspecified',
                          items: _genderValues
                              .map(
                                (value) => DropdownMenuItem<String>(
                                  value: value,
                                  child: Text(t('gender_$value')),
                                ),
                              )
                              .toList(),
                          onChanged: _saving ? null : (v) => setState(() => _gender = v ?? 'unspecified'),
                          decoration: const InputDecoration(
                            isDense: true,
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('dance_interests'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _danceInterestsCtrl,
                          maxLines: 2,
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            hintText: t('dance_interests_hint'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('dance_school'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _danceSchoolCtrl,
                          decoration: InputDecoration(
                            isDense: true,
                            border: const OutlineInputBorder(),
                            hintText: t('dance_school_hint'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  _card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t('about_profile'), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _aboutCtrl,
                          maxLines: 5,
                          decoration: InputDecoration(
                            alignLabelWithHint: true,
                            isDense: true,
                            border: const OutlineInputBorder(),
                            hintText: t('about_profile_hint'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _saving ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFB45F13),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      ),
                      child: Text(_saving ? '...' : t('save')),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
