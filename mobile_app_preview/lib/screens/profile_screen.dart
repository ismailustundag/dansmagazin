import 'package:flutter/material.dart';

import '../services/i18n.dart';
import '../services/notification_center.dart';
import '../services/profile_card_palette.dart';
import '../services/profile_api.dart';
import '../theme/app_theme.dart';
import 'admin_notifications_screen.dart';
import 'app_webview_screen.dart';
import 'chat_thread_screen.dart';
import 'edit_profile_screen.dart';
import 'editor_event_management_screen.dart';
import 'my_photos_screen.dart';
import 'notifications_screen.dart';
import 'screen_shell.dart';
import 'settings_screen.dart';
import 'tickets_screen.dart';

class ProfileScreen extends StatefulWidget {
  final bool isLoggedIn;
  final String userName;
  final String userEmail;
  final String sessionToken;
  final int accountId;
  final int? wpUserId;
  final List<String> wpRoles;
  final String appRole;
  final bool canCreateMobileEvent;
  final VoidCallback onLoginTap;
  final VoidCallback onLogoutTap;
  final Future<void> Function(String route)? onOpenRoute;

  const ProfileScreen({
    super.key,
    required this.isLoggedIn,
    required this.userName,
    required this.userEmail,
    required this.sessionToken,
    required this.accountId,
    required this.wpUserId,
    required this.wpRoles,
    required this.appRole,
    required this.canCreateMobileEvent,
    required this.onLoginTap,
    required this.onLogoutTap,
    this.onOpenRoute,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  static const _rose = AppTheme.pink;
  static const _peach = AppTheme.orange;
  static const _sky = AppTheme.cyan;
  static const _mint = AppTheme.info;
  static const _lavender = AppTheme.violet;
  static const _photoPanelBase = 'https://foto.dansmagazin.net';

  String _displayName = '';
  String _avatarUrl = '';
  ProfileSettingsData? _profile;

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
    _displayName = widget.userName;
    _loadProfileData();
    NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _loadProfileData() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty || !widget.isLoggedIn) return;
    try {
      final s = await ProfileApi.settings(token);
      if (!mounted) return;
      setState(() {
        _profile = s;
        _displayName = s.username.trim().isEmpty ? widget.userName : s.username.trim();
        _avatarUrl = _resolveAvatarUrl(s.avatarUrl, s.updatedAt);
      });
    } catch (_) {}
  }

