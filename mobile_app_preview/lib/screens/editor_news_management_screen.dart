import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/error_message.dart';
import '../theme/app_theme.dart';

class EditorNewsCreateScreen extends StatefulWidget {
  final String sessionToken;

  const EditorNewsCreateScreen({super.key, required this.sessionToken});

  @override
  State<EditorNewsCreateScreen> createState() => _EditorNewsCreateScreenState();
}

class _EditorNewsCreateScreenState extends State<EditorNewsCreateScreen> {
  static const String _base = 'https://api2.dansmagazin.net';

  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  final _sourceCtrl = TextEditingController();

  XFile? _coverFile;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _sourceCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickCover() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 2000,
    );
    if (!mounted || picked == null) return;
    setState(() => _coverFile = picked);
  }

  String _errorFromBody(String body, int status) {
    return parseApiErrorBody(body, fallback: 'İşlem başarısız ($status)');
  }

  Future<void> _submit() async {
    final title = _titleCtrl.text.trim();
    final bodyText = _bodyCtrl.text.trim();
    if (title.length < 3) {
      setState(() => _error = 'Haber başlığı en az 3 karakter olmalı.');
      return;
    }
    if (bodyText.length < 10) {
      setState(() => _error = 'Haber metni en az 10 karakter olmalı.');
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final req = http.MultipartRequest('POST', Uri.parse('$_base/news/submissions'))
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['title'] = title
        ..fields['body_text'] = bodyText
        ..fields['source_link'] = _sourceCtrl.text.trim();
      if (_coverFile != null) {
        req.files.add(await http.MultipartFile.fromPath('cover_image', _coverFile!.path));
      }

      final res = await req.send();
      final raw = await res.stream.bytesToString();
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() => _error = _errorFromBody(raw, res.statusCode));
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Haber talebi onaya gönderildi.')),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Bağlantı hatası: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Haber Oluştur')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _txt(_titleCtrl, 'Haber Başlığı'),
            _txt(_bodyCtrl, 'Haber Metni', maxLines: 8),
            _txt(
              _sourceCtrl,
              'Kaynak Linki (opsiyonel)',
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _pickCover,
                    icon: const Icon(Icons.image_outlined),
                    label: const Text('Haber Görseli Seç'),
                  ),
                ),
              ],
            ),
            if (_coverFile != null) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(File(_coverFile!.path), height: 180, fit: BoxFit.cover),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: const TextStyle(color: Colors.redAccent)),
            ],
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_outlined),
                label: Text(_saving ? 'Gönderiliyor...' : 'Onaya Gönder'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _txt(
    TextEditingController c,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: const Color(0xFF111827),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }
}

class ManageNewsScreen extends StatefulWidget {
  final String sessionToken;

  const ManageNewsScreen({super.key, required this.sessionToken});

  @override
  State<ManageNewsScreen> createState() => _ManageNewsScreenState();
}

class _ManageNewsScreenState extends State<ManageNewsScreen> {
  static const String _base = 'https://api2.dansmagazin.net';

