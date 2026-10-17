import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_app_preview/screens/event_location_picker.dart';
import 'package:mobile_app_preview/services/event_locations_api.dart';

void main() {
  testWidgets(
      'legacy locality survives editing; new international locality accepted on mobile',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    EventLocation? selected;
    final client = MockClient((_) async =>
        http.Response(jsonEncode({'countries': [], 'cities': []}), 200));
    await http.runWithClient(() async {
      await tester.pumpWidget(MaterialApp(
          home: Builder(
              builder: (context) => Scaffold(
                      body: TextButton(
                    onPressed: () async {
                      selected = await pickEventLocation(context,
                          const EventLocation(city: 'Massanassa / Valencia'));
                    },
                    child: const Text('Open'),
                  )))));
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Massanassa / Valencia'), findsOneWidget);
      await tester.tap(find.text('Seç'));
      await tester.pumpAndSettle();
      expect(selected!.city, 'Massanassa / Valencia');
      expect(selected!.countryCode, '');
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField).at(0), 'TH');
      await tester.enterText(find.byType(TextFormField).at(1), 'Bangkok');
      await tester.tap(find.text('Seç'));
      await tester.pumpAndSettle();
      expect(selected!.city, 'Bangkok');
      expect(selected!.countryCode, 'TH');
      expect(tester.takeException(), isNull);
    }, () => client);
  });
}
