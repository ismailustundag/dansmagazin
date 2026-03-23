import 'dart:convert';

import 'package:http/http.dart' as http;

import 'error_message.dart';

class EventSocialApiException implements Exception {
  final String message;
  EventSocialApiException(this.message);

  @override
  String toString() => message;
}

class EventAttendee {
  final int accountId;
  final String name;
  final String avatarUrl;
  final bool isMe;
  final bool isFriend;
  final String friendStatus;
  final int? friendRequestId;

  const EventAttendee({
    required this.accountId,
    required this.name,
    required this.avatarUrl,
    required this.isMe,
    required this.isFriend,
    required this.friendStatus,
    required this.friendRequestId,
  });

  factory EventAttendee.fromJson(Map<String, dynamic> json) {
    return EventAttendee(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isMe: (json['is_me'] == true),
      isFriend: (json['is_friend'] == true),
      friendStatus: (json['friend_status'] ?? 'none').toString(),
      friendRequestId: (json['friend_request_id'] as num?)?.toInt(),
    );
  }

  EventAttendee copyWith({
    int? accountId,
    String? name,
    String? avatarUrl,
    bool? isMe,
    bool? isFriend,
    String? friendStatus,
    int? friendRequestId,
  }) {
    return EventAttendee(
      accountId: accountId ?? this.accountId,
      name: name ?? this.name,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      isMe: isMe ?? this.isMe,
      isFriend: isFriend ?? this.isFriend,
      friendStatus: friendStatus ?? this.friendStatus,
      friendRequestId: friendRequestId ?? this.friendRequestId,
    );
  }
}

class EventCommentItem {
  final int id;
  final int threadSubmissionId;
  final int authorAccountId;
  final String authorName;
  final bool authorIsVerified;
  final String body;
  final String createdAt;
  final String updatedAt;
  final bool isMine;
  final bool canEdit;
  final bool canDelete;
  final bool isEdited;

  const EventCommentItem({
    required this.id,
    required this.threadSubmissionId,
    required this.authorAccountId,
    required this.authorName,
    required this.authorIsVerified,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.isMine,
    required this.canEdit,
    required this.canDelete,
    required this.isEdited,
  });

  factory EventCommentItem.fromJson(Map<String, dynamic> json) {
    return EventCommentItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      threadSubmissionId: (json['thread_submission_id'] as num?)?.toInt() ?? 0,
      authorAccountId: (json['author_account_id'] as num?)?.toInt() ?? 0,
      authorName: (json['author_name'] ?? '').toString(),
      authorIsVerified: json['author_is_verified'] == true,
      body: (json['body'] ?? '').toString(),
      createdAt: (json['created_at'] ?? '').toString(),
      updatedAt: (json['updated_at'] ?? '').toString(),
      isMine: json['is_mine'] == true,
      canEdit: json['can_edit'] == true,
      canDelete: json['can_delete'] == true,
      isEdited: json['is_edited'] == true,
    );
  }
}

class EventCommentsResult {
  final List<EventCommentItem> items;
  final bool canComment;
  final bool canModerate;
  final String eligibility;
  final EventCommentItem? myComment;

  const EventCommentsResult({
    required this.items,
    required this.canComment,
    required this.canModerate,
    required this.eligibility,
    required this.myComment,
  });
}

class EventRaffleWinner {
  final int position;
  final int accountId;
  final String name;

  const EventRaffleWinner({
    required this.position,
    required this.accountId,
    required this.name,
  });

  factory EventRaffleWinner.fromJson(Map<String, dynamic> json) {
    return EventRaffleWinner(
      position: (json['position'] as num?)?.toInt() ?? 0,
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
    );
  }
}

class EventRaffleDetail {
  final int id;
  final int submissionId;
  final String startsAt;
  final String endsAt;
  final int winnerCount;
  final int entryCount;
  final String state;
  final bool isDrawn;
  final bool hasJoined;
  final bool canJoin;
  final bool canManage;
  final bool canDraw;
  final String drawnAt;
  final List<EventRaffleWinner> winners;

  const EventRaffleDetail({
    required this.id,
    required this.submissionId,
    required this.startsAt,
    required this.endsAt,
    required this.winnerCount,
    required this.entryCount,
    required this.state,
    required this.isDrawn,
    required this.hasJoined,
    required this.canJoin,
    required this.canManage,
    required this.canDraw,
    required this.drawnAt,
    required this.winners,
  });

