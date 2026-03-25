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
  String _selectedStoreLogoPath = '';
  String _effectiveStoreTitle = '';
  String _storeLogoUrl = '';
  final Set<int> _busyProductIds = <int>{};

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
        _storeLogoUrl = settings.storeLogoUrl;
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

  Future<void> _saveStoreProfile() async {
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
      var settings = await StoreApi.updateMySettings(
        sessionToken: widget.sessionToken,
        storeTitle: value,
      );
      if (_selectedStoreLogoPath.trim().isNotEmpty) {
        settings = await StoreApi.uploadMyLogo(
          sessionToken: widget.sessionToken,
          imagePath: _selectedStoreLogoPath,
        );
      }
      if (!mounted) return;
      setState(() {
        _storeTitleCtrl.text = settings.storeTitle;
        _effectiveStoreTitle = settings.effectiveStoreTitle;
        _storeLogoUrl = settings.storeLogoUrl;
        _selectedStoreLogoPath = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mağaza bilgileri güncellendi.')),
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

  Future<void> _pickStoreLogo() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 84,
      maxWidth: 1200,
      maxHeight: 1200,
    );
    if (file == null || !mounted) return;
    setState(() => _selectedStoreLogoPath = file.path);
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

  Future<void> _runBusyProductAction(int productId, Future<void> Function() action) async {
    if (_busyProductIds.contains(productId)) return;
    setState(() {
      _busyProductIds.add(productId);
      _productError = '';
    });
    try {
      await action();
    } catch (e) {
      if (!mounted) return;
      setState(() => _productError = e.toString());
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _busyProductIds.remove(productId));
      }
    }
  }

  Future<void> _toggleSold(StoreProductItem item) async {
    await _runBusyProductAction(item.id, () async {
      await StoreApi.updateProductSoldStatus(
        sessionToken: widget.sessionToken,
        productId: item.id,
        isSold: !item.isSold,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(item.isSold ? 'Ürün tekrar yayına alındı.' : 'Ürün satıldı olarak işaretlendi.'),
        ),
      );
    });
  }

  Future<void> _deleteProduct(StoreProductItem item) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: const Color(0xFF111826),
            title: const Text('Ürünü Sil'),
            content: Text(
              '"${item.title}" ürününü silmek istediğine emin misin?',
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Vazgeç'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
                child: const Text('Sil'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    await _runBusyProductAction(item.id, () async {
      await StoreApi.deleteProduct(
        sessionToken: widget.sessionToken,
        productId: item.id,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ürün silindi.')),
      );
    });
  }

  Future<void> _editProduct(StoreProductItem item) async {
    final titleCtrl = TextEditingController(text: item.title);
    final descriptionCtrl = TextEditingController(text: item.description);
    final priceCtrl = TextEditingController(text: item.price);
    var selectedImagePath = '';
    var saving = false;
    var error = '';

    try {
      final updated = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF0B1220),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        builder: (context) {
          return StatefulBuilder(
            builder: (context, setModalState) {
              Future<void> pickImage() async {
                final file = await _picker.pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 82,
                  maxWidth: 1600,
                  maxHeight: 1600,
                );
                if (file == null) return;
                setModalState(() => selectedImagePath = file.path);
              }

              Future<void> submit() async {
                final title = titleCtrl.text.trim();
                final description = descriptionCtrl.text.trim();
                final price = priceCtrl.text.trim();
                if (title.length < 2 || description.length < 3 || price.isEmpty) {
                  setModalState(() => error = 'Ürün adı, açıklama ve fiyat zorunlu.');
                  return;
                }
                setModalState(() {
                  saving = true;
                  error = '';
                });
                try {
                  await StoreApi.updateProduct(
                    sessionToken: widget.sessionToken,
                    productId: item.id,
                    title: title,
                    description: description,
                    price: price,
                    imagePath: selectedImagePath.isEmpty ? null : selectedImagePath,
                  );
                  if (!context.mounted) return;
                  Navigator.of(context).pop(true);
                } catch (e) {
                  setModalState(() => error = e.toString());
                } finally {
                  if (context.mounted) {
                    setModalState(() => saving = false);
                  }
                }
              }

              return Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Ürünü Düzenle',
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
                        hint: 'Örn. 1500',
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton.icon(
                        onPressed: saving ? null : pickImage,
                        icon: const Icon(Icons.add_a_photo_outlined),
                        label: Text(selectedImagePath.isEmpty ? 'Yeni Fotoğraf Seç' : 'Fotoğrafı Değiştir'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: Colors.white.withOpacity(0.18)),
                          minimumSize: const Size.fromHeight(48),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: selectedImagePath.isNotEmpty
                            ? Image.file(
                                File(selectedImagePath),
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                              )
                            : item.imageUrl.trim().isNotEmpty
                                ? Image.network(
                                    item.imageUrl.trim(),
                                    height: 180,
                                    width: double.infinity,
                                    fit: BoxFit.cover,
                                  )
                                : Container(
                                    height: 180,
                                    color: const Color(0xFF112038),
                                    alignment: Alignment.center,
                                    child: const Icon(Icons.shopping_bag_outlined, color: Colors.white38, size: 30),
                                  ),
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
                        onPressed: saving ? null : submit,
                        icon: const Icon(Icons.save_outlined),
                        label: Text(saving ? 'Kaydediliyor...' : 'Değişiklikleri Kaydet'),
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
              );
            },
          );
        },
      );

      if (updated == true) {
        await _load();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ürün güncellendi.')),
        );
      }
    } finally {
      titleCtrl.dispose();
      descriptionCtrl.dispose();
      priceCtrl.dispose();
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
              currentLogoUrl: _storeLogoUrl,
              selectedLogoPath: _selectedStoreLogoPath,
              saving: _storeSaving,
              error: _storeError,
              onPickLogo: _pickStoreLogo,
              onSave: _saveStoreProfile,
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
              for (final item in _items)
                _MyProductCard(
                  item: item,
                  busy: _busyProductIds.contains(item.id),
                  onEdit: () => _editProduct(item),
                  onToggleSold: () => _toggleSold(item),
                  onDelete: () => _deleteProduct(item),
                ),
          ],
        ),
      ),
    );
  }
}