  Future<void> _openTickets() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TicketsScreen(sessionToken: widget.sessionToken),
      ),
    );
  }

  Future<void> _openPhotos() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MyPhotosScreen(accountId: widget.accountId),
      ),
    );
  }

  Future<void> _openNotifications() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NotificationsScreen(
          sessionToken: widget.sessionToken,
          onOpenRoute: widget.onOpenRoute,
        ),
      ),
    );
    await NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _openSettings() async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          sessionToken: widget.sessionToken,
          isSuperAdmin: widget.appRole == 'super_admin',
        ),
      ),
    );
    if (deleted == true) {
      widget.onLogoutTap();
      return;
    }
    await _loadProfileData();
    await NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _openEditProfile() async {
    final updated = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => EditProfileScreen(sessionToken: widget.sessionToken),
      ),
    );
    if (updated == true) {
      await _loadProfileData();
    }
  }

  Future<void> _openSupportChat() async {
    if (widget.sessionToken.trim().isEmpty) return;
    try {
      final contact = await ProfileApi.supportContact(widget.sessionToken);
      final target = contact ??
          const SupportContact(
            accountId: 164,
            name: 'Dansmagazin',
            avatarUrl: '',
          );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatThreadScreen(
            sessionToken: widget.sessionToken,
            peerAccountId: target.accountId,
            peerName: target.name,
            peerAvatarUrl: target.avatarUrl,
          ),
        ),
      );
    } catch (_) {}
  }

  Future<void> _openPhotoPanel(String path, String title) async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) return;
    final cleanPath = path.trim().replaceAll(RegExp(r'^/+'), '');
    final nextPath = '/panel/$cleanPath';
    final url = '$_photoPanelBase/mobile-sso-login?next=${Uri.encodeQueryComponent(nextPath)}';
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppWebViewScreen(
          url: url,
          title: title,
          headers: {'Authorization': 'Bearer $token'},
        ),
      ),
    );
  }

  bool get _showManagementTools =>
      widget.appRole == 'super_admin' ||
      widget.canCreateMobileEvent ||
      widget.wpRoles.contains('administrator') ||
      widget.wpRoles.contains('editor');

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    if (!widget.isLoggedIn) {
      return ScreenShell(
        title: t('profile'),
        icon: Icons.person,
        subtitle: t('profile_subtitle_guest'),
        tone: AppTone.profile,
        content: [
          PreviewCard(
            title: t('login'),
            subtitle: t('login_subtitle'),
            icon: Icons.login,
            tone: AppTone.profile,
            onTap: widget.onLoginTap,
          ),
        ],
      );
    }

    final greetingName = _displayName.trim().isEmpty ? widget.userName : _displayName;
    final initials = greetingName.trim().isNotEmpty ? greetingName.trim().substring(0, 1).toUpperCase() : 'U';

    return ScreenShell(
      title: t('profile'),
      icon: Icons.person,
      subtitle: '',
      tone: AppTone.profile,
      headerTrailing: _TopIconButton(
        icon: Icons.notifications_none_rounded,
        badgeCount: 0,
        onTap: _openNotifications,
      ),
      content: [
        _ProfileHeroCard(
          displayName: greetingName,
          accountId: widget.accountId,
          avatarUrl: _avatarUrl,
          initials: initials,
          gender: _profile?.gender ?? '',
          registeredAt: _profile?.registeredAt ?? '',
          danceInterests: _profile?.danceInterests ?? '',
          danceSchool: _profile?.danceSchool ?? '',
          about: _profile?.about ?? '',
        ),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _openEditProfile,
            icon: const Icon(Icons.edit_rounded),
            label: Text(t('edit_profile')),
          ),
        ),
        const SizedBox(height: 14),
        _SectionTitle(title: t('quick_actions')),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _ActionTile(
                title: t('my_tickets'),
                icon: Icons.confirmation_num_rounded,
                accent: _peach,
                onTap: _openTickets,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ActionTile(
                title: t('my_photos'),
                icon: Icons.collections_rounded,
                accent: _rose,
                onTap: _openPhotos,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ActionTile(
                title: t('settings'),
                icon: Icons.tune_rounded,
                accent: _sky,
                onTap: _openSettings,
              ),
            ),
          ],
        ),
        if (_showManagementTools) ...[
          const SizedBox(height: 14),
          _SectionTitle(title: t('management_tools')),
          const SizedBox(height: 10),
          if (widget.canCreateMobileEvent || widget.wpRoles.contains('administrator') || widget.wpRoles.contains('editor'))
            _ProfileListCard(
              title: t('event_management'),
              subtitle: t('event_management_subtitle'),
              icon: Icons.event_note_rounded,
              accent: _lavender,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => EditorEventManagementScreen(sessionToken: widget.sessionToken),
                ),
              ),
            ),
          if (widget.isLoggedIn && widget.appRole == 'super_admin')
            _ProfileListCard(
              title: 'Foto Paneli',
              subtitle: 'Etkinlikler, profil ve kredi islemlerini yonetin',
              icon: Icons.photo_library_outlined,
              accent: _mint,
              onTap: () => _openPhotoPanel('events', 'Foto Paneli · Etkinlikler'),
            ),
          if (widget.appRole == 'super_admin')
            _ProfileListCard(
              title: t('send_notification'),
              subtitle: t('send_notification_subtitle'),
              icon: Icons.campaign_rounded,
              accent: _peach,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AdminNotificationsScreen(sessionToken: widget.sessionToken),
                ),
              ),
            ),
        ],
        const SizedBox(height: 14),
        _SectionTitle(title: t('account_tools')),
        const SizedBox(height: 10),
        _ProfileListCard(
          title: t('logout'),
          subtitle: t('logout_subtitle'),
          icon: Icons.logout_rounded,
          accent: _rose,
          onTap: widget.onLogoutTap,
        ),
      ],
    );
  }
}

