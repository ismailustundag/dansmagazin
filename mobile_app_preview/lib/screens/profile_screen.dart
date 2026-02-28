import 'package:flutter/material.dart';

import '../services/event_social_api.dart';
import 'friends_screen.dart';
import 'messages_inbox_screen.dart';
import 'placeholder_detail_screen.dart';
import 'screen_shell.dart';
import 'tickets_screen.dart';

class ProfileScreen extends StatelessWidget {
  final bool isLoggedIn;
  final String userName;
  final String userEmail;
  final String sessionToken;
  final int accountId;
  final int? wpUserId;
  final List<String> wpRoles;
  final VoidCallback onLoginTap;
  final VoidCallback onLogoutTap;

  const ProfileScreen({
    super.key,
    required this.isLoggedIn,
    required this.userName,
    required this.userEmail,
    required this.sessionToken,
    required this.accountId,
    required this.wpUserId,
    required this.wpRoles,
    required this.onLoginTap,
    required this.onLogoutTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!isLoggedIn) {
      return ScreenShell(
        title: 'Profil',
        icon: Icons.person,
        subtitle: 'Kişisel alanınıza erişmek için giriş yapın.',
        content: [
          PreviewCard(
            title: 'Giriş Yap',
            subtitle: 'Biletler, mesajlar ve satın alınan fotoğraflar',
            icon: Icons.login,
            onTap: onLoginTap,
          ),
        ],
      );
    }
    return ScreenShell(
      title: 'Profil',
      icon: Icons.person,
      subtitle: '$userName • $userEmail${wpRoles.isNotEmpty ? ' • ${wpRoles.join(",")}' : ''}',
      content: [
        PreviewCard(
          title: 'Biletlerim',
          subtitle: 'Katıldığınız etkinlik biletleri',
          icon: Icons.confirmation_num,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TicketsScreen(
                sessionToken: sessionToken,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: 'Fotoğraflarım',
          subtitle: 'Eşleşen ve satın aldığınız fotoğraflar',
          icon: Icons.photo_library,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const PlaceholderDetailScreen(
                title: 'Fotoğraflarım',
                description: 'Kullanıcıya ait fotoğraflar bu ekranda olacak.',
                icon: Icons.photo_library,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: 'Mesajlarım',
          subtitle: 'Arkadaşlarınla yaptığın konuşmalar',
          icon: Icons.mark_chat_unread,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => MessagesInboxScreen(
                sessionToken: sessionToken,
              ),
            ),
          ),
        ),
        FutureBuilder<List<FriendRequestItem>>(
          future: EventSocialApi.friendRequests(
            sessionToken: sessionToken,
            direction: 'incoming',
          ),
          builder: (context, snapshot) {
            final count = snapshot.data?.length ?? 0;
            final subtitle = count > 0
                ? 'Bekleyen istek: $count'
                : 'Eklediğin arkadaşlar ve sosyal ağın';
            return PreviewCard(
              title: count > 0 ? 'Arkadaşlarım ($count)' : 'Arkadaşlarım',
              subtitle: subtitle,
              icon: Icons.groups,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => FriendsScreen(
                    sessionToken: sessionToken,
                  ),
                ),
              ),
            );
          },
        ),
        PreviewCard(
          title: 'Ayarlar',
          subtitle: 'Bildirim, gizlilik, dil',
          icon: Icons.settings,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => const PlaceholderDetailScreen(
                title: 'Ayarlar',
                description: 'Hesap ve uygulama ayarları bu ekranda yönetilecek.',
                icon: Icons.settings,
              ),
            ),
          ),
        ),
        PreviewCard(
          title: 'Çıkış Yap',
          subtitle: 'Bu cihazdaki oturumu kapat',
          icon: Icons.logout,
          onTap: onLogoutTap,
        ),
      ],
    );
  }
}
