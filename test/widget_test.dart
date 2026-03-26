// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:zabbix_mobile_app/core/app_settings.dart';
import 'package:zabbix_mobile_app/main.dart';

void main() {
  testWidgets('App boots with settings', (WidgetTester tester) async {
    final settings = AppSettings();
    await tester.pumpWidget(
      MyApp(settings: settings, enableFcmHandlers: false),
    );
    expect(find.byType(MyApp), findsOneWidget);
  });
}
