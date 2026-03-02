import 'package:flutter/foundation.dart';

import 'notifications_api.dart';

class NotificationCenter {
  static const NotificationSummary _zero = NotificationSummary(
    totalCount: 0,
    incomingFriendRequestsCount: 0,
    unreadMessagesCount: 0,
  );

  static final ValueNotifier<NotificationSummary> summary =
      ValueNotifier<NotificationSummary>(_zero);
  static final ValueNotifier<int> totalCount = ValueNotifier<int>(0);

  static void setSummary(NotificationSummary s) {
    summary.value = s;
    totalCount.value = s.totalCount;
  }

  static void clear() {
    setSummary(_zero);
  }

  static Future<void> refresh(String sessionToken) async {
    final token = sessionToken.trim();
    if (token.isEmpty) {
      clear();
      return;
    }
    try {
      final s = await NotificationsApi.fetchSummary(token);
      setSummary(s);
    } catch (_) {
      // Keep the latest known value on transient errors.
    }
  }
}
