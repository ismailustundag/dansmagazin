import 'dart:convert';

import 'package:http/http.dart' as http;

class PhotoPollOption {
  final int id;
  final String text;
  final bool myVote;
  final int? voteCount;
  final double? percentage;

  const PhotoPollOption({
    required this.id,
    required this.text,
    required this.myVote,
    required this.voteCount,
    required this.percentage,
  });

  factory PhotoPollOption.fromJson(Map<String, dynamic> json) {
    final rawPercentage = json['percentage'];
    return PhotoPollOption(
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: (json['text'] ?? '').toString(),
      myVote: json['my_vote'] == true,
      voteCount: (json['vote_count'] as num?)?.toInt(),
      percentage: rawPercentage is num ? rawPercentage.toDouble() : null,
    );
  }
}

class PhotoPoll {
  final int id;
  final String question;
  final bool showResultsAfterVote;
  final bool isActive;
  final bool hasVoted;
  final int? myOptionId;
  final bool canViewResults;
  final int? totalVotes;
  final String createdAt;
  final List<PhotoPollOption> options;

  const PhotoPoll({
    required this.id,
    required this.question,
    required this.showResultsAfterVote,
    required this.isActive,
    required this.hasVoted,
    required this.myOptionId,
    required this.canViewResults,
    required this.totalVotes,
    required this.createdAt,
    required this.options,
  });

  factory PhotoPoll.fromJson(Map<String, dynamic> json) {
    return PhotoPoll(
      id: (json['id'] as num?)?.toInt() ?? 0,
      question: (json['question'] ?? '').toString(),
      showResultsAfterVote: json['show_results_after_vote'] == true,
      isActive: json['is_active'] != false,
      hasVoted: json['has_voted'] == true,
      myOptionId: (json['my_option_id'] as num?)?.toInt(),
      canViewResults: json['can_view_results'] == true,
      totalVotes: (json['total_votes'] as num?)?.toInt(),
      createdAt: (json['created_at'] ?? '').toString(),
      options: (json['options'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PhotoPollOption.fromJson)
          .toList(),
    );
  }
}

class PhotoPollsApi {
  static const String _base = 'https://api2.dansmagazin.net/photos/polls';

  static Map<String, String> _headers(String sessionToken, {bool jsonBody = false}) {
    return {
      if (sessionToken.trim().isNotEmpty) 'Authorization': 'Bearer ${sessionToken.trim()}',
      if (jsonBody) 'Content-Type': 'application/json',
    };
  }

  static String _parseError(String body, {required String fallback}) {
    try {
      final raw = jsonDecode(body);
      if (raw is Map<String, dynamic>) {
        final detail = (raw['detail'] ?? raw['message'] ?? raw['error'] ?? '').toString().trim();
        if (detail.isNotEmpty) return detail;
      }
    } catch (_) {}
    return fallback;
  }

  static Future<List<PhotoPoll>> fetch(
    String sessionToken, {
    bool includeInactive = false,
    int limit = 50,
  }) async {
    final uri = Uri.parse(_base).replace(
      queryParameters: {
        'limit': '$limit',
        if (includeInactive) 'include_inactive': 'true',
      },
    );
    final resp = await http.get(uri, headers: _headers(sessionToken));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Anketler yüklenemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return (map['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PhotoPoll.fromJson)
        .toList();
  }

  static Future<PhotoPoll> vote(
    String sessionToken, {
    required int pollId,
    required int optionId,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/$pollId/vote'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'option_id': optionId}),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Oy gönderilemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoPoll.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<PhotoPoll> create(
    String sessionToken, {
    required String question,
    required List<String> options,
    required bool showResultsAfterVote,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/admin'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({
        'question': question,
        'options': options,
        'show_results_after_vote': showResultsAfterVote,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Anket oluşturulamadı'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoPoll.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }
}
