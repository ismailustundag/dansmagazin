import 'package:flutter/material.dart';

import '../services/event_social_api.dart';
import '../services/i18n.dart';

class BlockedUsersScreen extends StatefulWidget {
  final String sessionToken;

  const BlockedUsersScreen({
    super.key,
    required this.sessionToken,
  });

  @override
  State<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends State<BlockedUsersScreen> {
  late Future<List<BlockedUserItem>> _future;
  int? _unblockingAccountId;

  String _initialOf(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.substring(0, 1).toUpperCase();
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<BlockedUserItem>> _load() {
    return EventSocialApi.blockedUsers(sessionToken: widget.sessionToken);
  }

  Future<void> _unblock(BlockedUserItem item) async {
    if (_unblockingAccountId != null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(I18n.t('unblock_user')),
        content: Text(I18n.t('unblock_user_confirm')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(I18n.t('cancel')),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(I18n.t('unblock_user')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _unblockingAccountId = item.accountId);
    try {
      await EventSocialApi.unblockUser(
        sessionToken: widget.sessionToken,
        targetAccountId: item.accountId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('unblock_user_done'))),
      );
      setState(() => _future = _load());
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())),
      );
    } finally {
      if (mounted) {
        setState(() => _unblockingAccountId = null);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = I18n.t;
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(t('blocked_users')),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<List<BlockedUserItem>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return Center(
                child: TextButton(
                  onPressed: () => setState(() => _future = _load()),
                  child: Text(t('blocked_users_load_error')),
                ),
              );
            }
            final items = snapshot.data ?? const <BlockedUserItem>[];
            if (items.isEmpty) {
              return Center(
                child: Text(
                  t('no_blocked_users'),
                  style: const TextStyle(color: Colors.white70),
                ),
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(14),
              itemCount: items.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final item = items[index];
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121826),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: const Color(0xFF1D2332),
                        backgroundImage: item.avatarUrl.trim().isNotEmpty ? NetworkImage(item.avatarUrl.trim()) : null,
                        child: item.avatarUrl.trim().isEmpty
                            ? Text(
                                _initialOf(item.name),
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                              )
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (item.email.trim().isNotEmpty) ...[
                              const SizedBox(height: 2),
                              Text(
                                item.email,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _unblockingAccountId == item.accountId ? null : () => _unblock(item),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white24),
                        ),
                        child: _unblockingAccountId == item.accountId
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(t('unblock_user')),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