  late Future<_ManageNewsPayload> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<_ManageNewsPayload> _fetch() async {
    final r = await http.get(
      Uri.parse('$_base/news/manage/items'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken}'},
    );
    if (r.statusCode != 200) {
      throw Exception('Haber listesi alınamadı (${r.statusCode})');
    }
    final map = jsonDecode(r.body) as Map<String, dynamic>;
    final items = (map['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(_ManagedNewsItem.fromJson)
        .toList();
    final isSuperAdmin = map['is_super_admin'] == true;
    return _ManageNewsPayload(items: items, isSuperAdmin: isSuperAdmin);
  }

  Future<void> _refresh() async {
    final f = _fetch();
    setState(() => _future = f);
    await f;
  }

  Future<void> _openEdit(_ManagedNewsItem item, bool isSuperAdmin) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          backgroundColor: AppTheme.bgPrimary,
          appBar: AppBar(
            backgroundColor: AppTheme.bgPrimary,
            title: const Text('Haberi Yönet'),
          ),
          body: SafeArea(
            top: false,
            child: _EditNewsSubmissionSheet(
              sessionToken: widget.sessionToken,
              item: item,
              isSuperAdmin: isSuperAdmin,
            ),
          ),
        ),
      ),
    );
    if (changed == true && mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Haberleri Yönet'),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<_ManageNewsPayload>(
            future: _future,
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError) {
                return ListView(
                  children: [
                    const SizedBox(height: 56),
                    Center(
                      child: TextButton(
                        onPressed: _refresh,
                        child: const Text('Haberler alınamadı, tekrar dene'),
                      ),
                    ),
                  ],
                );
              }

              final data = snap.data ?? const _ManageNewsPayload(items: [], isSuperAdmin: false);
              if (data.items.isEmpty) {
                return ListView(
                  children: const [
                    SizedBox(height: 56),
                    Center(child: Text('Henüz haber talebi yok.')),
                  ],
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: data.items.length,
                itemBuilder: (_, i) {
                  final item = data.items[i];
                  return InkWell(
                    onTap: () => _openEdit(item, data.isSuperAdmin),
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      padding: const EdgeInsets.all(14),
                      decoration: AppTheme.panel(tone: AppTone.admin, radius: 18, subtle: true),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (item.coverUrl.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Image.network(
                                item.coverUrl,
                                width: 72,
                                height: 54,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _coverFallback(),
                              ),
                            )
                          else
                            _coverFallback(),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  item.submitterName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12.5),
                                ),
                                const SizedBox(height: 6),
                                _statusChip(item.status),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _coverFallback() {
    return Container(
      width: 72,
      height: 54,
      decoration: BoxDecoration(
        color: AppTheme.surfacePrimary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.image_not_supported_outlined, color: AppTheme.textSecondary),
    );
  }

  Widget _statusChip(String raw) {
    final s = raw.trim().toLowerCase();
    final color = switch (s) {
      'approved' => const Color(0xFF1E7D44),
      'rejected' => const Color(0xFF8B1C1C),
      _ => const Color(0xFF7A5D00),
    };
    final text = switch (s) {
      'approved' => 'Onaylandı',
      'rejected' => 'Reddedildi',
      _ => 'Onay Bekliyor',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }
}

class _ManageNewsPayload {
  final List<_ManagedNewsItem> items;
  final bool isSuperAdmin;

  const _ManageNewsPayload({required this.items, required this.isSuperAdmin});
}

class _ManagedNewsItem {
  final int submissionId;
  final String title;
  final String bodyText;
  final String sourceLink;
  final String coverUrl;
  final String status;
  final String submitterName;
  final String adminNote;
  final String wpPostUrl;

  const _ManagedNewsItem({
    required this.submissionId,
    required this.title,
    required this.bodyText,
    required this.sourceLink,
    required this.coverUrl,
    required this.status,
    required this.submitterName,
    required this.adminNote,
    required this.wpPostUrl,
  });

  factory _ManagedNewsItem.fromJson(Map<String, dynamic> j) {
    return _ManagedNewsItem(
      submissionId: (j['submission_id'] as num?)?.toInt() ?? 0,
      title: (j['title'] ?? '').toString(),
      bodyText: (j['body_text'] ?? '').toString(),
      sourceLink: (j['source_link'] ?? '').toString(),
      coverUrl: (j['cover_url'] ?? '').toString(),
      status: (j['status'] ?? '').toString(),
      submitterName: (j['submitter_name'] ?? '').toString(),
      adminNote: (j['admin_note'] ?? '').toString(),
      wpPostUrl: (j['wp_post_url'] ?? '').toString(),
    );
  }
}

class _EditNewsSubmissionSheet extends StatefulWidget {
  final String sessionToken;
  final _ManagedNewsItem item;
  final bool isSuperAdmin;

  const _EditNewsSubmissionSheet({
    required this.sessionToken,
    required this.item,
    required this.isSuperAdmin,
  });

  @override
  State<_EditNewsSubmissionSheet> createState() => _EditNewsSubmissionSheetState();
}

class _EditNewsSubmissionSheetState extends State<_EditNewsSubmissionSheet> {
  static const String _base = 'https://api2.dansmagazin.net';

  late final TextEditingController _titleCtrl;
  late final TextEditingController _bodyCtrl;
  late final TextEditingController _sourceCtrl;
  final _adminNoteCtrl = TextEditingController();

  XFile? _coverFile;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _titleCtrl = TextEditingController(text: widget.item.title);
    _bodyCtrl = TextEditingController(text: widget.item.bodyText);
    _sourceCtrl = TextEditingController(text: widget.item.sourceLink);
    _adminNoteCtrl.text = widget.item.adminNote;
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _sourceCtrl.dispose();
    _adminNoteCtrl.dispose();
    super.dispose();
  }

  String _errorFromBody(String body, int status) {
    return parseApiErrorBody(body, fallback: 'İşlem başarısız ($status)');
  }

  Future<void> _pickCover() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 2000,
    );
    if (!mounted || picked == null) return;
    setState(() => _coverFile = picked);
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/news/manage/items/${widget.item.submissionId}/update'),
      )
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['title'] = _titleCtrl.text.trim()
        ..fields['body_text'] = _bodyCtrl.text.trim()
        ..fields['source_link'] = _sourceCtrl.text.trim();

      if (_coverFile != null) {
        req.files.add(await http.MultipartFile.fromPath('cover_image', _coverFile!.path));
      }

      final res = await req.send();
      final raw = await res.stream.bytesToString();
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() => _error = _errorFromBody(raw, res.statusCode));
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Kaydetme hatası: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _moderate(String action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/news/manage/items/${widget.item.submissionId}/$action'),
      )
        ..headers['Authorization'] = 'Bearer ${widget.sessionToken}'
        ..fields['admin_note'] = _adminNoteCtrl.text.trim();

      final res = await req.send();
      final raw = await res.stream.bytesToString();
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() => _error = _errorFromBody(raw, res.statusCode));
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'İşlem hatası: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteSubmission() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Haberi Sil'),
        content: const Text(
          'Bu haber kaydı uygulamadan silinecek. WP’de yayınlandıysa oradan da kalıcı olarak kaldırılacak. Devam edilsin mi?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final req = http.MultipartRequest(
        'POST',
        Uri.parse('$_base/news/manage/items/${widget.item.submissionId}/delete'),
      )..headers['Authorization'] = 'Bearer ${widget.sessionToken}';
      final res = await req.send();
      final raw = await res.stream.bytesToString();
      if (!mounted) return;
      if (res.statusCode != 200) {
        setState(() => _error = _errorFromBody(raw, res.statusCode));
        return;
      }
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Silme hatası: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openWpPost() async {
    final url = widget.item.wpPostUrl.trim();
    if (url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom),
      child: ListView(
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.panel(tone: AppTone.admin, radius: 20, elevated: true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.item.submitterName.trim().isEmpty ? 'Gönderen bilgisi yok' : widget.item.submitterName,
                  style: const TextStyle(fontSize: 13.5, color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: _statusChip(widget.item.status)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _section(
            'İçerik',
            [
              _txt(_titleCtrl, 'Haber Başlığı'),
              _txt(_bodyCtrl, 'Haber Metni', maxLines: 8),
              _txt(
                _sourceCtrl,
                'Kaynak Linki (opsiyonel)',
                keyboardType: TextInputType.url,
              ),
            ],
          ),
          _section(
            'Görsel ve Yayın',
            [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _saving ? null : _pickCover,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('Görsel Değiştir'),
                    ),
                  ),
                ],
              ),
              if (_coverFile != null) ...[
                const SizedBox(height: 10),
                _coverPreview(Image.file(File(_coverFile!.path), height: 180, fit: BoxFit.cover)),
              ] else if (widget.item.coverUrl.isNotEmpty) ...[
                const SizedBox(height: 10),
                _coverPreview(
                  Image.network(
                    widget.item.coverUrl,
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                ),
              ],
              if (widget.item.wpPostUrl.trim().isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextButton.icon(
                    onPressed: _openWpPost,
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('WP Yayınını Aç'),
                  ),
                ),
            ],
          ),
          if (widget.isSuperAdmin)
            _section(
              'Moderasyon',
              [
                _txt(_adminNoteCtrl, 'Admin Notu', maxLines: 2),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving ? null : () => _moderate('reject'),
                        style: OutlinedButton.styleFrom(foregroundColor: Colors.redAccent),
                        child: const Text('Reddet'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _saving ? null : () => _moderate('approve'),
                        child: const Text('Onayla ve WP’de Yayınla'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Değişiklikleri Kaydet'),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _deleteSubmission,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.redAccent,
              ),
              icon: const Icon(Icons.delete_forever_outlined),
              label: const Text('Haberi Sil'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _txt(
    TextEditingController c,
    String label, {
    int maxLines = 1,
    TextInputType? keyboardType,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        maxLines: maxLines,
        keyboardType: keyboardType ?? (maxLines > 1 ? TextInputType.multiline : TextInputType.text),
        textInputAction: maxLines > 1 ? TextInputAction.newline : TextInputAction.next,
        enableInteractiveSelection: true,
        decoration: _fieldDecoration(label),
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.admin, radius: 20, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _coverPreview(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: child,
    );
  }

  Widget _statusChip(String raw) {
    final s = raw.trim().toLowerCase();
    final color = switch (s) {
      'approved' => const Color(0xFF1E7D44),
      'rejected' => const Color(0xFF8B1C1C),
      _ => const Color(0xFF7A5D00),
    };
    final text = switch (s) {
      'approved' => 'Onaylandı',
      'rejected' => 'Reddedildi',
      _ => 'Onay Bekliyor',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999)),
      child: Text(text, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }

  InputDecoration _fieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      filled: true,
      fillColor: AppTheme.surfacePrimary,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.borderSoft),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: AppTheme.cyan.withOpacity(0.8)),
      ),
    );
  }
}
