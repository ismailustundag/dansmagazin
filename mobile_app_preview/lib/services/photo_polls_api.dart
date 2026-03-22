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

class PhotoPollQuestion {
  final int id;
  final String text;
  final int? myOptionId;
  final List<PhotoPollOption> options;

  const PhotoPollQuestion({
    required this.id,
    required this.text,
    required this.myOptionId,
    required this.options,
  });

  factory PhotoPollQuestion.fromJson(Map<String, dynamic> json) {
    return PhotoPollQuestion(
      id: (json['id'] as num?)?.toInt() ?? 0,
      text: (json['text'] ?? '').toString(),
      myOptionId: (json['my_option_id'] as num?)?.toInt(),
      options: (json['options'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(PhotoPollOption.fromJson)
          .toList(),
    );
  }
}

class PhotoPollDraftQuestion {
  final String question;
  final List<String> options;

  const PhotoPollDraftQuestion({
    required this.question,
    required this.options,
  });
}

class PhotoPoll {
  final int id;
  final String title;
  final int questionCount;
  final bool showResultsAfterVote;
  final bool isActive;
  final bool hasVoted;
  final bool canViewResults;
  final int? totalVotes;
  final String createdAt;
  final List<PhotoPollQuestion> questions;

  const PhotoPoll({
    required this.id,
    required this.title,
    required this.questionCount,
    required this.showResultsAfterVote,
    required this.isActive,
    required this.hasVoted,
    required this.canViewResults,
    required this.totalVotes,
    required this.createdAt,
    required this.questions,
  });

  factory PhotoPoll.fromJson(Map<String, dynamic> json) {
    final questionsJson = (json['questions'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PhotoPollQuestion.fromJson)
        .toList();
    final legacyOptions = (json['options'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PhotoPollOption.fromJson)
        .toList();
    final title = (json['question'] ?? '').toString();
    final fallbackQuestions = questionsJson.isNotEmpty
        ? questionsJson
        : [
            PhotoPollQuestion(
              id: (json['id'] as num?)?.toInt() ?? 0,
              text: title,
              myOptionId: (json['my_option_id'] as num?)?.toInt(),
              options: legacyOptions,
            ),
          ];
    return PhotoPoll(
      id: (json['id'] as num?)?.toInt() ?? 0,
      title: title,
      questionCount: (json['question_count'] as num?)?.toInt() ?? fallbackQuestions.length,
      showResultsAfterVote: json['show_results_after_vote'] == true,
      isActive: json['is_active'] != false,
      hasVoted: json['has_voted'] == true,
      canViewResults: json['can_view_results'] == true,
      totalVotes: (json['total_votes'] as num?)?.toInt(),
      createdAt: (json['created_at'] ?? '').toString(),
      questions: fallbackQuestions,
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

  static Future<PhotoPoll> fetchOne(
    String sessionToken, {
    required int pollId,
    bool includeInactive = false,
  }) async {
    final uri = Uri.parse('$_base/$pollId').replace(
      queryParameters: {
        if (includeInactive) 'include_inactive': 'true',
      },
    );
    final resp = await http.get(uri, headers: _headers(sessionToken));
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Anket yüklenemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoPoll.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<PhotoPoll> submit(
    String sessionToken, {
    required int pollId,
    required Map<int, int> answers,
  }) async {
    final bodyAnswers = answers.entries
        .map((entry) => {'question_id': entry.key, 'option_id': entry.value})
        .toList();
    final resp = await http.post(
      Uri.parse('$_base/$pollId/submit'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'answers': bodyAnswers}),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Oy gönderilemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoPoll.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<PhotoPoll> create(
    String sessionToken, {
    required String title,
    required List<PhotoPollDraftQuestion> questions,
    required bool showResultsAfterVote,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/admin'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({
        'title': title,
        'questions': questions
            .map(
              (question) => {
                'question': question.question,
                'options': question.options,
              },
            )
            .toList(),
        'show_results_after_vote': showResultsAfterVote,
      }),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Anket oluşturulamadı'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoPoll.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<PhotoPoll> setActive(
    String sessionToken, {
    required int pollId,
    required bool active,
  }) async {
    final resp = await http.post(
      Uri.parse('$_base/$pollId/state'),
      headers: _headers(sessionToken, jsonBody: true),
      body: jsonEncode({'active': active}),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Anket durumu güncellenemedi'));
    }
    final map = jsonDecode(resp.body) as Map<String, dynamic>;
    return PhotoPoll.fromJson((map['item'] as Map<String, dynamic>? ?? const {}));
  }

  static Future<void> delete(
    String sessionToken, {
    required int pollId,
  }) async {
    final resp = await http.delete(
      Uri.parse('$_base/$pollId'),
      headers: _headers(sessionToken),
    );
    if (resp.statusCode != 200) {
      throw Exception(_parseError(resp.body, fallback: 'Anket silinemedi'));
    }
  }
}