  factory EventRaffleDetail.fromJson(Map<String, dynamic> json) {
    return EventRaffleDetail(
      id: (json['id'] as num?)?.toInt() ?? 0,
      submissionId: (json['submission_id'] as num?)?.toInt() ?? 0,
      startsAt: (json['starts_at'] ?? '').toString(),
      endsAt: (json['ends_at'] ?? '').toString(),
      winnerCount: (json['winner_count'] as num?)?.toInt() ?? 0,
      entryCount: (json['entry_count'] as num?)?.toInt() ?? 0,
      state: (json['state'] ?? '').toString(),
      isDrawn: json['is_drawn'] == true,
      hasJoined: json['has_joined'] == true,
      canJoin: json['can_join'] == true,
      canManage: json['can_manage'] == true,
      canDraw: json['can_draw'] == true,
      drawnAt: (json['drawn_at'] ?? '').toString(),
      winners: (json['winners'] as List<dynamic>? ?? [])
          .whereType<Map<String, dynamic>>()
          .map(EventRaffleWinner.fromJson)
          .toList(),
    );
  }
}

class EventRaffleResult {
  final bool canManage;
  final EventRaffleDetail? raffle;

  const EventRaffleResult({
    required this.canManage,
    required this.raffle,
  });
}

class FriendRequestItem {
  final int requestId;
  final int peerAccountId;
  final String peerName;
  final String peerEmail;
  final bool peerIsVerified;
  final String createdAt;

  const FriendRequestItem({
    required this.requestId,
    required this.peerAccountId,
    required this.peerName,
    required this.peerEmail,
    required this.peerIsVerified,
    required this.createdAt,
  });

  factory FriendRequestItem.fromJson(Map<String, dynamic> json) {
    return FriendRequestItem(
      requestId: (json['request_id'] as num?)?.toInt() ?? 0,
      peerAccountId: (json['peer_account_id'] as num?)?.toInt() ?? 0,
      peerName: (json['peer_name'] ?? '').toString(),
      peerEmail: (json['peer_email'] ?? '').toString(),
      peerIsVerified: json['peer_is_verified'] == true,
      createdAt: (json['created_at'] ?? '').toString(),
    );
  }
}

class SocialUserItem {
  final int accountId;
  final String name;
  final String email;
  final String avatarUrl;
  final bool isVerified;
  final bool isFriend;
  final String friendStatus;
  final int? friendRequestId;

  const SocialUserItem({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.isVerified,
    required this.isFriend,
    required this.friendStatus,
    required this.friendRequestId,
  });

  factory SocialUserItem.fromJson(Map<String, dynamic> json) {
    return SocialUserItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      isVerified: json['is_verified'] == true,
      isFriend: json['is_friend'] == true,
      friendStatus: (json['friend_status'] ?? 'none').toString(),
      friendRequestId: (json['friend_request_id'] as num?)?.toInt(),
    );
  }
}

class SocialUserSearchResult {
  final List<SocialUserItem> items;
  final bool hasMore;
  final int? nextOffset;
  final int minQueryLength;

  const SocialUserSearchResult({
    required this.items,
    required this.hasMore,
    required this.nextOffset,
    required this.minQueryLength,
  });
}

class BlockedUserItem {
  final int accountId;
  final String name;
  final String email;
  final String avatarUrl;
  final String blockedAt;

  const BlockedUserItem({
    required this.accountId,
    required this.name,
    required this.email,
    required this.avatarUrl,
    required this.blockedAt,
  });

  factory BlockedUserItem.fromJson(Map<String, dynamic> json) {
    return BlockedUserItem(
      accountId: (json['account_id'] as num?)?.toInt() ?? 0,
      name: (json['name'] ?? '').toString(),
      email: (json['email'] ?? '').toString(),
      avatarUrl: (json['avatar_url'] ?? '').toString(),
      blockedAt: (json['blocked_at'] ?? '').toString(),
    );
  }
}

class EventSocialApi {
  static const String _base = 'https://api2.dansmagazin.net';

  static const String statusPendingOutgoing = 'pending_outgoing';