class _StoreTitleCard extends StatelessWidget {
  final TextEditingController controller;
  final String effectiveStoreTitle;
  final String currentLogoUrl;
  final String selectedLogoPath;
  final bool saving;
  final String error;
  final VoidCallback onPickLogo;
  final VoidCallback onSave;

  const _StoreTitleCard({
    required this.controller,
    required this.effectiveStoreTitle,
    required this.currentLogoUrl,
    required this.selectedLogoPath,
    required this.saving,
    required this.error,
    required this.onPickLogo,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    final displayLogo = selectedLogoPath.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.profile, radius: 24, elevated: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Mağaza Profili',
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
          const SizedBox(height: 14),
          const Text(
            'Mağaza Logosu',
            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          Center(
            child: Container(
              width: 112,
              height: 112,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24),
                color: const Color(0xFF0B1220),
                border: Border.all(color: AppTheme.borderSoft),
              ),
              child: displayLogo
                  ? Image.file(File(selectedLogoPath), fit: BoxFit.cover)
                  : currentLogoUrl.trim().isNotEmpty
                      ? Image.network(currentLogoUrl.trim(), fit: BoxFit.cover)
                      : const Center(
                          child: Icon(
                            Icons.storefront_rounded,
                            size: 40,
                            color: Colors.white54,
                          ),
                        ),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: saving ? null : onPickLogo,
            icon: const Icon(Icons.image_outlined),
            label: Text(displayLogo ? 'Logoyu Değiştir' : 'Logo Seç'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(46),
              foregroundColor: Colors.white,
              side: BorderSide(color: AppTheme.borderSoft),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
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
            icon: const Icon(Icons.save_outlined),
            label: Text(saving ? 'Kaydediliyor...' : 'Kaydet'),
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
  final bool busy;
  final VoidCallback onEdit;
  final VoidCallback onToggleSold;
  final VoidCallback onDelete;

  const _MyProductCard({
    required this.item,
    required this.busy,
    required this.onEdit,
    required this.onToggleSold,
    required this.onDelete,
  });

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
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: busy ? null : onEdit,
                      icon: const Icon(Icons.edit_outlined, size: 16),
                      label: const Text('Düzenle'),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : onToggleSold,
                      icon: Icon(item.isSold ? Icons.undo_rounded : Icons.check_circle_outline_rounded, size: 16),
                      label: Text(item.isSold ? 'Geri Al' : 'Satıldı'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: item.isSold ? Colors.white : const Color(0xFFFFC857),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: busy ? null : onDelete,
                      icon: const Icon(Icons.delete_outline_rounded, size: 16),
                      label: const Text('Sil'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.redAccent,
                      ),
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
