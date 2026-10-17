import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mobile_app_preview/screens/auth_screen.dart';
import 'package:mobile_app_preview/services/app_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await AppSettings.setLanguage('tr');
  });

  testWidgets('language can be selected before sign in or registration',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));
    await tester.pump();

    expect(find.text('🇹🇷'), findsOneWidget);
    expect(find.text('🇬🇧'), findsOneWidget);
    expect(find.text('🇪🇸'), findsOneWidget);
    expect(find.text('Türkçe'), findsNothing);
    expect(find.text('English'), findsNothing);
    expect(find.text('Español'), findsNothing);
    expect(find.text('Uygulama dilini seçin'), findsOneWidget);
    expect(find.text('Giriş'), findsOneWidget);

    await tester.tap(find.text('🇪🇸'));
    await tester.pump(const Duration(milliseconds: 50));

    expect(AppSettings.language.value, 'es');
    expect(find.text('Elige el idioma'), findsOneWidget);
    expect(find.text('Acceder'), findsOneWidget);
    expect(find.text('Registro'), findsOneWidget);
    expect(find.text('Olvidé mi contraseña'), findsOneWidget);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.language'), 'es');
  });
}
