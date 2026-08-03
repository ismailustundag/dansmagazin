import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_app_preview/services/guest_list_api.dart';

void main() {
  test('GuestListSummary parses master ownership metadata', () {
    final summary = GuestListSummary.fromJson({
      'guest_list_id': 5,
      'name': 'Ankara Genel',
      'member_count': 33,
      'is_master': true,
      'is_owned': false,
      'source_master_list_id': null,
      'created_at': '2026-08-03T09:00:00',
      'updated_at': '2026-08-03T09:00:00',
    });

    expect(summary.guestListId, 5);
    expect(summary.isMaster, isTrue);
    expect(summary.isOwned, isFalse);
    expect(summary.sourceMasterListId, isNull);
  });

  test('GuestListSummary parses profile copy source', () {
    final summary = GuestListSummary.fromJson({
      'guest_list_id': 7,
      'name': 'Ankara Genel Kopyası',
      'member_count': 33,
      'is_master': false,
      'is_owned': true,
      'source_master_list_id': 5,
      'created_at': '2026-08-03T09:00:00',
      'updated_at': '2026-08-03T09:00:00',
    });

    expect(summary.isMaster, isFalse);
    expect(summary.isOwned, isTrue);
    expect(summary.sourceMasterListId, 5);
  });
}
