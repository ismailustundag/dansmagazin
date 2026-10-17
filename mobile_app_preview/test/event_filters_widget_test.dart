import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_app_preview/screens/discover_screen.dart';
import 'package:mobile_app_preview/services/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.setLanguage('tr');
  });

  testWidgets('country, city, event type and dance filters reach API together',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final requests = <Uri>[];
    final client = MockClient((request) async {
      requests.add(request.url);
      final data = request.url.path.endsWith('filter-options')
          ? {
              'countries': [
                {'code': 'ES', 'name': 'İspanya'}
              ],
              'cities': [
                {
                  'country_code': 'ES',
                  'city_id': 'geo:valencia',
                  'city': 'Valencia'
                }
              ],
            }
          : {'items': [], 'news': []};
      return http.Response(jsonEncode(data), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await http.runWithClient(() async {
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(
              body: DiscoverScreen(sessionToken: '', canAddToFeed: false))));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Filtrele'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tüm ülkeler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('İspanya'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tüm Şehirler'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Valencia (ES)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tüm Etkinlik Türleri'));
      await tester.pumpAndSettle();
          await tester.scrollUntilVisible(find.text('Festivaller'), 80,
          scrollable: find.byType(Scrollable).last);
          await tester.tap(find.text('Festivaller'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Salsa'));
      await tester.tap(find.text('Salsa'));
      await tester.ensureVisible(find.text('Uygula'));
      await tester.tap(find.text('Uygula'));
      await tester.pumpAndSettle();
      final query =
          requests.lastWhere((uri) => uri.path == '/events').queryParameters;
      expect(query['country_code'], 'ES');
      expect(query['city_id'], 'geo:valencia');
      expect(query['event_kind'], 'festival');
      expect(query['dance_styles'], 'salsa');
      expect(query.containsKey('city'), false);
      expect(tester.takeException(), isNull);
    }, () => client);
  });
}