class _ProfileHeroCard extends StatelessWidget {
  final String displayName;
  final int accountId;
  final String avatarUrl;
  final String initials;
  final String gender;
  final String registeredAt;
  final String danceInterests;
  final String danceSchool;
  final String about;

  const _ProfileHeroCard({
    required this.displayName,
    required this.accountId,
    required this.avatarUrl,
    required this.initials,
    required this.gender,
    required this.registeredAt,
    required this.danceInterests,
    required this.danceSchool,
    required this.about,
  });

  List<String> _interestItems(String raw) {
    return raw
        .split(RegExp(r'[,;\n]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Widget _profileVisual(ProfileCardPalette palette) {
    if (avatarUrl.trim().isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Image.network(
          avatarUrl.trim(),
          width: double.infinity,
          height: 214,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _fallbackVisual(palette),
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
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 44,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    final nameText = displayName.trim().toUpperCase();
    final palette = ProfileCardPalette.fromGender(gender);
    final interestItems = _interestItems(danceInterests);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette.cardGradient,
        ),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
        boxShadow: [
          BoxShadow(
            color: palette.buttonFill.withOpacity(0.16),
            blurRadius: 24,
            offset: const Offset(0, 12),
          ),
          const BoxShadow(
            color: Color(0x22000000),
            blurRadius: 24,
            offset: Offset(0, 14),
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
                      value: registeredAt,
                      palette: palette,
                    ),
                  ),
                  SizedBox(
                    width: cellWidth,
                    child: _infoCell(
                      title: t('profile_id'),
                      value: '$accountId',
                      palette: palette,
                    ),
                  ),
                  SizedBox(
                    width: constraints.maxWidth,
                    child: _infoCell(
                      title: t('dance_interests'),
                      value: danceInterests,
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
                      value: danceSchool,
                      palette: palette,
                    ),
                  ),
                  if (about.trim().isNotEmpty)
                    SizedBox(
                      width: constraints.maxWidth,
                      child: _infoCell(
                        title: t('about_profile'),
                        value: about,
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

class _TopIconButton extends StatelessWidget {
  final IconData icon;
  final int badgeCount;
  final VoidCallback onTap;

  const _TopIconButton({
    required this.icon,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surfaceSecondary.withOpacity(0.88),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Center(child: Icon(icon, color: Colors.white, size: 24)),
              ValueListenableBuilder<int>(
                valueListenable: NotificationCenter.totalCount,
                builder: (_, count, __) {
                  if (count <= 0) return const SizedBox.shrink();
                  return Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppTheme.pink,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: AppTheme.bgPrimary, width: 1.5),
                      ),
                      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        count > 99 ? '99+' : '$count',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
          color: AppTheme.textPrimary,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _ActionTile({
    required this.title,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final start = Color.alphaBlend(accent.withOpacity(0.24), const Color(0xFF21283A));
    final end = Color.alphaBlend(accent.withOpacity(0.12), const Color(0xFF171C29));
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          decoration: AppTheme.panel(tone: AppTone.profile, radius: 18, elevated: true).copyWith(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                start,
                end,
              ],
            ),
            border: Border.all(color: accent.withOpacity(0.22)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: accent.withOpacity(0.22),
                  ),
                  child: Icon(icon, color: accent, size: 25),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.1),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ProfileListCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _ProfileListCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: AppTheme.panel(tone: AppTone.profile, radius: 18, subtle: true),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, color: accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.63),
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.arrow_forward_ios_rounded, color: Colors.white.withOpacity(0.42), size: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
