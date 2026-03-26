import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/event_social_api.dart';
import '../services/i18n.dart';
import '../services/profile_card_palette.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';
import 'chat_thread_screen.dart';

class FriendProfileScreen extends StatefulWidget {
  final String sessionToken;
  final int friendAccountId;

  const FriendProfileScreen({
    super.key,
    required this.sessionToken,
    required this.friendAccountId,
  });

  @override
  State<FriendProfileScreen> createState() => _FriendProfileScreenState();
}

class _FriendProfileScreenState extends State<FriendProfileScreen> {
  static const String _base = 'https://api2.dansmagazin.net';
  late Future<_FriendProfile> _future;
  bool _removing = false;
  bool _blocking = false;
  bool _reporting = false;
  bool _sendingRequest = false;
  bool _cancellingRequest = false;
  bool _acceptingRequest = false;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<_FriendProfile> _fetch() async {
    final resp = await http.get(
      Uri.parse('$_base/profile/friends/${widget.friendAccountId}'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Arkadaş profili alınamadı');
    }
    return _FriendProfile.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> _openChat(_FriendProfile profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatThreadScreen(
          sessionToken: widget.sessionToken,
          peerAccountId: profile.accountId,
          peerName: profile.name,
          peerAvatarUrl: profile.avatarUrl,
          peerIsVerified: profile.isVerified,
        ),
      ),
    );
  }

