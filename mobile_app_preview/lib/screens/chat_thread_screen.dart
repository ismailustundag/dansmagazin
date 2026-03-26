import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/app_settings.dart';
import '../services/date_time_format.dart';
import '../services/error_message.dart';
import '../services/notification_center.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';

class ChatThreadScreen extends StatefulWidget {
  final String sessionToken;
  final int peerAccountId;
  final String peerName;
  final String peerAvatarUrl;
  final bool peerIsVerified;

  const ChatThreadScreen({
    super.key,
    required this.sessionToken,
    required this.peerAccountId,
    required this.peerName,
    this.peerAvatarUrl = '',
    this.peerIsVerified = false,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  static const String _base = 'https://api2.dansmagazin.net';

  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _inputFocusNode = FocusNode();
  bool _sending = false;
  bool _loading = true;
  bool _clearingThread = false;
  String? _error;
  int _meAccountId = 0;
  int _peerLastReadMessageId = 0;
  bool _peerTyping = false;
  List<_MsgItem> _items = const [];
  _MsgItem? _replyingTo;
  _MsgItem? _editingMessage;
  Timer? _pollTimer;
  Timer? _typingIdleTimer;
  bool _typingActive = false;
  DateTime _lastTypingSignalAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _refreshThread(scrollToBottom: true);
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _refreshThread(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _typingIdleTimer?.cancel();
    if (_typingActive) {
      unawaited(_setTyping(false));
    }
    _scrollCtrl.dispose();
    _inputFocusNode.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  Future<_ThreadData> _fetchThread() async {
    final t = widget.sessionToken.trim();
    final resp = await http.get(
      Uri.parse('$_base/messages?with_account_id=${widget.peerAccountId}&limit=200'),
      headers: {'Authorization': 'Bearer $t'},
    );
    if (resp.statusCode != 200) {
      throw Exception('Mesajlar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final meId = (body['me_account_id'] as num?)?.toInt() ?? 0;
    final peerLastReadMessageId = (body['peer_last_read_message_id'] as num?)?.toInt() ?? 0;
    final peerTyping = body['peer_typing'] == true;
    final items = (body['items'] as List<dynamic>? ?? [])
        .map((e) => _MsgItem.fromJson(e as Map<String, dynamic>))
        .toList();
    return _ThreadData(
      meAccountId: meId,
      items: items,
      peerLastReadMessageId: peerLastReadMessageId,
      peerTyping: peerTyping,
    );
  }

  Future<void> _refreshThread({bool silent = false, bool scrollToBottom = false}) async {
    if (!silent && mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await _fetchThread();
      if (!mounted) return;
      setState(() {
        _meAccountId = data.meAccountId;
        _peerLastReadMessageId = data.peerLastReadMessageId;
        _peerTyping = data.peerTyping;
        _items = data.items;
        _loading = false;
        _error = null;
      });
      await NotificationCenter.refresh(widget.sessionToken);
      if (scrollToBottom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollCtrl.hasClients) return;
          _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    _typingIdleTimer?.cancel();
    if (_typingActive) {
      _typingActive = false;
      unawaited(_setTyping(false));
    }
    setState(() => _sending = true);
    try {
      final isEditing = _editingMessage != null;
      final resp = await http.post(
        Uri.parse(
          isEditing
              ? '$_base/messages/${_editingMessage!.id}/edit'
              : '$_base/messages/send',
        ),
        headers: {
          'Authorization': 'Bearer ${widget.sessionToken.trim()}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(
          isEditing
              ? {'body': text}
              : {
                  'to_account_id': widget.peerAccountId,
                  'body': text,
                  if (_replyingTo != null) 'reply_to_message_id': _replyingTo!.id,
                },
        ),
      );
      if (resp.statusCode != 200) {
        String msg = isEditing ? 'Mesaj düzenlenemedi' : 'Mesaj gönderilemedi';
        try {
          final j = jsonDecode(resp.body) as Map<String, dynamic>;
          msg = parseApiErrorBody(jsonEncode(j), fallback: msg);
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        }
        return;
      }
      _msgCtrl.clear();
      _replyingTo = null;
      _editingMessage = null;
      if (!mounted) return;
      await _refreshThread(scrollToBottom: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _setTyping(bool isTyping) async {
    final t = widget.sessionToken.trim();
    if (t.isEmpty) return;
    try {
      await http.post(
        Uri.parse('$_base/messages/typing'),
        headers: {
          'Authorization': 'Bearer $t',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'to_account_id': widget.peerAccountId,
          'is_typing': isTyping,
        }),
      );
    } catch (_) {
      // non-critical
    }
  }

  void _onDraftChanged(String value) {
    final hasText = value.trim().isNotEmpty;
    if (!hasText) {
      _typingIdleTimer?.cancel();
      if (_typingActive) {
        _typingActive = false;
        unawaited(_setTyping(false));
      }
      return;
    }

    final now = DateTime.now();
    if (!_typingActive || now.difference(_lastTypingSignalAt) >= const Duration(seconds: 2)) {
      _typingActive = true;
      _lastTypingSignalAt = now;
      unawaited(_setTyping(true));
    }

    _typingIdleTimer?.cancel();
    _typingIdleTimer = Timer(const Duration(seconds: 2), () {
      if (!_typingActive) return;
      _typingActive = false;
      unawaited(_setTyping(false));
    });
  }

  void _showAvatarPreview() {
    final url = widget.peerAvatarUrl.trim();
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
                borderRadius: BorderRadius.circular(14),
                child: Image.network(url, fit: BoxFit.contain),
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

  void _startReply(_MsgItem item) {
    setState(() {
      _editingMessage = null;
      _replyingTo = item;
    });
    _inputFocusNode.requestFocus();
  }

  void _startEdit(_MsgItem item) {
    setState(() {
      _replyingTo = null;
      _editingMessage = item;
      _msgCtrl.text = item.body;
      _msgCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _msgCtrl.text.length));
    });
    _inputFocusNode.requestFocus();
  }

  void _clearComposerContext() {
    setState(() {
      _replyingTo = null;
      _editingMessage = null;
    });
  }

  Future<void> _deleteMessage(_MsgItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mesaj silinsin mi?'),
        content: const Text('Bu mesaj sohbet içinde silinmiş olarak görünecek.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final resp = await http.post(
      Uri.parse('$_base/messages/${item.id}/delete'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Mesaj silinemedi')));
      return;
    }
    if (!mounted) return;
    await _refreshThread();
  }

  Future<void> _toggleLike(_MsgItem item, bool like) async {
    final resp = await http.post(
      Uri.parse('$_base/messages/${item.id}/${like ? 'like' : 'unlike'}'),
      headers: {'Authorization': 'Bearer ${widget.sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(like ? 'Mesaj beğenilemedi' : 'Beğeni geri alınamadı')),
      );
      return;
    }
    if (!mounted) return;
    await _refreshThread(silent: true);
  }

  Future<void> _clearConversation() async {
    if (_clearingThread) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sohbeti temizle'),
        content: const Text('Bu işlem sohbeti sadece senin görünümünden kaldırır. Karşı tarafın mesajları silinmez.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Vazgeç'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Temizle'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _clearingThread = true);
    try {
      final resp = await http.post(
        Uri.parse('$_base/messages/clear'),
        headers: {
          'Authorization': 'Bearer ${widget.sessionToken.trim()}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'peer_account_id': widget.peerAccountId}),
      );
      if (resp.statusCode != 200) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sohbet temizlenemedi')));
        return;
      }
      _replyingTo = null;
      _editingMessage = null;
      _msgCtrl.clear();
      if (!mounted) return;
      await _refreshThread();
    } finally {
      if (mounted) setState(() => _clearingThread = false);
    }
  }

  String _replySenderLabel(_MsgItem item) {
    return item.senderAccountId == _meAccountId ? 'Sen' : widget.peerName;
  }

  String _quotedPreviewText(_MsgItem item) {
    if (item.isDeleted) return 'Bu mesaj silindi';
    final text = item.body.trim();
    if (text.length <= 80) return text;
    return '${text.substring(0, 77)}...';
  }

  Future<void> _showMessageActions(_MsgItem item) async {
    final mine = item.senderAccountId == _meAccountId;
    if (item.isDeleted) return;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.surfacePrimary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) {
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (mine) ...[
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('Mesajı düzenle'),
                  onTap: () => Navigator.of(ctx).pop('edit'),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Mesajı sil'),
                  onTap: () => Navigator.of(ctx).pop('delete'),
                ),
              ] else ...[
                ListTile(
                  leading: Icon(item.likedByMe ? Icons.favorite_border : Icons.favorite),
                  title: Text(item.likedByMe ? 'Beğeniyi geri al' : 'Beğen'),
                  onTap: () => Navigator.of(ctx).pop(item.likedByMe ? 'unlike' : 'like'),
                ),
                ListTile(
                  leading: const Icon(Icons.reply_rounded),
                  title: const Text('Yanıtla'),
                  onTap: () => Navigator.of(ctx).pop('reply'),
                ),
              ],
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'edit':
        _startEdit(item);
        break;
      case 'delete':
        await _deleteMessage(item);
        break;
      case 'like':
        await _toggleLike(item, true);
        break;
      case 'unlike':
        await _toggleLike(item, false);
        break;
      case 'reply':
        _startReply(item);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final messageScale = AppSettings.textScale.value.clamp(0.90, 1.35).toDouble();
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: Row(
          children: [
            InkWell(
              onTap: _showAvatarPreview,
              borderRadius: BorderRadius.circular(20),
              child: VerifiedAvatar(
                imageUrl: widget.peerAvatarUrl,
                label: widget.peerName,
                isVerified: widget.peerIsVerified,
                radius: 16,
                backgroundColor: AppTheme.violet,
                fallbackStyle: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: EmojiText(
                widget.peerName,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') {
                _clearConversation();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('Sohbeti temizle'),
              ),
            ],
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            Expanded(
              child: _loading && _items.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _items.isEmpty
                      ? Center(
                          child: TextButton(
                            onPressed: () => _refreshThread(),
                            child: const Text('Mesajlar yüklenemedi, tekrar dene'),
                          ),
                        )
                      : _items.isEmpty
                          ? const Center(child: Text('Henüz mesaj yok.'))
                          : ListView.builder(
                              controller: _scrollCtrl,
                              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                              padding: const EdgeInsets.all(12),
                              itemCount: _items.length,
                              itemBuilder: (_, i) {
                                final m = _items[i];
                                final mine = m.senderAccountId == _meAccountId;
                                final deliveredToServer = mine && m.id > 0;
                                final seenByPeer = mine && m.id > 0 && _peerLastReadMessageId >= m.id;
                                return Align(
                                  alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                                  child: GestureDetector(
                                    onLongPress: () => _showMessageActions(m),
                                    child: Container(
                                      margin: const EdgeInsets.only(bottom: 8),
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                      constraints: const BoxConstraints(maxWidth: 280),
                                      decoration: BoxDecoration(
                                        color: mine ? AppTheme.violet : AppTheme.surfaceSecondary,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(
                                          color: mine ? AppTheme.violet.withOpacity(0.28) : AppTheme.borderSoft,
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          if (m.replyTo != null) ...[
                                            Container(
                                              width: double.infinity,
                                              margin: const EdgeInsets.only(bottom: 8),
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                              decoration: BoxDecoration(
                                                color: Colors.black.withOpacity(0.12),
                                                borderRadius: BorderRadius.circular(12),
                                                border: Border.all(color: Colors.white.withOpacity(0.10)),
                                              ),
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    _replySenderLabel(m.replyTo!),
                                                    style: TextStyle(
                                                      color: Colors.white.withOpacity(0.78),
                                                      fontSize: 11 * messageScale,
                                                      fontWeight: FontWeight.w700,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 3),
                                                  EmojiText(
                                                    _quotedPreviewText(m.replyTo!),
                                                    maxLines: 2,
                                                    overflow: TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 12 * messageScale,
                                                      color: Colors.white.withOpacity(0.84),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                          EmojiText(
                                            m.isDeleted ? 'Bu mesaj silindi' : m.body,
                                            style: TextStyle(
                                              fontSize: 15 * messageScale,
                                              height: 1.35,
                                              fontStyle: m.isDeleted ? FontStyle.italic : FontStyle.normal,
                                              color: m.isDeleted ? Colors.white.withOpacity(0.72) : null,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                formatDateTimeDdMmYyyyHmDot(m.createdAt),
                                                style: TextStyle(
                                                  color: Colors.white.withOpacity(0.7),
                                                  fontSize: 11 * messageScale,
                                                ),
                                              ),
                                              if (m.editedAt.trim().isNotEmpty) ...[
                                                const SizedBox(width: 6),
                                                Text(
                                                  'düzenlendi',
                                                  style: TextStyle(
                                                    color: Colors.white.withOpacity(0.62),
                                                    fontSize: 10 * messageScale,
                                                  ),
                                                ),
                                              ],
                                              if (m.likeCount > 0) ...[
                                                const SizedBox(width: 6),
                                                Icon(
                                                  Icons.favorite,
                                                  size: 13 * messageScale,
                                                  color: Colors.pinkAccent,
                                                ),
                                              ],
                                              if (deliveredToServer) ...[
                                                const SizedBox(width: 4),
                                                Icon(
                                                  seenByPeer ? Icons.done_all : Icons.done,
                                                  size: 17 * messageScale,
                                                  color: seenByPeer ? AppTheme.success : AppTheme.textSecondary,
                                                ),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
            ),
            SafeArea(
              top: false,
              child: Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                color: AppTheme.surfacePrimary,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_replyingTo != null || _editingMessage != null)
                      Container(
                        width: double.infinity,
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceSecondary,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: AppTheme.borderSoft),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _editingMessage != null ? 'Mesajı düzenle' : 'Yanıtlanıyor',
                                    style: TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 11 * messageScale,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  EmojiText(
                                    _editingMessage != null ? _editingMessage!.body : _quotedPreviewText(_replyingTo!),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 13 * messageScale,
                                      color: AppTheme.textPrimary,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              onPressed: _clearComposerContext,
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ],
                        ),
                      ),
                    if (_peerTyping)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: EmojiText(
                          '${widget.peerName} yazıyor...',
                          style: TextStyle(
                            fontSize: 12 * messageScale,
                            color: AppTheme.info,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            constraints: const BoxConstraints(minHeight: 52),
                            padding: const EdgeInsets.symmetric(horizontal: 14),
                            decoration: BoxDecoration(
                              color: AppTheme.surfaceElevated,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(color: AppTheme.borderStrong.withOpacity(0.9)),
                            ),
                            child: TextField(
                              controller: _msgCtrl,
                              focusNode: _inputFocusNode,
                              minLines: 1,
                              maxLines: 4,
                              onChanged: _onDraftChanged,
                              onSubmitted: (_) => _send(),
                              textInputAction: TextInputAction.send,
                              textAlignVertical: TextAlignVertical.center,
                              style: TextStyle(
                                fontSize: 15 * messageScale,
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w500,
                                height: 1.3,
                              ),
                              cursorColor: AppTheme.violet,
                              decoration: InputDecoration(
                                hintText: _editingMessage != null ? 'Mesajı düzenle...' : 'Mesaj yaz...',
                                hintStyle: TextStyle(
                                  fontSize: 14 * messageScale,
                                  color: AppTheme.textTertiary,
                                  fontWeight: FontWeight.w400,
                                ),
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                disabledBorder: InputBorder.none,
                                errorBorder: InputBorder.none,
                                focusedErrorBorder: InputBorder.none,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(vertical: 14),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(minWidth: 92, minHeight: 52),
                          child: ElevatedButton(
                            onPressed: _sending ? null : _send,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.violet,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                              minimumSize: const Size(92, 52),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            child: _sending
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : Text(_editingMessage != null ? 'Kaydet' : 'Gönder', style: TextStyle(fontSize: 14 * messageScale)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ThreadData {
  final int meAccountId;
  final int peerLastReadMessageId;
  final bool peerTyping;
  final List<_MsgItem> items;

  const _ThreadData({
    required this.meAccountId,
    required this.peerLastReadMessageId,
    required this.peerTyping,
    required this.items,
  });
}

class _MsgItem {
  final int id;
  final int senderAccountId;
  final int receiverAccountId;
  final String body;
  final String createdAt;
  final String editedAt;
  final String deletedAt;
  final int likeCount;
  final bool likedByMe;
  final _MsgItem? replyTo;

  const _MsgItem({
    required this.id,
    required this.senderAccountId,
    required this.receiverAccountId,
    required this.body,
    required this.createdAt,
    required this.editedAt,
    required this.deletedAt,
    required this.likeCount,
    required this.likedByMe,
    required this.replyTo,
  });

  bool get isDeleted => deletedAt.trim().isNotEmpty;

  factory _MsgItem.fromJson(Map<String, dynamic> json) {
    final replyMessageId = (json['reply_message_id'] as num?)?.toInt() ?? 0;
    return _MsgItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      senderAccountId: (json['sender_account_id'] as num?)?.toInt() ?? 0,
      receiverAccountId: (json['receiver_account_id'] as num?)?.toInt() ?? 0,
      body: (json['body'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
      editedAt: (json['edited_at'] ?? '').toString(),
      deletedAt: (json['deleted_at'] ?? '').toString(),
      likeCount: (json['like_count'] as num?)?.toInt() ?? 0,
      likedByMe: json['liked_by_me'] == true,
      replyTo: replyMessageId > 0
          ? _MsgItem(
              id: replyMessageId,
              senderAccountId: (json['reply_sender_account_id'] as num?)?.toInt() ?? 0,
              receiverAccountId: 0,
              body: (json['reply_body'] ?? '').toString(),
              createdAt: '',
              editedAt: '',
              deletedAt: (json['reply_deleted_at'] ?? '').toString(),
              likeCount: 0,
              likedByMe: false,
              replyTo: null,
            )
          : null,
    );
  }
}
