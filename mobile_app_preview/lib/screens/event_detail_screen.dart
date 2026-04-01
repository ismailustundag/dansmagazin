import 'package:flutter/material.dart';
import 'package:add_2_calendar/add_2_calendar.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/checkout_api.dart';
import '../services/content_share_service.dart';
import '../services/calendar_service.dart';
import '../services/date_time_format.dart';
import '../services/event_social_api.dart';
import '../services/i18n.dart';
import '../theme/app_theme.dart';
import '../widgets/emoji_text.dart';
import '../widgets/verified_avatar.dart';
import 'app_webview_screen.dart';
import 'friend_profile_screen.dart';

class EventDetailScreen extends StatefulWidget {
  final int submissionId;
  final String title;
  final String cover;
  final String description;
  final String eventDate;
  final String endAt;
  final String venue;
  final String venueMapUrl;
  final String organizer;
  final String program;
  final double entryFee;
  final String ticketUrl;
  final String wooProductId;
  final bool ticketSalesEnabled;
  final String sessionToken;
  final bool canAddToFeed;

  const EventDetailScreen({
    super.key,
    required this.submissionId,
    required this.title,
    required this.cover,
    required this.description,
    required this.eventDate,
    required this.endAt,
    required this.venue,
    required this.venueMapUrl,
    required this.organizer,
    required this.program,
    required this.entryFee,
    required this.ticketUrl,
    required this.wooProductId,
    required this.ticketSalesEnabled,
    required this.sessionToken,
    required this.canAddToFeed,
  });

  @override
  State<EventDetailScreen> createState() => _EventDetailScreenState();
}