  Future<void> _sendFriendRequest(_FriendProfile profile) async {
    if (_sendingRequest) return;
    setState(() => _sendingRequest = true);
    try {
      final result = await EventSocialApi.sendFriendRequestDirect(
        sessionToken: widget.sessionToken,
        targetAccountId: profile.accountId,
      );
      if (!mounted) return;
      final status = (result['status'] ?? '').toString();
      if (status == 'already_friends') {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Zaten arkadaşsınız.')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Arkadaşlık isteği gönderildi.')),
        );
      }
      setState(() => _future = _fetch());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _sendingRequest = false);
    }
  }

  Future<void> _cancelFriendRequest(_FriendProfile profile) async {
    final requestId = profile.friendRequestId;
    if (_cancellingRequest || requestId == null || requestId <= 0) return;
    setState(() => _cancellingRequest = true);
    try {
      await EventSocialApi.cancelFriendRequest(
        sessionToken: widget.sessionToken,
        requestId: requestId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İstek geri çekildi.')),
      );
      setState(() => _future = _fetch());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _cancellingRequest = false);
    }
  }

  Future<void> _acceptFriendRequest(_FriendProfile profile) async {
    final requestId = profile.friendRequestId;
    if (_acceptingRequest || requestId == null || requestId <= 0) return;
    setState(() => _acceptingRequest = true);
    try {
      await EventSocialApi.acceptFriendRequest(
        sessionToken: widget.sessionToken,
        requestId: requestId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Arkadaşlık isteği kabul edildi.')),
      );
      setState(() => _future = _fetch());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) setState(() => _acceptingRequest = false);
    }
  }

  Future<void> _removeFriend(_FriendProfile profile) async {
    if (_removing) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.t('remove_friend')),
        content: Text(I18n.t('remove_friend_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(I18n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(I18n.t('remove_friend')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _removing = true);
    try {
      await EventSocialApi.removeFriend(
        sessionToken: widget.sessionToken,
        friendAccountId: profile.accountId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('friend_removed'))),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _removing = false);
      }
    }
  }

  Future<void> _blockUser(_FriendProfile profile) async {
    if (_blocking) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.t('block_user')),
        content: Text(I18n.t('block_user_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(I18n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(I18n.t('block_user')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _blocking = true);
    try {
      await EventSocialApi.blockUser(
        sessionToken: widget.sessionToken,
        targetAccountId: profile.accountId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('block_user_done'))),
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _blocking = false);
      }
    }
  }

  Future<void> _reportUser(_FriendProfile profile) async {
    if (_reporting) return;
    final noteCtrl = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.t('report_user_title')),
        content: TextField(
          controller: noteCtrl,
          maxLines: 4,
          decoration: InputDecoration(hintText: I18n.t('report_user_hint')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(I18n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(noteCtrl.text.trim()),
            child: Text(I18n.t('report_user')),
          ),
        ],
      ),
    );
    noteCtrl.dispose();
    if (reason == null) return;
    setState(() => _reporting = true);
    try {
      await EventSocialApi.reportUser(
        sessionToken: widget.sessionToken,
        targetAccountId: profile.accountId,
        reason: reason,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('report_user_done'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _reporting = false);
      }
    }
  }

  void _showAvatarPreview(String avatarUrl, String name) {
    final url = avatarUrl.trim();
    if (url.isEmpty) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => Container(
                    padding: const EdgeInsets.all(20),
                    color: const Color(0xFF111827),
                    child: Text(name.isEmpty ? 'Görsel açılamadı' : name),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 6,
              top: 6,
              child: IconButton(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openRelatedFriendProfile(_FriendListItem friend) async {
    if (friend.accountId <= 0 || friend.accountId == widget.friendAccountId) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(
          sessionToken: widget.sessionToken,
          friendAccountId: friend.accountId,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _future = _fetch());
  }

  void _showAllFriendsSheet(_FriendProfile profile) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF10172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        final friends = profile.friends;
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        I18n.t('all_friends_section'),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: Colors.white.withOpacity(0.10)),
                      ),
                      child: Text(
                        '${friends.length}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                if (friends.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      I18n.t('visible_friends_empty'),
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                else
                  SizedBox(
                    height: MediaQuery.of(sheetContext).size.height * 0.52,
                    child: GridView.builder(
                      padding: const EdgeInsets.only(bottom: 8),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 4,
                        mainAxisSpacing: 18,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.76,
                      ),
                      itemCount: friends.length,
                      itemBuilder: (context, index) {
                        final friend = friends[index];
                        return InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            Future<void>.delayed(const Duration(milliseconds: 120), () {
                              if (!mounted) return;
                              _openRelatedFriendProfile(friend);
                            });
                          },
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              VerifiedAvatar(
                                imageUrl: friend.avatarUrl,
                                label: friend.name,
                                isVerified: friend.isVerified,
                                radius: 28,
                                backgroundColor: Colors.white.withOpacity(0.08),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                friend.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  height: 1.2,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: Text(t('friend_profile')),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<_FriendProfile>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: TextButton(
                  onPressed: () => setState(() => _future = _fetch()),
                  child: Text(t('friend_profile_load_error')),
                ),
              );
            }
            final profile = snapshot.data!;
            return ListView(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.all(14),
              children: [
                _FriendProfileHeroCard(
                  profile: profile,
                  onPhotoTap: () => _showAvatarPreview(profile.avatarUrl, profile.name),
                ),
                const SizedBox(height: 14),
                if (profile.friendStatus == 'friend')
                  Row(
                    children: [
                      Expanded(
                        child: _ProfileActionButton(
                          label: t('send_message_short'),
                          icon: Icons.chat_bubble_outline_rounded,
                          onTap: () => _openChat(profile),
                          fillColor: const Color(0xFFF3DFC8),
                          foregroundColor: const Color(0xFF6A3107),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ProfileActionButton(
                          label: t('remove_short'),
                          icon: Icons.person_remove_outlined,
                          onTap: _removing ? null : () => _removeFriend(profile),
                          fillColor: const Color(0x26E58B8B),
                          foregroundColor: const Color(0xFFFFC2C2),
                          isLoading: _removing,
                        ),
                      ),
                    ],
                  )
                else if (profile.friendStatus == 'pending_outgoing')
                  _ProfileActionButton(
                    label: 'İsteği Geri Çek',
                    icon: Icons.undo_rounded,
                    onTap: _cancellingRequest ? null : () => _cancelFriendRequest(profile),
                    fillColor: const Color(0x14F59E0B),
                    foregroundColor: const Color(0xFFFFD98A),
                    isLoading: _cancellingRequest,
                  )
                else if (profile.friendStatus == 'pending_incoming')
                  _ProfileActionButton(
                    label: 'İsteği Kabul Et',
                    icon: Icons.person_add_alt_1_rounded,
                    onTap: _acceptingRequest ? null : () => _acceptFriendRequest(profile),
                    fillColor: const Color(0x1A22C55E),
                    foregroundColor: const Color(0xFFC6FFD7),
                    isLoading: _acceptingRequest,
                  )
                else
                  _ProfileActionButton(
                    label: 'Arkadaş Ekle',
                    icon: Icons.person_add_alt_1_rounded,
                    onTap: _sendingRequest ? null : () => _sendFriendRequest(profile),
                    fillColor: const Color(0x1A8B5CF6),
                    foregroundColor: const Color(0xFFE4DBFF),
                    isLoading: _sendingRequest,
                  ),
                const SizedBox(height: 12),
                _FriendConnectionsPreviewCard(
                  friends: profile.friends,
                  onTap: () => _showAllFriendsSheet(profile),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _MiniProfileActionButton(
                        label: t('report_user'),
                        icon: Icons.flag_outlined,
                        onTap: _reporting ? null : () => _reportUser(profile),
                        fillColor: const Color(0x1AFFC34D),
                        foregroundColor: const Color(0xFFFFD98A),
                        isLoading: _reporting,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _MiniProfileActionButton(
                        label: t('block_user'),
                        icon: Icons.block_rounded,
                        onTap: _blocking ? null : () => _blockUser(profile),
                        fillColor: const Color(0x18FF7C7C),
                        foregroundColor: const Color(0xFFFFB3B3),
                        isLoading: _blocking,
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _FriendProfileHeroCard extends StatelessWidget {
  final _FriendProfile profile;
  final VoidCallback onPhotoTap;

  const _FriendProfileHeroCard({
    required this.profile,
    required this.onPhotoTap,
  });

  List<String> _interestItems(String raw) {
    return raw
        .split(RegExp(r'[,;\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Widget _infoCell({
    required String title,
    required String value,
    required ProfileCardPalette palette,
    Widget? child,
  }) {
    final resolvedValue = value.trim().isEmpty ? I18n.t('not_added_yet') : value.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: palette.surfaceTint,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: Colors.white.withOpacity(0.74),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          child ??
              EmojiText(
                resolvedValue,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xFFFFF7F1),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
        ],
      ),
    );
  }

  Widget _profileVisual(ProfileCardPalette palette) {
    final child = profile.avatarUrl.trim().isNotEmpty
        ? InkWell(
            onTap: onPhotoTap,
            borderRadius: BorderRadius.circular(24),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: Image.network(
                profile.avatarUrl.trim(),
                width: double.infinity,
                height: 214,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallbackVisual(palette),
              ),
            ),
          )
        : _fallbackVisual(palette);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        if (profile.isVerified)
          const Positioned(
            right: 12,
            bottom: 12,
            child: VerifiedBadge(size: 28, emojiScale: 0.74),
          ),
      ],
    );
  }

  Widget _fallbackVisual(ProfileCardPalette palette) {
    return Container(
      width: double.infinity,
      height: 214,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.placeholderGradient,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        profile.initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 44,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    final nameText = profile.name.trim().toUpperCase();
    final palette = ProfileCardPalette.fromGender(profile.gender);
    final interestItems = _interestItems(profile.danceInterests);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.cardGradient,
        ),
        border: Border.all(color: const Color(0x22FFFFFF)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x20000000),
            blurRadius: 22,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _profileVisual(palette),
          const SizedBox(height: 12),
          VerifiedNameText(
            nameText,
            isVerified: profile.isVerified,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              height: 1.02,
            ),
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final cellWidth = (constraints.maxWidth - 10) / 2;
              return Wrap(
                spacing: 10,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: cellWidth,
                    child: _infoCell(
                      title: t('registration_date'),
                      value: profile.registeredAt,
                      palette: palette,
                    ),
                  ),
                  SizedBox(
                    width: cellWidth,
                    child: _infoCell(
                      title: t('profile_id'),
                      value: '${profile.accountId}',
                      palette: palette,
                    ),
                  ),
                  SizedBox(
                    width: constraints.maxWidth,
                    child: _infoCell(
                      title: t('dance_interests'),
                      value: profile.danceInterests,
                      palette: palette,
                      child: interestItems.isEmpty
                          ? null
                          : Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: interestItems
                                  .map(
                                    (item) => Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.08),
                                        borderRadius: BorderRadius.circular(999),
                                        border: Border.all(color: Colors.white.withOpacity(0.08)),
                                      ),
                                      child: EmojiText(
                                        item,
                                        style: const TextStyle(
                                          color: Color(0xFFFFF7F1),
                                          fontSize: 11,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                    ),
                  ),
                  SizedBox(
                    width: constraints.maxWidth,
                    child: _infoCell(
                      title: t('dance_school'),
                      value: profile.danceSchool,
                      palette: palette,
                    ),
                  ),
                  if (profile.about.trim().isNotEmpty)
                    SizedBox(
                      width: constraints.maxWidth,
                      child: _infoCell(
                        title: t('about_profile'),
                        value: profile.about,
                        palette: palette,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _FriendConnectionsPreviewCard extends StatelessWidget {
  final List<_FriendListItem> friends;
  final VoidCallback onTap;

  const _FriendConnectionsPreviewCard({
    required this.friends,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final preview = friends.take(4).toList();
    return Material(
      color: const Color(0xFF121A2B),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.04),
                Colors.white.withOpacity(0.02),
              ],
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          I18n.t('all_friends_section'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          friends.isEmpty
                              ? I18n.t('visible_friends_empty')
                              : '${friends.length} · ${I18n.t("tap_to_view")}',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.72),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.chevron_right_rounded, color: Colors.white.withOpacity(0.72), size: 24),
                ],
              ),
              if (preview.isNotEmpty) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: 108,
                  height: 40,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      for (var i = 0; i < preview.length; i++)
                        Positioned(
                          left: i * 22,
                          top: 0,
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFF121A2B), width: 2),
                            ),
                            child: VerifiedAvatar(
                              imageUrl: preview[i].avatarUrl,
                              label: preview[i].name,
                              isVerified: preview[i].isVerified,
                              radius: 18,
                              backgroundColor: Colors.white.withOpacity(0.10),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final Color fillColor;
  final Color foregroundColor;
  final bool isLoading;

  const _ProfileActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.fillColor,
    required this.foregroundColor,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fillColor,
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: foregroundColor.withOpacity(0.16)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 16,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoading)
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
                  ),
                )
              else
                Icon(icon, color: foregroundColor, size: 18),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MiniProfileActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final Color fillColor;
  final Color foregroundColor;
  final bool isLoading;

  const _MiniProfileActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    required this.fillColor,
    required this.foregroundColor,
    this.isLoading = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fillColor,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: foregroundColor.withOpacity(0.16)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isLoading)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
                  ),
                )
              else
                Icon(icon, color: foregroundColor, size: 15),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foregroundColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FriendProfile {
  final int accountId;
  final String name;
  final String avatarUrl;
  final String gender;
  final String registeredAt;
  final String danceInterests;
  final String danceSchool;
  final String about;
  final String friendStatus;
  final int? friendRequestId;
  final bool isFriend;
  final bool isVerified;
  final List<_FriendListItem> friends;

  const _FriendProfile({
    required this.accountId,
    required this.name,
    required this.avatarUrl,
    required this.gender,
    required this.registeredAt,
    required this.danceInterests,
    required this.danceSchool,
    required this.about,
    required this.friendStatus,
    required this.friendRequestId,
    required this.isFriend,
    required this.isVerified,
    required this.friends,
  });

  String get initials => name.trim().isNotEmpty ? name.trim().substring(0, 1).toUpperCase() : '?';

  factory _FriendProfile.fromJson(Map<String, dynamic> json) {
    return _FriendProfile(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      gender: (json['gender'] ?? '').toString(),
      registeredAt: (json['registered_at'] ?? '').toString(),
      danceInterests: (json['dance_interests'] ?? '').toString(),
      danceSchool: (json['dance_school'] ?? '').toString(),
      about: (json['about'] ?? '').toString(),
      friendStatus: (json['friend_status'] ?? 'none').toString(),
      friendRequestId: (json['friend_request_id'] as num?)?.toInt(),
      isFriend: json['is_friend'] == true,
      isVerified: json['is_verified'] == true,
      friends: ((json['friends'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(_FriendListItem.fromJson)
          .toList()),
    );
  }
}

class _FriendListItem {
  final int accountId;
  final String name;
  final String avatarUrl;
  final bool isVerified;

  const _FriendListItem({
    required this.accountId,
    required this.name,
    required this.avatarUrl,
    required this.isVerified,
  });

  factory _FriendListItem.fromJson(Map<String, dynamic> json) {
    return _FriendListItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
    );
  }
}
