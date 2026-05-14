import 'package:flutter/material.dart';

import '../services/event_social_api.dart';
import '../services/guest_list_api.dart';
import '../theme/app_theme.dart';

class GuestListsScreen extends StatefulWidget {
  final String sessionToken;

  const GuestListsScreen({
    super.key,
    required this.sessionToken,
  });

  @override
  State<GuestListsScreen> createState() => _GuestListsScreenState();
}

class _GuestListsScreenState extends State<GuestListsScreen> {
  late Future<List<GuestListSummary>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<List<GuestListSummary>> _fetch() {
    return GuestListApi.listGuestLists(widget.sessionToken);
  }

  Future<void> _refresh() async {
    final future = _fetch();
    setState(() => _future = future);
    await future;
  }

  Future<void> _createList() async {
    final name = await _askForName(title: 'Yeni Davetli Listesi', initialValue: '');
    if (name == null || name.trim().isEmpty) return;
    try {
      await GuestListApi.createGuestList(
        sessionToken: widget.sessionToken,
        name: name,
      );
      if (!mounted) return;
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Davetli listesi oluşturuldu.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _renameList(GuestListSummary item) async {
    final name = await _askForName(
      title: 'Listeyi Yeniden Adlandır',
      initialValue: item.name,
    );
    if (name == null || name.trim().isEmpty || name.trim() == item.name.trim()) return;
    try {
      await GuestListApi.renameGuestList(
        sessionToken: widget.sessionToken,
        guestListId: item.guestListId,
        name: name,
      );
      if (!mounted) return;
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Liste adı güncellendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _deleteList(GuestListSummary item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Listeyi Sil'),
        content: Text('${item.name} listesini silmek istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await GuestListApi.deleteGuestList(
        sessionToken: widget.sessionToken,
        guestListId: item.guestListId,
      );
      if (!mounted) return;
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Davetli listesi silindi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _openDetail(GuestListSummary item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => GuestListDetailScreen(
          sessionToken: widget.sessionToken,
          guestListId: item.guestListId,
        ),
      ),
    );
    if (changed == true && mounted) {
      await _refresh();
    }
  }

  Future<String?> _askForName({
    required String title,
    required String initialValue,
  }) async {
    final ctrl = TextEditingController(text: initialValue);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(
            hintText: 'Ankara, İstanbul, Vişnelik...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Davetli Listeleri'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createList,
        icon: const Icon(Icons.playlist_add_rounded),
        label: const Text('Liste Oluştur'),
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: _refresh,
          child: FutureBuilder<List<GuestListSummary>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 80),
                    const Text(
                      'Davetli listeleri alınamadı.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 10),
                    Center(
                      child: TextButton(
                        onPressed: _refresh,
                        child: const Text('Tekrar Dene'),
                      ),
                    ),
                  ],
                );
              }
              final items = snapshot.data ?? const <GuestListSummary>[];
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: AppTheme.panel(
                      tone: AppTone.profile,
                      radius: 20,
                      elevated: true,
                    ),
                    child: const Text(
                      'Burada yöneticilere özel davetli listeleri oluşturabilirsiniz. Bir listeyi daha sonra etkinlik içinden elle aktararak sadece o etkinliğe davetli tanımlarsınız.',
                      style: TextStyle(height: 1.45),
                    ),
                  ),
                  const SizedBox(height: 14),
                  if (items.isEmpty)
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: AppTheme.panel(
                        tone: AppTone.profile,
                        radius: 18,
                        subtle: true,
                      ),
                      child: const Text(
                        'Henüz davetli listeniz yok. Sağ alttan ilk listenizi oluşturabilirsiniz.',
                        style: TextStyle(color: AppTheme.textSecondary),
                      ),
                    )
                  else
                    ...items.map(
                      (item) => Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        decoration: AppTheme.panel(
                          tone: AppTone.profile,
                          radius: 18,
                          subtle: true,
                        ),
                        child: ListTile(
                          onTap: () => _openDetail(item),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                          title: Text(
                            item.name,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              '${item.memberCount} kişi kayıtlı',
                              style: const TextStyle(color: AppTheme.textSecondary),
                            ),
                          ),
                          leading: Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: AppTheme.violet.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: const Icon(Icons.groups_rounded, color: AppTheme.violet),
                          ),
                          trailing: PopupMenuButton<String>(
                            onSelected: (value) {
                              if (value == 'rename') {
                                _renameList(item);
                              } else if (value == 'delete') {
                                _deleteList(item);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem<String>(
                                value: 'rename',
                                child: Text('Yeniden Adlandır'),
                              ),
                              PopupMenuItem<String>(
                                value: 'delete',
                                child: Text('Sil'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class GuestListDetailScreen extends StatefulWidget {
  final String sessionToken;
  final int guestListId;

  const GuestListDetailScreen({
    super.key,
    required this.sessionToken,
    required this.guestListId,
  });

  @override
  State<GuestListDetailScreen> createState() => _GuestListDetailScreenState();
}

class _GuestListDetailScreenState extends State<GuestListDetailScreen> {
  late Future<GuestListDetail> _future;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<GuestListDetail> _fetch() {
    return GuestListApi.guestListDetail(
      sessionToken: widget.sessionToken,
      guestListId: widget.guestListId,
    );
  }

  Future<void> _refresh() async {
    final future = _fetch();
    setState(() => _future = future);
    await future;
  }

  Future<void> _rename(GuestListDetail detail) async {
    final ctrl = TextEditingController(text: detail.summary.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Listeyi Yeniden Adlandır'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 80,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ctrl.text.trim()),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (name == null || name.trim().isEmpty || name.trim() == detail.summary.name.trim()) return;
    try {
      await GuestListApi.renameGuestList(
        sessionToken: widget.sessionToken,
        guestListId: widget.guestListId,
        name: name,
      );
      _changed = true;
      if (!mounted) return;
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Liste adı güncellendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _delete(GuestListDetail detail) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Listeyi Sil'),
        content: Text('${detail.summary.name} listesini silmek istiyor musunuz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await GuestListApi.deleteGuestList(
        sessionToken: widget.sessionToken,
        guestListId: widget.guestListId,
      );
      _changed = true;
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _addMember(GuestListDetail detail) async {
    final selected = await Navigator.of(context).push<SocialUserItem>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _GuestListMemberPickerScreen(
          sessionToken: widget.sessionToken,
          existingAccountIds: detail.members.map((member) => member.accountId).toSet(),
        ),
      ),
    );
    if (selected == null) return;
    try {
      await GuestListApi.addMember(
        sessionToken: widget.sessionToken,
        guestListId: widget.guestListId,
        accountId: selected.accountId,
      );
      _changed = true;
      if (!mounted) return;
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${selected.name} listeye eklendi.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  Future<void> _removeMember(GuestListMember member) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kullanıcıyı Çıkar'),
        content: Text('${member.name} bu listeden çıkarılsın mı?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Çıkar'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await GuestListApi.removeMember(
        sessionToken: widget.sessionToken,
        guestListId: widget.guestListId,
        accountId: member.accountId,
      );
      _changed = true;
      if (!mounted) return;
      await _refresh();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${member.name} listeden çıkarıldı.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        Navigator.of(context).pop(_changed);
        return false;
      },
      child: Scaffold(
        backgroundColor: AppTheme.bgPrimary,
        appBar: AppBar(
          backgroundColor: AppTheme.bgPrimary,
          title: const Text('Davetli Listesi'),
        ),
        floatingActionButton: FutureBuilder<GuestListDetail>(
          future: _future,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            return FloatingActionButton.extended(
              onPressed: () => _addMember(snapshot.data!),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Kullanıcı Ekle'),
            );
          },
        ),
        body: SafeArea(
          top: false,
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: FutureBuilder<GuestListDetail>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return ListView(
                    padding: const EdgeInsets.all(24),
                    children: [
                      const SizedBox(height: 80),
                      const Text(
                        'Liste detayları alınamadı.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: TextButton(
                          onPressed: _refresh,
                          child: const Text('Tekrar Dene'),
                        ),
                      ),
                    ],
                  );
                }
                final detail = snapshot.data!;
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: AppTheme.panel(
                        tone: AppTone.profile,
                        radius: 20,
                        elevated: true,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            detail.summary.name,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${detail.summary.memberCount} kişi kayıtlı',
                            style: const TextStyle(color: AppTheme.textSecondary),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => _rename(detail),
                                icon: const Icon(Icons.edit_rounded),
                                label: const Text('Adını Değiştir'),
                              ),
                              OutlinedButton.icon(
                                onPressed: () => _delete(detail),
                                icon: const Icon(Icons.delete_outline_rounded),
                                label: const Text('Listeyi Sil'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: AppTheme.panel(
                        tone: AppTone.profile,
                        radius: 18,
                        subtle: true,
                      ),
                      child: const Text(
                        'Bu listedeki kullanıcıları daha sonra etkinlik içinden içeri aktarabilirsiniz. Aktarım yapıldığında sadece o etkinlik için davetli olurlar.',
                        style: TextStyle(color: AppTheme.textSecondary, height: 1.45),
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (detail.members.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: AppTheme.panel(
                          tone: AppTone.profile,
                          radius: 18,
                          subtle: true,
                        ),
                        child: const Text(
                          'Bu listede henüz kullanıcı yok. Sağ alttan kullanıcı arayıp ekleyebilirsiniz.',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      )
                    else
                      ...detail.members.map(
                        (member) => Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          decoration: AppTheme.panel(
                            tone: AppTone.profile,
                            radius: 18,
                            subtle: true,
                          ),
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                            leading: _UserAvatar(
                              imageUrl: member.avatarUrl,
                              label: member.name,
                              isVerified: member.isVerified,
                            ),
                            title: Text(
                              member.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700),
                            ),
                            subtitle: Text(
                              member.email.isEmpty ? 'Kullanıcı kaydı' : member.email,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: AppTheme.textSecondary),
                            ),
                            trailing: IconButton(
                              onPressed: () => _removeMember(member),
                              icon: const Icon(Icons.remove_circle_outline_rounded),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _GuestListMemberPickerScreen extends StatefulWidget {
  final String sessionToken;
  final Set<int> existingAccountIds;

  const _GuestListMemberPickerScreen({
    required this.sessionToken,
    required this.existingAccountIds,
  });

  @override
  State<_GuestListMemberPickerScreen> createState() => _GuestListMemberPickerScreenState();
}

class _GuestListMemberPickerScreenState extends State<_GuestListMemberPickerScreen> {
  final TextEditingController _queryCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  int _minQueryLength = 2;
  List<SocialUserItem> _items = const <SocialUserItem>[];

  @override
  void dispose() {
    _queryCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryCtrl.text.trim();
    if (query.length < _minQueryLength) {
      setState(() {
        _error = 'En az $_minQueryLength karakter girin.';
        _items = const <SocialUserItem>[];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await EventSocialApi.searchUsers(
        sessionToken: widget.sessionToken,
        query: query,
        limit: 30,
      );
      if (!mounted) return;
      setState(() {
        _minQueryLength = result.minQueryLength;
        _items = result.items;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _items = const <SocialUserItem>[];
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Kullanıcı Seç'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextField(
              controller: _queryCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                hintText: 'Kullanıcı adı, ad veya e-posta ara',
                filled: true,
                fillColor: AppTheme.surfacePrimary,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                suffixIcon: IconButton(
                  onPressed: _loading ? null : _search,
                  icon: _loading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search_rounded),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: AppTheme.panel(
                tone: AppTone.profile,
                radius: 16,
                subtle: true,
              ),
              child: Text(
                'Arama sonucundaki kullanıcıya dokunduğunuzda listeye eklenecek. Zaten listede olanlar tekrar seçilemez.',
                style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(color: AppTheme.warning),
              ),
            ],
            const SizedBox(height: 14),
            if (_items.isEmpty && !_loading)
              const Text(
                'Henüz arama sonucu yok.',
                style: TextStyle(color: AppTheme.textSecondary),
              )
            else
              ..._items.map((item) {
                final alreadyAdded = widget.existingAccountIds.contains(item.accountId);
                return Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  decoration: AppTheme.panel(
                    tone: AppTone.profile,
                    radius: 18,
                    subtle: true,
                  ),
                  child: ListTile(
                    onTap: alreadyAdded ? null : () => Navigator.of(context).pop(item),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    leading: _UserAvatar(
                      imageUrl: item.avatarUrl,
                      label: item.name,
                      isVerified: item.isVerified,
                    ),
                    title: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      item.email,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: AppTheme.textSecondary),
                    ),
                    trailing: alreadyAdded
                        ? const Text(
                            'Ekli',
                            style: TextStyle(color: AppTheme.textSecondary, fontWeight: FontWeight.w700),
                          )
                        : const Icon(Icons.add_circle_outline_rounded),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}

class _UserAvatar extends StatelessWidget {
  final String imageUrl;
  final String label;
  final bool isVerified;

  const _UserAvatar({
    required this.imageUrl,
    required this.label,
    required this.isVerified,
  });

  @override
  Widget build(BuildContext context) {
    final initial = label.trim().isEmpty ? '?' : label.trim().substring(0, 1).toUpperCase();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        CircleAvatar(
          radius: 22,
          backgroundColor: AppTheme.surfaceSecondary,
          backgroundImage: imageUrl.trim().isNotEmpty ? NetworkImage(imageUrl.trim()) : null,
          child: imageUrl.trim().isNotEmpty
              ? null
              : Text(
                  initial,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
        ),
        if (isVerified)
          const Positioned(
            right: -2,
            bottom: -2,
            child: CircleAvatar(
              radius: 8,
              backgroundColor: AppTheme.bgPrimary,
              child: Icon(
                Icons.verified_rounded,
                size: 14,
                color: AppTheme.cyan,
              ),
            ),
          ),
      ],
    );
  }
}
