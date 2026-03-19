import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/event_social_api.dart';
import '../services/i18n.dart';
import '../services/profile_card_palette.dart';
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
        ),
      ),
    );
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
              padding: const EdgeInsets.all(14),
              children: [
                _FriendProfileHeroCard(
                  profile: profile,
                  onPhotoTap: () => _showAvatarPreview(profile.avatarUrl, profile.name),
                ),
                const SizedBox(height: 14),
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
              Text(
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
    if (profile.avatarUrl.trim().isNotEmpty) {
      return InkWell(
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
      );
    }
    return _fallbackVisual(palette);
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
          Text(
            nameText,
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
                                      child: Text(
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

class _FriendProfile {
  final int accountId;
  final String name;
  final String avatarUrl;
  final String gender;
  final String registeredAt;
  final String danceInterests;
  final String danceSchool;
  final String about;

  const _FriendProfile({
    required this.accountId,
    required this.name,
    required this.avatarUrl,
    required this.gender,
    required this.registeredAt,
    required this.danceInterests,
    required this.danceSchool,
    required this.about,
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
    );
  }
}
