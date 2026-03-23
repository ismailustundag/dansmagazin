import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/store_api.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';

class StoreManagementScreen extends StatefulWidget {
  final String sessionToken;

  const StoreManagementScreen({
    super.key,
    required this.sessionToken,
  });

  @override
  State<StoreManagementScreen> createState() => _StoreManagementScreenState();
}

class _StoreManagementScreenState extends State<StoreManagementScreen> {
  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _picker = ImagePicker();

  List<StoreProductItem> _items = const [];
  bool _loading = true;
  bool _saving = false;
  String _error = '';
  String _selectedImagePath = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final items = await StoreApi.myProducts(widget.sessionToken);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _pickImage() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 82,
      maxWidth: 1600,
      maxHeight: 1600,
    );
    if (file == null || !mounted) return;
    setState(() => _selectedImagePath = file.path);
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    final description = _descriptionCtrl.text.trim();
    final price = _priceCtrl.text.trim();
    if (title.length < 2 || description.length < 3 || price.isEmpty || _selectedImagePath.isEmpty) {
      setState(() => _error = 'Ürün adı, fotoğraf, açıklama ve fiyat zorunlu.');
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await StoreApi.createProduct(
        sessionToken: widget.sessionToken,
        title: title,
        description: description,
        price: price,
        imagePath: _selectedImagePath,
      );
      _titleCtrl.clear();
      _descriptionCtrl.clear();
      _priceCtrl.clear();
      if (!mounted) return;
      setState(() => _selectedImagePath = '');
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ürün mağazana eklendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        title: const Text('Mağazamı Yönet'),
        backgroundColor: const Color(0xFF0F172A),
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(parent: ClampingScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: AppTheme.panel(tone: AppTone.info, radius: 24, elevated: true),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Yeni Ürün',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 12),
                  _Field(
                    controller: _titleCtrl,
                    label: 'Ürün adı',
                    hint: 'Örn. Dans ayakkabısı',
                  ),
                  const SizedBox(height: 10),
                  _Field(
                    controller: _descriptionCtrl,
                    label: 'Ürün açıklaması',
                    hint: 'Ürünü kısa ve net anlat.',
                    minLines: 4,
                    maxLines: 6,
                  ),
                  const SizedBox(height: 10),
                  _Field(
                    controller: _priceCtrl,
                    label: 'Fiyat',
                    hint: 'Örn. 1500',
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _pickImage,
                    icon: const Icon(Icons.add_a_photo_outlined),
                    label: Text(_selectedImagePath.isEmpty ? 'Ürün Fotoğrafı Seç' : 'Fotoğrafı Değiştir'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withOpacity(0.18)),
                      minimumSize: const Size.fromHeight(48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                  if (_selectedImagePath.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: Image.file(
                        File(_selectedImagePath),
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ],
                  if (_error.trim().isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      _error,
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 14),
                  ElevatedButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: const Icon(Icons.storefront_outlined),
                    label: Text(_saving ? 'Kaydediliyor...' : 'Ürünü Yayınla'),
                    style: ElevatedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      backgroundColor: AppTheme.cyan,
                      foregroundColor: const Color(0xFF06111F),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                      textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Mevcut Ürünlerim',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_items.isEmpty)
              Container(
                padding: const EdgeInsets.all(18),
                decoration: AppTheme.panel(tone: AppTone.neutral, radius: 22, elevated: true),
                child: const Text(
                  'Henüz ürün eklemedin. İlk ürününü yukarıdaki formdan oluşturabilirsin.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.4),
                ),
              )
            else
              for (final item in _items)
                Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(12),
                  decoration: AppTheme.panel(tone: AppTone.neutral, radius: 22, elevated: true),
                  child: Row(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: SizedBox(
                          width: 76,
                          height: 76,
                          child: item.imageUrl.trim().isNotEmpty
                              ? Image.network(item.imageUrl.trim(), fit: BoxFit.cover)
                              : Container(
                                  color: const Color(0xFF112038),
                                  alignment: Alignment.center,
                                  child: const Icon(Icons.shopping_bag_outlined, color: Colors.white38),
                                ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            EmojiText(
                              item.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              item.formattedPrice,
                              style: const TextStyle(color: AppTheme.cyan, fontSize: 13, fontWeight: FontWeight.w800),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              children: [
                                VerifiedAvatar(
                                  imageUrl: item.seller.avatarUrl,
                                  label: item.seller.name,
                                  isVerified: item.seller.isVerified,
                                  radius: 14,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: VerifiedNameText(
                                    item.seller.name,
                                    isVerified: item.seller.isVerified,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                          ],
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

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final int minLines;
  final int maxLines;
  final TextInputType? keyboardType;

  const _Field({
    required this.controller,
    required this.label,
    required this.hint,
    this.minLines = 1,
    this.maxLines = 1,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      minLines: minLines,
      maxLines: maxLines,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
      ),
    );
  }
}
