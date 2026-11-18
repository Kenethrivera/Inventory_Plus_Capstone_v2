import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
    );
  });

  Future<void> showLogin(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(controller: InventoryController())),
    );
  }

  testWidgets('Tab moves from username to password', (tester) async {
    await showLogin(tester);
    final fields = find.byType(TextFormField);
    final usernameFocus = tester
        .widget<EditableText>(
          find.descendant(
            of: fields.at(0),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode;
    final passwordFocus = tester
        .widget<EditableText>(
          find.descendant(
            of: fields.at(1),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode;

    await tester.tap(fields.at(0));
    await tester.pump();
    expect(usernameFocus.hasFocus, isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(passwordFocus.hasFocus, isTrue);
  });

  testWidgets('short nonempty credentials pass local validation', (
    tester,
  ) async {
    await showLogin(tester);
    final fields = find.byType(TextFormField);
    final username = tester.widget<TextFormField>(fields.at(0));
    final password = tester.widget<TextFormField>(fields.at(1));

    expect(username.validator!('ab'), isNull);
    expect(password.validator!('12345'), isNull);
    expect(username.validator!(''), 'Username is required');
    expect(password.validator!(''), 'Password is required');
  });

  testWidgets('policy links open simple text dialogs', (tester) async {
    await showLogin(tester);
    await tester.tap(find.text('Terms of Service'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('These terms are governed'), findsOneWidget);

    await tester.tap(find.text('Close').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('We collect, use, and store'), findsOneWidget);
  });

  testWidgets('policy dialog fits a narrow screen', (tester) async {
    await showLogin(tester, size: const Size(375, 800));
    await tester.ensureVisible(find.text('Privacy Policy'));
    await tester.tap(find.text('Privacy Policy'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
