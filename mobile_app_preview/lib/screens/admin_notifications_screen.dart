import 'package:flutter/material.dart';

import '../services/notifications_api.dart';
import '../services/date_time_format.dart';
import '../services/i18n.dart';

class AdminNotificationsScreen extends StatefulWidget {
  final String sessionToken;

  const AdminNotificationsScreen({super.key, required this.sessionToken});

  @override
  State<AdminNotificationsScreen> createState() => _AdminNotificationsScreenState();
}

class _AdminNotificationsScreenState extends State<AdminNotificationsScreen> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _popupTitleCtrl = TextEditingController();
  final TextEditingController _popupBodyCtrl = TextEditingController();
  final TextEditingController _popupCtaLabelCtrl = TextEditingController();
  final TextEditingController _popupCtaTargetCtrl = TextEditingController();
  final TextEditingController _popupMinimumVersionCtrl = TextEditingController();

  bool _sendToAll = true;
  bool _sending = false;
  bool _loadingUsers = false;
  bool _loadingSent = false;
  bool _popupLoading = false;
  bool _popupSaving = false;
  bool _popupDismissible = true;
  bool _popupShowToGuests = false;
  bool _popupForceUpdate = false;
  String _error = '';
  String _popupError = '';
  final Set<int> _selected = <int>{};
  final Map<int, NotificationUserCandidate> _selectedUsers = <int, NotificationUserCandidate>{};
  List<NotificationUserCandidate> _users = const [];
  List<NotificationFeedItem> _sent = const [];
  AppPopupConfig? _currentPopup;

  String _t(String key) => I18n.t(key);
  String _fmt(String key, Map<String, String> values) {
    var template = _t(key);
    values.forEach((k, v) {
      template = template.replaceAll('{$k}', v);
    });
    return template;
  }

  @override
  void initState() {
    super.initState();
    _loadUsers();
    _loadSent();
    _loadCurrentPopup();
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    _searchCtrl.dispose();
    _popupTitleCtrl.dispose();
    _popupBodyCtrl.dispose();
    _popupCtaLabelCtrl.dispose();
    _popupCtaTargetCtrl.dispose();
    _popupMinimumVersionCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUsers() async {
    setState(() => _loadingUsers = true);
    try {
      final items = await NotificationsApi.searchUsers(
        widget.sessionToken,
        query: _searchCtrl.text,
        limit: 100,
      );
      if (!mounted) return;
      setState(() {
        _users = items;
        for (final user in items) {
          if (_selected.contains(user.accountId)) {
            _selectedUsers[user.accountId] = user;
          }
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingUsers = false);
    }
  }

  Future<void> _loadSent() async {
    setState(() => _loadingSent = true);
    try {
      final items = await NotificationsApi.fetchSent(widget.sessionToken, limit: 200);
      if (!mounted) return;
      setState(() => _sent = items);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loadingSent = false);
    }
  }

  Future<void> _loadCurrentPopup() async {
    setState(() => _popupLoading = true);
    try {
      final popup = await NotificationsApi.fetchAdminCurrentPopup(widget.sessionToken);
      if (!mounted) return;
      _currentPopup = popup;
      _popupTitleCtrl.text = popup?.title ?? '';
      _popupBodyCtrl.text = popup?.body ?? '';
      _popupCtaLabelCtrl.text = popup?.ctaLabel ?? '';
      _popupCtaTargetCtrl.text = popup?.ctaTarget ?? '';
      _popupMinimumVersionCtrl.text = popup?.minimumAppVersion ?? '';
      _popupDismissible = popup?.dismissible ?? true;
      _popupShowToGuests = popup?.showToGuests ?? false;
      _popupForceUpdate = popup?.forceUpdate ?? false;
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      setState(() => _popupError = e.toString());
    } finally {
      if (mounted) setState(() => _popupLoading = false);
    }
  }

  Future<void> _send() async {
    final title = _titleCtrl.text.trim();
    final body = _bodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _error = _t('required_title_body'));
      return;
    }
    if (!_sendToAll && _selected.isEmpty) {
      setState(() => _error = _t('select_recipients_or_enable_all'));
      return;
    }
    setState(() {
      _sending = true;
      _error = '';
    });
    try {
      final sentCount = await NotificationsApi.sendNotification(
        widget.sessionToken,
        title: title,
        body: body,
        sendToAll: _sendToAll,
        targetAccountIds: _selected.toList()..sort(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_fmt('notification_sent_count', {'count': '$sentCount'}))),
      );
      _titleCtrl.clear();
      _bodyCtrl.clear();
      _selected.clear();
      _selectedUsers.clear();
      await _loadSent();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _savePopup() async {
    final title = _popupTitleCtrl.text.trim();
    final body = _popupBodyCtrl.text.trim();
    if (title.isEmpty || body.isEmpty) {
      setState(() => _popupError = _t('popup_required_title_body'));
      return;
    }
    setState(() {
      _popupSaving = true;
      _popupError = '';
    });
    try {
      final popup = await NotificationsApi.saveAppPopup(
        widget.sessionToken,
        title: title,
        body: body,
        ctaLabel: _popupCtaLabelCtrl.text,
        ctaTarget: _popupCtaTargetCtrl.text,
        minimumAppVersion: _popupMinimumVersionCtrl.text,
        dismissible: _popupDismissible,
        showToGuests: _popupShowToGuests,
        forceUpdate: _popupForceUpdate,
      );
      if (!mounted) return;
      setState(() => _currentPopup = popup);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t('popup_saved'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _popupError = e.toString());
    } finally {
      if (mounted) setState(() => _popupSaving = false);
    }
  }

  Future<void> _deactivatePopup() async {
    setState(() {
      _popupSaving = true;
      _popupError = '';
    });
    try {
      await NotificationsApi.deactivateCurrentPopup(widget.sessionToken);
      if (!mounted) return;
      setState(() => _currentPopup = null);
      _popupTitleCtrl.clear();
      _popupBodyCtrl.clear();
      _popupCtaLabelCtrl.clear();
      _popupCtaTargetCtrl.clear();
      _popupMinimumVersionCtrl.clear();
      _popupDismissible = true;
      _popupShowToGuests = false;
      _popupForceUpdate = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_t('popup_closed'))),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _popupError = e.toString());
    } finally {
      if (mounted) setState(() => _popupSaving = false);
    }
  }

  String _fmtDate(String raw) {
    return formatDateTimeDdMmYyyyHmDot(raw);
  }

  String _selectedUsersButtonLabel() {
    if (_sendToAll) {
      return _sending ? _t('sending_ellipsis') : _t('send_notification_button');
    }
    final names = _selectedUsers.values
        .map((user) => user.name.trim().isEmpty ? _t('user') : user.name.trim())
        .toList()
      ..sort();
    if (names.isEmpty) {
      return _sending ? _t('sending_ellipsis') : _t('send_notification_button');
    }
    final preview = names.take(2).join(', ');
    final extraCount = names.length - 2;
    final suffix = extraCount > 0 ? ' +$extraCount' : '';
    return _sending ? _t('sending_ellipsis') : '${_t('send_notification_button')} • $preview$suffix';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF080B14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        title: Text(_t('admin_notifications_title')),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_t('new_notification_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _titleCtrl,
                    decoration: InputDecoration(
                      labelText: _t('title_label'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _bodyCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: _t('content_label'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _sendToAll,
                    title: Text(_t('send_to_all_users_label')),
                    onChanged: (v) => setState(() => _sendToAll = v),
                  ),
                  if (!_sendToAll) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: (_) => _loadUsers(),
                            decoration: InputDecoration(
                              hintText: _t('search_user_hint'),
                              border: OutlineInputBorder(),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _loadingUsers ? null : _loadUsers,
                          child: Text(_t('search_button')),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (_selectedUsers.isNotEmpty) ...[
                      Builder(
                        builder: (context) {
                          final selectedUsers = _selectedUsers.values.toList()
                            ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
                          return Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: selectedUsers
                                .map(
                                  (user) => Chip(
                                    label: Text(
                                      user.name.trim().isEmpty ? _t('user') : user.name.trim(),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    deleteIcon: const Icon(Icons.close_rounded, size: 18),
                                    onDeleted: _sending
                                        ? null
                                        : () {
                                            setState(() {
                                              _selected.remove(user.accountId);
                                              _selectedUsers.remove(user.accountId);
                                            });
                                          },
                                  ),
                                )
                                .toList(),
                          );
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_loadingUsers)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      ..._users.map(
                        (u) => CheckboxListTile(
                          value: _selected.contains(u.accountId),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _selected.add(u.accountId);
                                _selectedUsers[u.accountId] = u;
                              } else {
                                _selected.remove(u.accountId);
                                _selectedUsers.remove(u.accountId);
                              }
                            });
                          },
                          title: Text(u.name.trim().isEmpty ? _t('user') : u.name),
                          subtitle: u.email.trim().isEmpty ? null : Text(u.email),
                          controlAffinity: ListTileControlAffinity.leading,
                          dense: true,
                        ),
                      ),
                  ],
                  if (_error.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_error, style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 8),
                  ElevatedButton.icon(
                    onPressed: _sending ? null : _send,
                    icon: const Icon(Icons.send),
                    label: Text(_selectedUsersButtonLabel()),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_t('app_popup_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(
                    _t('app_popup_description'),
                    style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  if (_popupLoading)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  TextField(
                    controller: _popupTitleCtrl,
                    decoration: InputDecoration(
                      labelText: _t('popup_title_label'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _popupBodyCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: InputDecoration(
                      labelText: _t('popup_body_label'),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _popupCtaLabelCtrl,
                    decoration: InputDecoration(
                      labelText: _t('button_text_label'),
                      border: OutlineInputBorder(),
                      hintText: _t('button_text_hint'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _popupCtaTargetCtrl,
                    decoration: InputDecoration(
                      labelText: _t('button_target_label'),
                      border: OutlineInputBorder(),
                      hintText: _t('button_target_hint'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _popupMinimumVersionCtrl,
                    decoration: InputDecoration(
                      labelText: _t('minimum_version_label'),
                      border: OutlineInputBorder(),
                      hintText: '1.0.9+10',
                    ),
                  ),
                  const SizedBox(height: 8),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _popupDismissible,
                    title: Text(_t('dismissible_label')),
                    onChanged: (v) => setState(() => _popupDismissible = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _popupShowToGuests,
                    title: Text(_t('show_to_guests_label')),
                    onChanged: (v) => setState(() => _popupShowToGuests = v),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _popupForceUpdate,
                    title: Text(_t('force_update_popup_label')),
                    onChanged: (v) => setState(() => _popupForceUpdate = v),
                  ),
                  if (_currentPopup != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _fmt('active_popup_updated', {'date': _fmtDate(_currentPopup!.updatedAt)}),
                      style: TextStyle(color: Colors.white.withOpacity(0.62), fontSize: 11),
                    ),
                  ],
                  if (_popupError.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(_popupError, style: const TextStyle(color: Colors.redAccent)),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: (_popupSaving || _currentPopup == null) ? null : _deactivatePopup,
                          child: Text(_t('close_popup')),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _popupSaving ? null : _savePopup,
                          icon: const Icon(Icons.announcement_outlined),
                          label: Text(_popupSaving ? _t('saving_ellipsis') : _t('save_popup')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF121826),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_t('sent_notifications_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  if (_loadingSent)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_sent.isEmpty)
                    Text(_t('no_sends_yet'), style: TextStyle(color: Colors.white.withOpacity(0.75)))
                  else
                    ..._sent.map(
                      (n) => Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF0F172A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    n.title.trim().isEmpty ? _t('default_notification_title') : n.title,
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                Text(_fmtDate(n.createdAt), style: const TextStyle(fontSize: 11, color: Colors.white70)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(n.body, style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
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