  static Future<List<EventAttendee>> attendees({
    required int submissionId,
    String? sessionToken,
  }) async {
    final headers = <String, String>{};
    final t = (sessionToken ?? '').trim();
    if (t.isNotEmpty) headers['Authorization'] = 'Bearer $t';

    final resp = await http.get(
      Uri.parse('$_base/events/$submissionId/attendees'),
      headers: headers,
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException('Katılımcılar alınamadı');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => EventAttendee.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<EventCommentsResult> comments({
    required int submissionId,
    String? sessionToken,
  }) async {
    final headers = <String, String>{};
    final t = (sessionToken ?? '').trim();
    if (t.isNotEmpty) headers['Authorization'] = 'Bearer $t';
    final resp = await http.get(
      Uri.parse('$_base/events/$submissionId/comments'),
      headers: headers,
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Yorumlar alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(EventCommentItem.fromJson)
        .toList();
    EventCommentItem? myComment;
    for (final item in items) {
      if (item.isMine) {
        myComment = item;
        break;
      }
    }
    return EventCommentsResult(
      items: items,
      canComment: body['can_comment'] == true,
      canModerate: body['can_moderate'] == true,
      eligibility: (body['eligibility'] ?? '').toString(),
      myComment: myComment,
    );
  }

  static Future<EventCommentItem> upsertComment({
    required int submissionId,
    required String sessionToken,
    required String body,
  }) async {
    final resp = await http.put(
      Uri.parse('$_base/events/$submissionId/comments/me'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'body': body}),
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Yorum kaydedilemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    final item = map['item'];
    if (item is! Map<String, dynamic>) {
      throw EventSocialApiException('Geçersiz yorum cevabı');
    }
    return EventCommentItem.fromJson(item);
  }

  static Future<void> deleteComment({
    required int submissionId,
    required int commentId,
    required String sessionToken,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/events/$submissionId/comments/$commentId'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Yorum silinemedi'));
    }
  }

  static Future<void> attend({
    required int submissionId,
    required String sessionToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/$submissionId/attend'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Katılım kaydedilemedi'));
    }
  }

  static Future<void> leave({
    required int submissionId,
    required String sessionToken,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/events/$submissionId/attend'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Katılım iptal edilemedi'));
    }
  }

  static Future<EventRaffleResult> raffle({
    required int submissionId,
    String? sessionToken,
  }) async {
    final headers = <String, String>{};
    final t = (sessionToken ?? '').trim();
    if (t.isNotEmpty) headers['Authorization'] = 'Bearer $t';
    final resp = await http.get(
      Uri.parse('$_base/events/$submissionId/raffle'),
      headers: headers,
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Çekiliş bilgisi alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raffleJson = body['raffle'];
    return EventRaffleResult(
      canManage: body['can_manage'] == true,
      raffle: raffleJson is Map<String, dynamic> ? EventRaffleDetail.fromJson(raffleJson) : null,
    );
  }

  static Future<EventRaffleDetail> upsertRaffle({
    required int submissionId,
    required String sessionToken,
    required String startsAt,
    required String endsAt,
    required int winnerCount,
  }) async {
    final resp = await http.put(
      Uri.parse('$_base/events/$submissionId/raffle'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'starts_at': startsAt,
        'ends_at': endsAt,
        'winner_count': winnerCount,
      }),
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Çekiliş kaydedilemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raffleJson = body['raffle'];
    if (raffleJson is! Map<String, dynamic>) {
      throw EventSocialApiException('Geçersiz çekiliş cevabı');
    }
    return EventRaffleDetail.fromJson(raffleJson);
  }

  static Future<EventRaffleDetail> joinRaffle({
    required int submissionId,
    required String sessionToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/$submissionId/raffle/join'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Çekilişe katılım kaydedilemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raffleJson = body['raffle'];
    if (raffleJson is! Map<String, dynamic>) {
      throw EventSocialApiException('Geçersiz çekiliş cevabı');
    }
    return EventRaffleDetail.fromJson(raffleJson);
  }

  static Future<EventRaffleDetail> drawRaffle({
    required int submissionId,
    required String sessionToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/$submissionId/raffle/draw'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Kazananlar belirlenemedi'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final raffleJson = body['raffle'];
    if (raffleJson is! Map<String, dynamic>) {
      throw EventSocialApiException('Geçersiz çekiliş cevabı');
    }
    return EventRaffleDetail.fromJson(raffleJson);
  }

  static Future<Map<String, dynamic>> addFriend({
    required int submissionId,
    required int targetAccountId,
    required String sessionToken,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/events/$submissionId/attendees/$targetAccountId/friend'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Arkadaş eklenemedi'));
    }
    try {
      final body = jsonDecode(resp.body);
      if (body is Map<String, dynamic>) return body;
    } catch (_) {}
    return const {};
  }

  static Future<List<FriendRequestItem>> friendRequests({
    required String sessionToken,
    String direction = 'incoming',
  }) async {
    final resp = await http.get(
      Uri.parse('$_base/profile/friend-requests?direction=$direction'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Arkadaşlık istekleri alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .map((e) => FriendRequestItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  static Future<void> acceptFriendRequest({
    required String sessionToken,
    required int requestId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friend-requests/$requestId/accept'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'İstek kabul edilemedi'));
    }
  }

  static Future<void> rejectFriendRequest({
    required String sessionToken,
    required int requestId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friend-requests/$requestId/reject'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'İstek reddedilemedi'));
    }
  }

  static Future<void> cancelFriendRequest({
    required String sessionToken,
    required int requestId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/friend-requests/$requestId/cancel'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'İstek geri çekilemedi'));
    }
  }

  static Future<SocialUserSearchResult> searchUsers({
    required String sessionToken,
    required String query,
    int limit = 20,
    int offset = 0,
  }) async {
    final q = query.trim();
    final lim = limit < 1 ? 1 : (limit > 50 ? 50 : limit);
    final off = offset < 0 ? 0 : offset;
    final resp = await http.get(
      Uri.parse('$_base/profile/users/search?q=${Uri.encodeQueryComponent(q)}&limit=$lim&offset=$off'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Kullanıcı araması yapılamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final items = (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(SocialUserItem.fromJson)
        .toList();
    return SocialUserSearchResult(
      items: items,
      hasMore: body['has_more'] == true,
      nextOffset: (body['next_offset'] as num?)?.toInt(),
      minQueryLength: (body['min_query_length'] as num?)?.toInt() ?? 2,
    );
  }

  static Future<Map<String, dynamic>> sendFriendRequestDirect({
    required String sessionToken,
    required int targetAccountId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friends/$targetAccountId/request'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Arkadaşlık isteği gönderilemedi'));
    }
    try {
      final body = jsonDecode(resp.body);
      if (body is Map<String, dynamic>) return body;
    } catch (_) {}
    return const {};
  }

  static Future<Map<String, dynamic>> connectFriendByQr({
    required String sessionToken,
    required String payload,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friends/qr-add'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'payload': payload.trim()}),
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'QR ile arkadaş eklenemedi'));
    }
    try {
      final body = jsonDecode(resp.body);
      if (body is Map<String, dynamic>) return body;
    } catch (_) {}
    return const {};
  }

  static Future<void> removeFriend({
    required String sessionToken,
    required int friendAccountId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/friends/$friendAccountId'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Arkadaş silinemedi'));
    }
  }

  static Future<void> blockUser({
    required String sessionToken,
    required int targetAccountId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friends/$targetAccountId/block'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Kullanıcı engellenemedi'));
    }
  }

  static Future<void> reportUser({
    required String sessionToken,
    required int targetAccountId,
    String reason = '',
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/profile/friends/$targetAccountId/report'),
      headers: {
        'Authorization': 'Bearer ${sessionToken.trim()}',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'reason': reason.trim()}),
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Kullanıcı şikayet edilemedi'));
    }
  }

  static Future<List<BlockedUserItem>> blockedUsers({
    required String sessionToken,
    int limit = 200,
  }) async {
    final lim = limit < 1 ? 1 : (limit > 500 ? 500 : limit);
    final resp = await http.get(
      Uri.parse('$_base/profile/blocks?limit=$lim'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Engellenen kullanıcılar alınamadı'));
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    return (body['items'] as List<dynamic>? ?? [])
        .whereType<Map<String, dynamic>>()
        .map(BlockedUserItem.fromJson)
        .toList();
  }

  static Future<void> unblockUser({
    required String sessionToken,
    required int targetAccountId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/profile/blocks/$targetAccountId'),
      headers: {'Authorization': 'Bearer ${sessionToken.trim()}'},
    );
    if (resp.statusCode != 200) {
      throw EventSocialApiException(_parseError(resp.body, fallback: 'Kullanıcının engeli kaldırılamadı'));
    }
  }

  static String _parseError(String body, {required String fallback}) {
    return parseApiErrorBody(body, fallback: fallback);
  }
}
