import 'package:flutter/material.dart';

import '../services/i18n.dart';
import '../services/notification_center.dart';
import '../services/profile_api.dart';
import 'admin_notifications_screen.dart';
import 'app_webview_screen.dart';
import 'chat_thread_screen.dart';
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
  static const _panelColor = Color(0xFF171C29);
  static const _panelSoft = Color(0xFF202637);
  static const _lineColor = Color(0x22FFFFFF);
  static const _rose = Color(0xFFE58B8B);
  static const _peach = Color(0xFFF3B78A);
  static const _sky = Color(0xFF8FB7E8);
  static const _mint = Color(0xFF8FD5C2);
  static const _lavender = Color(0xFFB39DDB);
  static const _photoPanelBase = 'https://foto.dansmagazin.net';

  String _displayName = '';
  String _avatarUrl = '';

  @override
  void initState() {
    super.initState();
    _displayName = widget.userName;
    _loadProfileVisuals();
    NotificationCenter.refresh(widget.sessionToken);
  }

  Future<void> _loadProfileVisuals() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty || !widget.isLoggedIn) return;
    try {
      final s = await ProfileApi.settings(token);
      if (!mounted) return;
      setState(() {
        _displayName = s.username.trim().isEmpty ? widget.userName : s.username.trim();
        _avatarUrl = s.avatarUrl.trim();
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
    await _loadProfileVisuals();
    await NotificationCenter.refresh(widget.sessionToken);
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
        content: [
          PreviewCard(
            title: t('login'),
            subtitle: t('login_subtitle'),
            icon: Icons.login,
            onTap: widget.onLoginTap,
          ),
        ],
      );
    }

    final greetingName = _displayName.trim().isEmpty ? widget.userName : _displayName;
    final initials = greetingName.trim().isNotEmpty ? greetingName.trim().substring(0, 1).toUpperCase() : 'U';
    final emailText = widget.userEmail.trim();

    return ScreenShell(
      title: t('profile'),
      icon: Icons.person,
      subtitle: '',
      content: [
        _ProfileHeroCard(
          displayName: greetingName,
          email: emailText,
          accountId: widget.accountId,
          avatarUrl: _avatarUrl,
          initials: initials,
          subtitle: t('profile_overview_subtitle'),
          onNotificationsTap: _openNotifications,
        ),
        const SizedBox(height: 6),
        _SectionTitle(title: t('quick_actions')),
        const SizedBox(height: 10),
        GridView.count(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 1.18,
          children: [
            _ActionTile(
              title: t('my_tickets'),
              subtitle: t('my_tickets_subtitle'),
              icon: Icons.confirmation_num_rounded,
              accent: _peach,
              onTap: _openTickets,
            ),
            _ActionTile(
              title: t('my_photos'),
              subtitle: t('my_photos_subtitle'),
              icon: Icons.collections_rounded,
              accent: _rose,
              onTap: _openPhotos,
            ),
            _ActionTile(
              title: t('settings'),
              subtitle: t('settings_subtitle'),
              icon: Icons.tune_rounded,
              accent: _sky,
              onTap: _openSettings,
            ),
            _ActionTile(
              title: t('support'),
              subtitle: t('support_subtitle'),
              icon: Icons.chat_bubble_outline_rounded,
              accent: _mint,
              onTap: _openSupportChat,
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
  final String email;
  final int accountId;
  final String avatarUrl;
  final String initials;
  final String subtitle;
  final VoidCallback onNotificationsTap;

  const _ProfileHeroCard({
    required this.displayName,
    required this.email,
    required this.accountId,
    required this.avatarUrl,
    required this.initials,
    required this.subtitle,
    required this.onNotificationsTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF21283A),
            Color(0xFF1A2030),
            Color(0xFF161B29),
          ],
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  children: [
                    avatarUrl.isNotEmpty
                        ? CircleAvatar(radius: 30, backgroundImage: NetworkImage(avatarUrl))
                        : CircleAvatar(
                            radius: 30,
                            backgroundColor: const Color(0xFFE58B8B),
                            child: Text(
                              initials,
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 20),
                            ),
                          ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${t('hello')} $displayName',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.72),
                              fontSize: 13,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              ValueListenableBuilder<int>(
                valueListenable: NotificationCenter.totalCount,
                builder: (_, count, __) => _TopIconButton(
                  icon: Icons.notifications_none_rounded,
                  badgeCount: count,
                  onTap: onNotificationsTap,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF111623),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x22FFFFFF)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _MetaInfo(
                    label: email.isEmpty ? 'E-mail' : email,
                    value: '${t('user_id')}: $accountId',
                  ),
                ),
              ],
            ),
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
      color: const Color(0x1FFFFFFF),
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
              if (badgeCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE66D6D),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: const Color(0xFF161B29), width: 1.5),
                    ),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      badgeCount > 99 ? '99+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
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

class _MetaInfo extends StatelessWidget {
  final String label;
  final String value;

  const _MetaInfo({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withOpacity(0.78),
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            color: Colors.white.withOpacity(0.56),
            fontSize: 12,
          ),
        ),
      ],
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
          color: Colors.white.withOpacity(0.92),
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;

  const _ActionTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF1D2331),
                Color(0xFF181D2A),
              ],
            ),
            border: Border.all(color: const Color(0x22FFFFFF)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x16000000),
                blurRadius: 18,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: accent.withOpacity(0.20),
                  ),
                  child: Icon(icon, color: accent, size: 22),
                ),
                const Spacer(),
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withOpacity(0.64),
                    height: 1.25,
                  ),
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
            decoration: BoxDecoration(
              color: const Color(0xFF171C29),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: const Color(0x22FFFFFF)),
            ),
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