class _EventDetailScreenState extends State<EventDetailScreen> {
  int _tab = 0;
  bool _openingCheckout = false;
  bool _loadingAttendees = true;
  bool _loadingComments = true;
  bool _loadingRaffle = true;
  bool _changingAttendance = false;
  bool _savingComment = false;
  bool _joiningRaffle = false;
  bool _joined = false;
  List<EventAttendee> _attendees = const [];
  List<EventCommentItem> _comments = const [];
  EventRaffleDetail? _raffle;
  String? _commentsError;
  String? _raffleError;
  int? _deletingCommentId;
  bool _editingComment = false;
  bool _sharingBusy = false;
  final TextEditingController _commentCtrl = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _didAutoHintScroll = false;
  bool _userInteractedWithScroll = false;
  int _autoHintAttempts = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScrollActivity);
    _loadAttendees();
    _loadComments();
    _loadRaffle();
    WidgetsBinding.instance.addPostFrameCallback((_) => _triggerAutoHintScroll());
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScrollActivity);
    _scrollController.dispose();
    _commentCtrl.dispose();
    super.dispose();
  }

  void _handleScrollActivity() {
    if (_scrollController.hasClients && _scrollController.offset > 2) {
      _userInteractedWithScroll = true;
    }
  }

  void _triggerAutoHintScroll() {
    if (!mounted || _didAutoHintScroll || _userInteractedWithScroll) return;
    if (!_scrollController.hasClients) {
      _scheduleAutoHintRetry();
      return;
    }
    final maxExtent = _scrollController.position.maxScrollExtent;
    if (maxExtent <= 24) {
      _scheduleAutoHintRetry();
      return;
    }
    final targetOffset = maxExtent.clamp(0, 84.0).toDouble();
    _didAutoHintScroll = true;
    _scrollController.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
    );
  }

  void _scheduleAutoHintRetry() {
    if (_didAutoHintScroll || _userInteractedWithScroll || _autoHintAttempts >= 3) return;
    _autoHintAttempts += 1;
    Future<void>.delayed(const Duration(milliseconds: 220), () {
      if (!mounted) return;
      _triggerAutoHintScroll();
    });
  }

  String _fmtDate(String raw) {
    return formatDateTimeDdMmYyyyHmDot(raw);
  }

  String _buyUrl() {
    if (!widget.ticketSalesEnabled) return '';
    final t = widget.ticketUrl.trim();
    if (t.isNotEmpty) {
      final u = Uri.tryParse(t);
      if (u != null) {
        final parsedPid =
            u.queryParameters['p'] ?? u.queryParameters['product_id'] ?? u.queryParameters['add-to-cart'];
        if (parsedPid != null && parsedPid.trim().isNotEmpty) {
          return 'https://www.dansmagazin.net/?post_type=product&p=${parsedPid.trim()}';
        }
      }
      return t;
    }
    final pid = widget.wooProductId.trim();
    if (pid.isNotEmpty) {
      return 'https://www.dansmagazin.net/?post_type=product&p=$pid';
    }
    return '';
  }

  Future<void> _openCheckout() async {
    final directUrl = _buyUrl();
    if (directUrl.isEmpty) return;

    var targetUrl = directUrl;
    if (widget.sessionToken.trim().isNotEmpty) {
      try {
        targetUrl = await CheckoutApi.buildAutoLoginUrl(
          sessionToken: widget.sessionToken.trim(),
          targetUrl: directUrl,
        );
      } catch (_) {
        // Auto-login link üretimi başarısızsa normal ürün sayfasına düş.
      }
    }

    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AppWebViewScreen(url: targetUrl, title: widget.title),
      ),
    );
  }

  ContentSharePayload _sharePayload() {
    final parts = <String>[];
    final eventDate = _fmtDate(widget.eventDate).trim();
    if (eventDate.isNotEmpty) parts.add(eventDate);
    if (widget.venue.trim().isNotEmpty) parts.add(widget.venue.trim());
    final subtitle = parts.join(' · ');
    final rawDescription = widget.description.trim().isNotEmpty
        ? widget.description.trim()
        : widget.program.trim().isNotEmpty
            ? widget.program.trim()
            : widget.organizer.trim();
    final trimmedDescription = rawDescription.length > 180
        ? '${rawDescription.substring(0, 180).trim()}...'
        : rawDescription;
    return ContentSharePayload(
      categoryLabel: 'Etkinlik',
      title: widget.title.trim(),
      subtitle: subtitle,
      description: trimmedDescription,
      imageUrl: widget.cover.trim(),
      feedText: '',
      shareUrl: 'https://www.dansmagazin.net/?route=/events/${widget.submissionId}',
      targetRoute: '/events/${widget.submissionId}',
      accentColor: AppTheme.orange,
    );
  }

  Future<void> _shareEvent() async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.shareAsImage(
        context,
        payload: _sharePayload(),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('visual_share_failed'))),
      );
    } finally {
      if (mounted) setState(() => _sharingBusy = false);
    }
  }

  Future<void> _shareEventLink() async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.shareLink(
        context,
        payload: _sharePayload(),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('link_share_failed'))),
      );
    } finally {
      if (mounted) setState(() => _sharingBusy = false);
    }
  }

  Future<void> _addEventToFeed() async {
    if (_sharingBusy) return;
    setState(() => _sharingBusy = true);
    try {
      await ContentShareService.addToFeed(
        sessionToken: widget.sessionToken,
        payload: _sharePayload(),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(I18n.t('added_to_feed'))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${I18n.t('feed_add_failed')} ${e.toString()}')),
      );
    } finally {
      if (mounted) setState(() => _sharingBusy = false);
    }
  }

  Future<void> _openShareActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined, color: Colors.white),
              title: Text(I18n.t('share_as_visual')),
              onTap: () => Navigator.of(context).pop('share'),
            ),
            ListTile(
              leading: const Icon(Icons.link_rounded, color: Colors.white),
              title: Text(I18n.t('share_as_link')),
              onTap: () => Navigator.of(context).pop('link'),
            ),
            if (widget.canAddToFeed)
              ListTile(
                leading: const Icon(Icons.dynamic_feed_rounded, color: Colors.white),
                title: Text(I18n.t('add_to_feed')),
                onTap: () => Navigator.of(context).pop('feed'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'link') {
      await _shareEventLink();
      return;
    }
    if (action == 'feed') {
      await _addEventToFeed();
      return;
    }
    await _shareEvent();
  }

  Future<void> _loadAttendees() async {
    if (!mounted) return;
    setState(() => _loadingAttendees = true);
    try {
      final items = await EventSocialApi.attendees(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() {
        _attendees = items;
        _joined = items.any((e) => e.isMe);
      });
    } catch (_) {
      // liste yüklenemezse ekran akışı bozulmasın
    } finally {
      if (mounted) setState(() => _loadingAttendees = false);
    }
  }

  EventCommentItem? get _myComment {
    for (final item in _comments) {
      if (item.isMine) return item;
    }
    return null;
  }

  Future<void> _loadComments() async {
    if (!mounted) return;
    setState(() {
      _loadingComments = true;
      _commentsError = null;
    });
    try {
      final result = await EventSocialApi.comments(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() {
        _comments = result.items;
        _commentsError = null;
        final myComment = result.myComment;
        if (_editingComment && myComment != null) {
          _commentCtrl.text = myComment.body;
        } else if (myComment == null) {
          _commentCtrl.clear();
        }
      });
    } on EventSocialApiException catch (e) {
      if (!mounted) return;
      setState(() => _commentsError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _commentsError = 'Yorumlar yüklenemedi.');
    } finally {
      if (mounted) setState(() => _loadingComments = false);
    }
  }

  Future<void> _loadRaffle() async {
    if (!mounted) return;
    setState(() {
      _loadingRaffle = true;
      _raffleError = null;
    });
    try {
      final result = await EventSocialApi.raffle(
        submissionId: widget.submissionId,
        sessionToken: widget.sessionToken,
      );
      if (!mounted) return;
      setState(() {
        _raffle = result.raffle;
        _raffleError = null;
      });
    } on EventSocialApiException catch (e) {
      if (!mounted) return;
      setState(() => _raffleError = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _raffleError = 'Çekiliş bilgisi yüklenemedi.');
    } finally {
      if (mounted) setState(() => _loadingRaffle = false);
    }
  }

  void _showMsg(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String? _extractFirstUrl(String raw) {
    final m = RegExp(r'https?://[^\s]+', caseSensitive: false).firstMatch(raw);
    return m?.group(0);
  }

  String _venueLabel() {
    final raw = widget.venue.trim();
    if (raw.isEmpty) return '';
    final url = _extractFirstUrl(raw);
    if (url == null) return raw;
    final cleaned = raw.replaceFirst(url, '').replaceAll(RegExp(r'\s+\n'), '\n').trim();
    return cleaned.isEmpty ? raw : cleaned;
  }

  Uri? _storedMapUri() {
    final direct = widget.venueMapUrl.trim();
    if (direct.isNotEmpty) {
      final normalized = direct.startsWith('http://') || direct.startsWith('https://')
          ? direct
          : (direct.startsWith('www.') ? 'https://$direct' : direct);
      final directUri = Uri.tryParse(normalized);
      if (directUri != null && directUri.hasScheme) return directUri;
    }

    final sharedUrl = _extractFirstUrl(widget.venue.trim());
    if (sharedUrl == null || sharedUrl.isEmpty) return null;
    final sharedUri = Uri.tryParse(sharedUrl);
    if (sharedUri != null && sharedUri.hasScheme) return sharedUri;
    return null;
  }

  Future<void> _openVenueInMaps() async {
    final uri = _storedMapUri();
    if (uri == null) {
      _showMsg('Konum linki bulunamadı.');
      return;
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (ok) return;
    } catch (_) {
      // external launch basarisizsa ayni linki varsayilan akisla tekrar dene.
    }
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.platformDefault);
      if (ok) return;
    } catch (_) {
      // son deneme de basarisizsa kullaniciya haber ver.
    }
    _showMsg('Harita açılamadı.');
  }

  DateTime? _parseEventDateForCalendar(String raw) {
    final v = raw.trim();
    if (v.isEmpty) return null;
    final normalized = v.replaceAll(' ', 'T');
    final direct = DateTime.tryParse(v) ?? DateTime.tryParse(normalized);
    if (direct != null) return direct;

    final yMd = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(v);
    if (yMd != null) {
      final y = int.tryParse(yMd.group(1)!);
      final m = int.tryParse(yMd.group(2)!);
      final d = int.tryParse(yMd.group(3)!);
      if (y != null && m != null && d != null) return DateTime(y, m, d);
    }

    final dmy = RegExp(r'^(\d{1,2})[.\-](\d{1,2})[.\-](\d{4})$').firstMatch(v);
    if (dmy != null) {
      final d = int.tryParse(dmy.group(1)!);
      final m = int.tryParse(dmy.group(2)!);
      final y = int.tryParse(dmy.group(3)!);
      if (y != null && m != null && d != null) return DateTime(y, m, d);
    }
    return null;
  }

  bool _eventHasTime(String raw) {
    return RegExp(r'\d{1,2}:\d{1,2}').hasMatch(raw);
  }

  Future<void> _addToCalendar() async {
    final start = _parseEventDateForCalendar(widget.eventDate);
    if (start == null) {
      _showMsg('Etkinlik tarihi geçersiz.');
      return;
    }
    final explicitEnd = _parseEventDateForCalendar(widget.endAt);
    final hasTime = _eventHasTime(widget.eventDate);
    final startDate = hasTime ? start : DateTime(start.year, start.month, start.day, 10, 0);
    final endDate = explicitEnd != null
        ? (_eventHasTime(widget.endAt)
            ? explicitEnd
            : DateTime(explicitEnd.year, explicitEnd.month, explicitEnd.day, 23, 59))
        : (hasTime ? startDate.add(const Duration(hours: 2)) : startDate.add(const Duration(hours: 1)));
    final details = widget.description.trim().isEmpty ? widget.title.trim() : widget.description.trim();
    final event = Event(
      title: widget.title.trim().isEmpty ? 'Etkinlik' : widget.title.trim(),
      description: details,
      location: _venueLabel().trim(),
      startDate: startDate,
      endDate: endDate,
      allDay: !hasTime,
      iosParams: const IOSParams(reminder: Duration(minutes: 30)),
      androidParams: const AndroidParams(emailInvites: <String>[]),
    );
    try {
      await CalendarService.addEvent(event);
    } catch (_) {
      _showMsg('Takvim açılamadı.');
    }
  }

  Future<void> _toggleAttend() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Katılım için önce giriş yapmalısın.');
      return;
    }
    setState(() => _changingAttendance = true);
    try {
      if (_joined) {
        await EventSocialApi.leave(submissionId: widget.submissionId, sessionToken: token);
      } else {
        await EventSocialApi.attend(submissionId: widget.submissionId, sessionToken: token);
      }
      await _loadAttendees();
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    } finally {
      if (mounted) setState(() => _changingAttendance = false);
    }
  }

  Future<void> _joinRaffle() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Çekilişe katılmak için önce giriş yapmalısın.');
      return;
    }
    setState(() => _joiningRaffle = true);
    try {
      final raffle = await EventSocialApi.joinRaffle(
        submissionId: widget.submissionId,
        sessionToken: token,
      );
      if (!mounted) return;
      setState(() => _raffle = raffle);
      _showMsg('Çekilişe katıldın. Başvurular durunca sonuçlar burada açıklanacak.');
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    } finally {
      if (mounted) setState(() => _joiningRaffle = false);
    }
  }

  Future<void> _addFriend(int targetAccountId) async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Arkadaş eklemek için önce giriş yapmalısın.');
      return;
    }
    try {
      final result = await EventSocialApi.addFriend(
        submissionId: widget.submissionId,
        targetAccountId: targetAccountId,
        sessionToken: token,
      );
      final status = (result['status'] ?? '').toString();
      if (mounted) {
        setState(() {
          _attendees = _attendees.map((a) {
            if (a.accountId != targetAccountId) return a;
            return a.copyWith(
              isFriend: status == 'already_friends' || status == 'friend',
              friendStatus: status == 'already_friends'
                  ? 'friend'
                  : (status.isEmpty ? EventSocialApi.statusPendingOutgoing : status),
              friendRequestId: (result['request_id'] as num?)?.toInt() ?? a.friendRequestId,
            );
          }).toList();
        });
      }
      _showMsg(status == 'already_friends' ? 'Zaten arkadaşsınız.' : 'Arkadaşlık isteği gönderildi.');
      await _loadAttendees();
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    }
  }

  Future<void> _openAttendeeProfile(EventAttendee attendee) async {
    if (attendee.isMe) return;
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Profil görüntülemek için önce giriş yapmalısın.');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FriendProfileScreen(
          sessionToken: token,
          friendAccountId: attendee.accountId,
        ),
      ),
    );
    if (!mounted) return;
    await _loadAttendees();
  }

  Future<void> _saveComment() async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Yorum yapmak için önce giriş yapmalısın.');
      return;
    }
    final body = _commentCtrl.text.trim();
    if (body.isEmpty) {
      _showMsg('Yorum alanı boş olamaz.');
      return;
    }
    final updating = _myComment != null;
    setState(() => _savingComment = true);
    try {
      final saved = await EventSocialApi.upsertComment(
        submissionId: widget.submissionId,
        sessionToken: token,
        body: body,
      );
      _commentCtrl.text = saved.body;
      _editingComment = false;
      await _loadComments();
      _showMsg(updating ? 'Yorumun güncellendi.' : 'Yorumun paylaşıldı.');
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    } finally {
      if (mounted) setState(() => _savingComment = false);
    }
  }

  Future<void> _deleteComment(EventCommentItem item) async {
    final token = widget.sessionToken.trim();
    if (token.isEmpty) {
      _showMsg('Yorum silmek için önce giriş yapmalısın.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceSecondary,
        title: const Text('Yorumu Sil'),
        content: const Text('Bu yorumu kaldırmak istediğine emin misin?'),
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
    if (confirmed != true) return;
    setState(() => _deletingCommentId = item.id);
    try {
      await EventSocialApi.deleteComment(
        submissionId: widget.submissionId,
        commentId: item.id,
        sessionToken: token,
      );
      if (_myComment?.id == item.id) {
        _commentCtrl.clear();
        _editingComment = false;
      }
      await _loadComments();
      _showMsg('Yorum silindi.');
    } on EventSocialApiException catch (e) {
      _showMsg(e.message);
    } finally {
      if (mounted) setState(() => _deletingCommentId = null);
    }
  }

  void _startEditingComment(EventCommentItem item) {
    _commentCtrl.text = item.body;
    setState(() => _editingComment = true);
  }

  void _cancelEditingComment() {
    setState(() => _editingComment = false);
    _commentCtrl.clear();
  }

  String _contentText() {
    if (_tab == 1) return widget.program.trim().isEmpty ? 'Program bilgisi girilmedi.' : widget.program.trim();
    if (_tab == 2) return _venueLabel().trim().isEmpty ? 'Konum bilgisi girilmedi.' : _venueLabel().trim();
    return widget.description.trim().isEmpty ? 'Detay bilgisi girilmedi.' : widget.description.trim();
  }

  @override
  Widget build(BuildContext context) {
    final buyUrl = _buyUrl();
    final venueLabel = _venueLabel();
    final canOpenMaps = _storedMapUri() != null;
    final canAddToCalendar = _parseEventDateForCalendar(widget.eventDate) != null;
    final posterMaxHeight = MediaQuery.of(context).size.height * 0.62;
    return Scaffold(
      backgroundColor: AppTheme.bgPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.bgPrimary,
        title: const Text('Etkinlik Detay'),
      ),
      body: SafeArea(
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
          children: [
          if (widget.cover.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: posterMaxHeight),
                child: Container(
                  color: AppTheme.surfaceElevated,
                  child: Image.network(
                    widget.cover,
                    width: double.infinity,
                    fit: BoxFit.contain,
                    alignment: Alignment.topCenter,
                    errorBuilder: (_, __, ___) => Container(
                      height: 220,
                      color: AppTheme.surfaceElevated,
                    ),
                  ),
                ),
              ),
            ),
          Container(
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.panel(tone: AppTone.events, radius: 22, elevated: true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _line(Icons.calendar_month, 'Başlangıç: ${_fmtDate(widget.eventDate)}'),
                if (widget.endAt.trim().isNotEmpty && widget.endAt.trim() != widget.eventDate.trim())
                  _line(Icons.schedule, 'Bitiş: ${_fmtDate(widget.endAt)}'),
                if (venueLabel.isNotEmpty) _line(Icons.location_on, venueLabel),
                if (widget.organizer.trim().isNotEmpty) _line(Icons.public, widget.organizer.trim()),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (canAddToCalendar)
            SizedBox(
              height: 46,
              child: OutlinedButton.icon(
                onPressed: _addToCalendar,
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppTheme.surfaceSecondary,
                  side: BorderSide(color: AppTheme.borderStrong.withOpacity(0.9)),
                  foregroundColor: AppTheme.textPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                icon: const Icon(Icons.event_available),
                label: const Text(
                  'Takvime Ekle',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          if (canAddToCalendar) const SizedBox(height: 12),
          SizedBox(
            height: 54,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                backgroundColor: _joined ? AppTheme.success.withOpacity(0.12) : AppTheme.surfaceSecondary,
                side: BorderSide(color: _joined ? AppTheme.success : AppTheme.orange.withOpacity(0.8)),
                foregroundColor: AppTheme.textPrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              onPressed: _changingAttendance ? null : _toggleAttend,
              child: _changingAttendance
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      _joined ? 'Katılımı Geri Çek' : 'Etkinliğe Katılacağım',
                      style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 50,
            child: OutlinedButton.icon(
              onPressed: _sharingBusy ? null : _openShareActions,
              style: OutlinedButton.styleFrom(
                backgroundColor: AppTheme.surfaceSecondary,
                side: BorderSide(color: AppTheme.borderStrong.withOpacity(0.9)),
                foregroundColor: AppTheme.textPrimary,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              icon: _sharingBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.ios_share_rounded),
              label: Text(
                I18n.t('share'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
          const SizedBox(height: 12),
          if (buyUrl.isNotEmpty)
            SizedBox(
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.orange,
                  foregroundColor: AppTheme.textPrimary,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
                ),
                onPressed: _openingCheckout
                    ? null
                    : () async {
                        setState(() => _openingCheckout = true);
                        try {
                          await _openCheckout();
                        } finally {
                          if (mounted) setState(() => _openingCheckout = false);
                        }
                      },
                child: _openingCheckout
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        'Bilet Satın Al',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                      ),
              ),
            ),
          if (_loadingRaffle || _raffle != null || (_raffleError ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 14),
            _raffleSection(),
          ],
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: AppTheme.panel(tone: AppTone.social, radius: 22, subtle: true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Etkinliğe Katılacaklar', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                if (_loadingAttendees)
                  const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator()))
                else if (_attendees.isEmpty)
                  const Text('Henüz katılımcı yok.')
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: _attendees
                        .map(
                          (a) => _EventAttendeeAvatar(
                            attendee: a,
                            onTap: () => _openAttendeeProfile(a),
                          ),
                        )
                        .toList(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(child: _tabBtn(0, 'Detaylar')),
              const SizedBox(width: 8),
              Expanded(child: _tabBtn(1, 'Program')),
              const SizedBox(width: 8),
              Expanded(child: _tabBtn(2, 'Konum')),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.panel(
              tone: _tab == 2 ? AppTone.events : AppTone.neutral,
              radius: 22,
              subtle: _tab != 2,
            ),
            child: _tab == 2
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      EmojiText(
                        _contentText(),
                        style: const TextStyle(color: AppTheme.textPrimary, height: 1.5),
                      ),
                      if (canOpenMaps) ...[
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            onPressed: _openVenueInMaps,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.orange,
                              foregroundColor: AppTheme.textPrimary,
                            ),
                            child: const Text(
                              'HARITADA AÇ',
                              style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 0.8),
                            ),
                          ),
                        ),
                      ],
                    ],
                  )
                : EmojiText(
                    _contentText(),
                    style: const TextStyle(color: AppTheme.textPrimary, height: 1.5),
                  ),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: AppTheme.panel(tone: AppTone.social, radius: 22, subtle: true),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Yorumlar',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                      ),
                    ),
                    if (_comments.isNotEmpty)
                      Text(
                        '${_comments.length} yorum',
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                if (widget.sessionToken.trim().isEmpty)
                  _commentNotice('Yorum yazmak için giriş yapmalısın.')
                else if (_editingComment || _myComment == null) ...[
                  TextField(
                    controller: _commentCtrl,
                    minLines: 3,
                    maxLines: 5,
                    decoration: InputDecoration(
                      hintText: 'Etkinlikle ilgili deneyimini paylaş',
                      filled: true,
                      fillColor: AppTheme.surfacePrimary,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: AppTheme.borderSoft),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: AppTheme.borderSoft),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide(color: AppTheme.pink.withOpacity(0.75)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Spacer(),
                      if (_editingComment)
                        TextButton(
                          onPressed: _savingComment ? null : _cancelEditingComment,
                          child: const Text('İptal'),
                        ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _savingComment ? null : _saveComment,
                        child: _savingComment
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(_editingComment ? 'Kaydet' : 'Yorum Yap'),
                      ),
                    ],
                  ),
                ] else
                  const SizedBox.shrink(),
                const SizedBox(height: 14),
                if (_loadingComments)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: CircularProgressIndicator(),
                    ),
                  )
                else if ((_commentsError ?? '').trim().isNotEmpty)
                  _commentNotice(_commentsError!)
                else if (_comments.isEmpty)
                  const Text(
                    'Henüz yorum yok. İlk deneyimi paylaşan sen olabilirsin.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  )
                else
                  ..._comments.map(_commentCard),
              ],
            ),
          ),
          ],
        ),
      ),
    );
  }

  Widget _raffleSection() {
    if (_loadingRaffle) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: AppTheme.panel(tone: AppTone.events, radius: 22, subtle: true),
        child: const Center(child: Padding(padding: EdgeInsets.all(8), child: CircularProgressIndicator())),
      );
    }
    if ((_raffleError ?? '').trim().isNotEmpty) {
      return _commentNotice(_raffleError!);
    }
    final raffle = _raffle;
    if (raffle == null) return const SizedBox.shrink();

    final stateLabel = switch (raffle.state) {
      'draft' => 'Başvuru Kapalı',
      'scheduled' => 'Başvuru Kapalı',
      'active' => 'Katılıma Açık',
      'closed' => 'Başvuru Durdu',
      'drawn' => 'Sonuçlandı',
      _ => 'Çekiliş',
    };
    final stateColor = switch (raffle.state) {
      'draft' => AppTheme.info,
      'scheduled' => AppTheme.info,
      'active' => AppTheme.orange,
      'closed' => AppTheme.warning,
      'drawn' => AppTheme.success,
      _ => AppTheme.textSecondary,
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: AppTheme.panel(tone: AppTone.events, radius: 22, subtle: true),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Etkinlik Çekilişi',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: stateColor.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  stateLabel,
                  style: TextStyle(
                    color: stateColor,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (raffle.startsAt.trim().isNotEmpty)
            Text(
              'Başvurular açıldı: ${_fmtDate(raffle.startsAt)}',
              style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
          if (raffle.endsAt.trim().isNotEmpty)
            Text(
              'Başvurular durdu: ${_fmtDate(raffle.endsAt)}',
              style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
            ),
          const SizedBox(height: 4),
          Text(
            '${raffle.entryCount} katılımcı • ${raffle.winnerCount} asıl • ${raffle.reserveCount} yedek',
            style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 10),
          if (raffle.state == 'draft' || raffle.state == 'scheduled')
            _commentNotice('Yönetici başvuruları henüz açmadı.')
          else if (raffle.state == 'active' && widget.sessionToken.trim().isEmpty)
            _commentNotice('Çekilişe katılmak için önce giriş yapmalısın.')
          else if (raffle.state == 'active' && raffle.hasJoined)
            _commentNotice('Çekilişe katıldın. Başvurular durduğunda sonuçlar burada açıklanacak.')
          else if (raffle.state == 'active')
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _joiningRaffle ? null : _joinRaffle,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.orange,
                  foregroundColor: AppTheme.textPrimary,
                ),
                icon: _joiningRaffle
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.celebration_outlined),
                label: Text(_joiningRaffle ? 'Kaydediliyor...' : 'Çekilişe Katıl'),
              ),
            )
          else if (raffle.state == 'closed')
            _commentNotice('Başvurular kapandı. Sonuçlar açıklandığında burada görünecek.')
          else
            const SizedBox.shrink(),
          if (raffle.primaryWinners.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Asıl Talihliler',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...raffle.primaryWinners.map(
              (winner) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: AppTheme.glassPanel(tone: AppTone.events, radius: 16),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppTheme.orange.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        winner.position.toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        winner.name.trim().isEmpty ? 'Kullanıcı' : winner.name.trim(),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (raffle.reserveWinners.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Text(
              'Yedek Talihliler',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            ...raffle.reserveWinners.map(
              (winner) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: AppTheme.glassPanel(tone: AppTone.events, radius: 16),
                child: Row(
                  children: [
                    Container(
                      width: 28,
                      height: 28,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: AppTheme.info.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        winner.position.toString(),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        winner.name.trim().isEmpty ? 'Kullanıcı' : winner.name.trim(),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _line(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14))),
        ],
      ),
    );
  }

  Widget _tabBtn(int val, String title) {
    final active = _tab == val;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: active ? AppTheme.orange.withOpacity(0.18) : AppTheme.surfaceSecondary,
        side: BorderSide(color: active ? AppTheme.orange : AppTheme.borderSoft),
        foregroundColor: AppTheme.textPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      ),
      onPressed: () => setState(() => _tab = val),
      child: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _commentNotice(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: AppTheme.glassPanel(tone: AppTone.social, radius: 16),
      child: EmojiText(
        text,
        style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
      ),
    );
  }

  Widget _commentCard(EventCommentItem item) {
    final meta = <String>[
      _fmtDate(item.updatedAt),
      if (item.isEdited) 'Düzenlendi',
      if (item.isMine) 'Sen',
    ];
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: AppTheme.glassPanel(tone: AppTone.social, radius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    EmojiText(
                      item.authorName.trim().isEmpty ? 'Kullanıcı' : item.authorName.trim(),
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      meta.join(' • '),
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.canEdit)
                    InkWell(
                      onTap: () => _startEditingComment(item),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.surfacePrimary.withOpacity(0.8),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.edit_outlined, size: 18),
                      ),
                    ),
                  if (item.canDelete) ...[
                    if (item.canEdit) const SizedBox(width: 8),
                    InkWell(
                      onTap: _deletingCommentId == item.id ? null : () => _deleteComment(item),
                      borderRadius: BorderRadius.circular(999),
                      child: Container(
                        width: 34,
                        height: 34,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.surfacePrimary.withOpacity(0.8),
                          shape: BoxShape.circle,
                        ),
                        child: _deletingCommentId == item.id
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.delete_outline_rounded, size: 18),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          EmojiText(
            item.body,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 14,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _EventAttendeeAvatar extends StatelessWidget {
  final EventAttendee attendee;
  final VoidCallback? onTap;

  const _EventAttendeeAvatar({
    required this.attendee,
    this.onTap,
  });

  Color get _ringColor {
    if (attendee.isMe) return AppTheme.cyan;
    switch (attendee.friendStatus) {
      case 'friend':
        return AppTheme.success;
      case 'pending_outgoing':
        return AppTheme.warning;
      case 'pending_incoming':
        return AppTheme.info;
      default:
        return AppTheme.borderSoft;
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = attendee.isMe ? '${attendee.name} (Sen)' : attendee.name;
    final avatarUrl = attendee.avatarUrl.trim();
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: onTap,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 54,
              height: 54,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _ringColor, width: 1.7),
              ),
              child: VerifiedAvatar(
                imageUrl: avatarUrl,
                label: label,
                isVerified: attendee.isVerified,
                radius: 23,
                backgroundColor: AppTheme.surfaceElevated,
                fallbackStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
            ),
            if (!attendee.isMe && attendee.friendStatus == 'none')
              Positioned(
                right: -1,
                top: -1,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppTheme.violet,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.bgPrimary, width: 1.5),
                  ),
                  child: const Icon(Icons.add, size: 10, color: Colors.white),
                ),
              ),
            if (!attendee.isMe && attendee.friendStatus == 'friend')
              Positioned(
                right: -1,
                top: -1,
                child: Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: AppTheme.success,
                    shape: BoxShape.circle,
                    border: Border.all(color: AppTheme.bgPrimary, width: 1.5),
                  ),
                  child: const Icon(Icons.check, size: 9, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
