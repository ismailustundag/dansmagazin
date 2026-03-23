import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/store_api.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';

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
  final _storeTitleCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _descriptionCtrl = TextEditingController();
  final _priceCtrl = TextEditingController();
  final _picker = ImagePicker();

  List<StoreProductItem> _items = const [];
  bool _loading = true;
  bool _saving = false;
  bool _storeSaving = false;
  String _storeError = '';
  String _productError = '';
  String _selectedImagePath = '';
  String _effectiveStoreTitle = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _storeTitleCtrl.dispose();
    _titleCtrl.dispose();
    _descriptionCtrl.dispose();
    _priceCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _storeError = '';
      _productError = '';
    });
    try {
      final results = await Future.wait<dynamic>([
        StoreApi.mySettings(widget.sessionToken),
        StoreApi.myProducts(widget.sessionToken),
      ]);
      final settings = results[0] as StoreSettings;
      final items = results[1] as List<StoreProductItem>;
      if (!mounted) return;
      setState(() {
        _storeTitleCtrl.text = settings.storeTitle;
        _effectiveStoreTitle = settings.effectiveStoreTitle;
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _productError = e.toString();
      });
    }
  }

  Future<void> _saveStoreTitle() async {
    final value = _storeTitleCtrl.text.trim();
    if (value.isNotEmpty && value.length < 2) {
      setState(() => _storeError = 'Mağaza adı en az 2 karakter olmalı.');
      return;
    }
    setState(() {
      _storeSaving = true;
      _storeError = '';
    });
    try {
      final settings = await StoreApi.updateMySettings(
        sessionToken: widget.sessionToken,
        storeTitle: value,
      );
      if (!mounted) return;
      setState(() {
        _storeTitleCtrl.text = settings.storeTitle;
        _effectiveStoreTitle = settings.effectiveStoreTitle;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mağaza adı güncellendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _storeError = e.toString());
    } finally {
      if (mounted) setState(() => _storeSaving = false);
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

  Future<void> _saveProduct() async {
    final title = _titleCtrl.text.trim();
    final description = _descriptionCtrl.text.trim();
    final price = _priceCtrl.text.trim();
    if (title.length < 2 || description.length < 3 || price.isEmpty || _selectedImagePath.isEmpty) {
      setState(() => _productError = 'Ürün adı, fotoğraf, açıklama ve fiyat zorunlu.');
      return;
    }
    setState(() {
      _saving = true;
      _productError = '';
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
      setState(() => _productError = e.toString());
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
            _StoreTitleCard(
              controller: _storeTitleCtrl,
              effectiveStoreTitle: _effectiveStoreTitle,
              saving: _storeSaving,
              error: _storeError,
              onSave: _saveStoreTitle,
            ),
            const SizedBox(height: 16),
            _NewProductCard(
              titleCtrl: _titleCtrl,
              descriptionCtrl: _descriptionCtrl,
              priceCtrl: _priceCtrl,
              saving: _saving,
              error: _productError,
              selectedImagePath: _selectedImagePath,
              onPickImage: _pickImage,
              onSave: _saveProduct,
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
              for (final item in _items) _MyProductCard(item: item),
          ],
        ),
      ),
    );
  }
}

class _StoreTitleCard extends StatelessWidget {
  final TextEditingController controller;
  final String effectiveStoreTitle;
  final bool saving;
  final String error;
  final VoidCallback onSave;

  const _StoreTitleCard({
    required this.controller,
    required this.effectiveStoreTitle,
    required this.saving,
    required this.error,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.profile, radius: 24, elevated: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mağaza Adı',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            effectiveStoreTitle.trim().isEmpty
                ? 'Kartlarda varsayılan mağaza adı görünür.'
                : 'Kartlarda görünen ad: $effectiveStoreTitle',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 12),
          _Field(
            controller: controller,
            label: 'Mağaza adı',
            hint: 'Örn. İsmail Dans Butik',
          ),
          if (error.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              error,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: saving ? null : onSave,
            icon: const Icon(Icons.edit_outlined),
            label: Text(saving ? 'Kaydediliyor...' : 'Mağaza Adını Kaydet'),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.white,
              foregroundColor: const Color(0xFF08101E),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _NewProductCard extends StatelessWidget {
  final TextEditingController titleCtrl;
  final TextEditingController descriptionCtrl;
  final TextEditingController priceCtrl;
  final bool saving;
  final String error;
  final String selectedImagePath;
  final VoidCallback onPickImage;
  final VoidCallback onSave;

  const _NewProductCard({
    required this.titleCtrl,
    required this.descriptionCtrl,
    required this.priceCtrl,
    required this.saving,
    required this.error,
    required this.selectedImagePath,
    required this.onPickImage,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.profile, radius: 24, elevated: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Yeni Ürün',
            style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          _Field(
            controller: titleCtrl,
            label: 'Ürün adı',
            hint: 'Örn. Dans ayakkabısı',
          ),
          const SizedBox(height: 10),
          _Field(
            controller: descriptionCtrl,
            label: 'Ürün açıklaması',
            hint: 'Ürünü kısa ve net anlat.',
            minLines: 4,
            maxLines: 6,
          ),
          const SizedBox(height: 10),
          _Field(
            controller: priceCtrl,
            label: 'Fiyat',
            hint: 'Orn. 1500',
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: saving ? null : onPickImage,
            icon: const Icon(Icons.add_a_photo_outlined),
            label: Text(selectedImagePath.isEmpty ? 'Ürün Fotoğrafı Seç' : 'Fotoğrafı Değiştir'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: BorderSide(color: Colors.white.withOpacity(0.18)),
              minimumSize: const Size.fromHeight(48),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
          if (selectedImagePath.isNotEmpty) ...[
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Image.file(
                File(selectedImagePath),
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
              ),
            ),
          ],
          if (error.trim().isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              error,
              style: const TextStyle(color: Colors.redAccent, fontSize: 12),
            ),
          ],
          const SizedBox(height: 14),
          ElevatedButton.icon(
            onPressed: saving ? null : onSave,
            icon: const Icon(Icons.storefront_outlined),
            label: Text(saving ? 'Kaydediliyor...' : 'Ürünü Yayınla'),
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
    );
  }
}

class _MyProductCard extends StatelessWidget {
  final StoreProductItem item;

  const _MyProductCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
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
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StatusChip(
                      label: item.isSold ? 'Satıldı' : 'Yayında',
                      color: item.isSold ? const Color(0xFFFFC857) : AppTheme.cyan,
                      textColor: item.isSold ? const Color(0xFF3A2A00) : const Color(0xFF062033),
                    ),
                    if (!item.isPubliclyVisible && !item.isSold)
                      const _StatusChip(
                        label: 'Gizli',
                        color: Color(0xFF2A3347),
                        textColor: Colors.white70,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color textColor;

  const _StatusChip({
    required this.label,
    required this.color,
    required this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w800,
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
