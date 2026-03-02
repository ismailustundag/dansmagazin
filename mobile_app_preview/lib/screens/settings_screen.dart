import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _kNotif = 'settings.notifications_enabled';
  static const _kLang = 'settings.language';
  static const _kAvatarPath = 'settings.avatar_path';

  final _picker = ImagePicker();
  bool _notificationsEnabled = true;
  String _language = 'tr';
  String _avatarPath = '';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = prefs.getBool(_kNotif) ?? true;
      _language = prefs.getString(_kLang) ?? 'tr';
      _avatarPath = prefs.getString(_kAvatarPath) ?? '';
      _loading = false;
    });
  }

  Future<void> _saveNotif(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotif, v);
    if (!mounted) return;
    setState(() => _notificationsEnabled = v);
  }

  Future<void> _saveLanguage(String v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLang, v);
    if (!mounted) return;
    setState(() => _language = v);
  }

  Future<void> _pickAvatar() async {
    final img = await _picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (img == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAvatarPath, img.path);
    if (!mounted) return;
    setState(() => _avatarPath = img.path);
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
        return CircleAvatar(radius: 36, backgroundImage: FileImage(f));
      }
    }
    return const CircleAvatar(
      radius: 36,
      backgroundColor: Color(0xFFE53935),
      child: Icon(Icons.person, color: Colors.white, size: 32),
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
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              ElevatedButton.icon(
                                onPressed: _pickAvatar,
                                icon: const Icon(Icons.photo_camera),
                                label: const Text('Profil Fotoğrafı Ekle'),
                              ),
                              if (_avatarPath.isNotEmpty)
                                OutlinedButton.icon(
                                  onPressed: _clearAvatar,
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Kaldır'),
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
                    child: SwitchListTile(
                      title: const Text('Bildirimler'),
                      subtitle: const Text('Bildirimleri aç/kapat'),
                      value: _notificationsEnabled,
                      onChanged: _saveNotif,
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
                        const Text(
                          'Dil',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String>(
                          value: _language,
                          items: const [
                            DropdownMenuItem(value: 'tr', child: Text('Türkçe')),
                            DropdownMenuItem(value: 'en', child: Text('English')),
                          ],
                          onChanged: (v) {
                            if (v != null) _saveLanguage(v);
                          },
                          decoration: const InputDecoration(
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
