import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/app_settings.dart';
import '../services/profile_api.dart';

class SettingsScreen extends StatefulWidget {
  final String sessionToken;

  const SettingsScreen({super.key, required this.sessionToken});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _kAvatarPath = 'settings.avatar_path';

  final _picker = ImagePicker();
  final _usernameCtrl = TextEditingController();
  bool _notificationsEnabled = true;
  String _language = 'tr';
  String _avatarPath = '';
  String _email = '';
  bool _loading = true;
  bool _saving = false;

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
    var avatar = prefs.getString(_kAvatarPath) ?? '';
    try {
      if (widget.sessionToken.trim().isNotEmpty) {
        final remote = await ProfileApi.settings(widget.sessionToken);
        _notificationsEnabled = remote.notificationsEnabled;
        _language = remote.language == 'en' ? 'en' : 'tr';
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

  Future<void> _saveRemote({String? username, String? language, bool? notifications}) async {
    if (widget.sessionToken.trim().isEmpty) return;
    setState(() => _saving = true);
    try {
      final saved = await ProfileApi.updateSettings(
        sessionToken: widget.sessionToken,
        username: username,
        language: language,
        notificationsEnabled: notifications,
      );
      if (!mounted) return;
      setState(() {
        _notificationsEnabled = saved.notificationsEnabled;
        _language = saved.language == 'en' ? 'en' : 'tr';
        _email = saved.email;
        if (username != null) _usernameCtrl.text = saved.username;
      });
      if (language != null) {
        await AppSettings.setLanguage(_language);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveLanguage(String v) async {
    setState(() => _language = v);
    await AppSettings.setLanguage(v);
    await _saveRemote(language: v);
  }

  Future<void> _saveNotif(bool v) async {
    setState(() => _notificationsEnabled = v);
    await _saveRemote(notifications: v);
  }

  Future<void> _saveUsername() async {
    final u = _usernameCtrl.text.trim();
    await _saveRemote(username: u);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Kullanıcı adı güncellendi')),
    );
  }

  Future<void> _pickAvatar() async {
    try {
      final img = await _picker
          .pickImage(
            source: ImageSource.gallery,
            imageQuality: 90,
            requestFullMetadata: false,
            maxWidth: 1440,
          )
          .timeout(const Duration(seconds: 25));
      if (img == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAvatarPath, img.path);
      if (!mounted) return;
      setState(() => _avatarPath = img.path);
    } on TimeoutException {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Galeri yanıt vermedi, tekrar deneyin.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Fotoğraf seçilemedi: $e')),
      );
    }
  }

  Future<void> _clearAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kAvatarPath);
    if (!mounted) return;
    setState(() => _avatarPath = '');
  }

  Widget _avatar() {
    if (_avatarPath.isNotEmpty) {
      final f = File(_avatarPath);
      if (f.existsSync()) {
        return CircleAvatar(radius: 34, backgroundImage: FileImage(f));
      }
    }
    return const CircleAvatar(
      radius: 34,
      backgroundColor: Color(0xFFE53935),
      child: Icon(Icons.person, color: Colors.white, size: 28),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: const Text('Ayarlar'),
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
                              const Text('Profil Fotoğrafı', style: TextStyle(fontWeight: FontWeight.w700)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: _pickAvatar,
                                    icon: const Icon(Icons.photo_camera, size: 18),
                                    label: const Text('Seç'),
                                  ),
                                  if (_avatarPath.isNotEmpty)
                                    OutlinedButton.icon(
                                      onPressed: _clearAvatar,
                                      icon: const Icon(Icons.delete_outline, size: 18),
                                      label: const Text('Kaldır'),
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
                        const Text('Kullanıcı Adı', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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
                            child: const Text('Kaydet'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF121826),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Bildirimler', style: TextStyle(fontWeight: FontWeight.w700)),
                              SizedBox(height: 2),
                              Text('Uygulama bildirimleri', style: TextStyle(fontSize: 12, color: Colors.white70)),
                            ],
                          ),
                        ),
                        Transform.scale(
                          scale: 0.85,
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
                        const Text('Dil', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
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
                ],
              ),
      ),
    );
  }
}
