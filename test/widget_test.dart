import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:olympus/app.dart';

void main() {
  group('AIChatApp basic smoke tests', () {
    testWidgets('App boots and shows expected core UI elements', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const OlympusApp());
      await tester.pumpAndSettle();

      // App title (AppBar)
      expect(find.text('AI Orchestrator'), findsOneWidget);

      // Primary action buttons in the AppBar
      expect(find.byIcon(Icons.brightness_6), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.byIcon(Icons.save_outlined), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // Send button & input field
      expect(find.byIcon(Icons.send), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.textContaining('Type a message'), findsOneWidget);

      // Initial system banner message inserted by ChatController constructor.
      expect(
        find.textContaining('AI Orchestrator v0.1.0 initialized'),
        findsOneWidget,
      );
    });

    testWidgets('Theme toggle updates MaterialApp.themeMode', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(const OlympusApp());
      await tester.pumpAndSettle();

      final materialAppFinder = find.byType(MaterialApp);

      MaterialApp getMaterialApp() =>
          tester.widget<MaterialApp>(materialAppFinder);

      // Initial themeMode should be dark (as defined in AppSettingsController)
      expect(getMaterialApp().themeMode, ThemeMode.dark);

      // Tap brightness / theme toggle icon
      await tester.tap(find.byIcon(Icons.brightness_6));
      await tester.pumpAndSettle();

      // Theme should now be light
      expect(getMaterialApp().themeMode, ThemeMode.light);

      // Toggle back (optional assertion)
      await tester.tap(find.byIcon(Icons.brightness_6));
      await tester.pumpAndSettle();
      expect(getMaterialApp().themeMode, ThemeMode.dark);
    });
  });
}
