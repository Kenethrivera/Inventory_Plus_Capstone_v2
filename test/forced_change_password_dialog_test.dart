import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/logic/inventory_controller.dart';
import 'package:inventory_plus/ui/widgets/change_password_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _PasswordController extends InventoryController {
  String? verifiedPassword;
  String? changedFrom;
  String? changedTo;

  @override
  Future<CurrentPasswordVerificationResult> verifyCurrentPassword(
    String currentPassword,
  ) async {
    verifiedPassword = currentPassword;
    return currentPassword == 'Temporary123!'
        ? CurrentPasswordVerificationResult.correct
        : CurrentPasswordVerificationResult.incorrect;
  }

  @override
  Future<ChangePasswordResult> changePassword(
    String currentPassword,
    String newPassword,
  ) async {
    changedFrom = currentPassword;
    changedTo = newPassword;
    return ChangePasswordResult.success;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      publishableKey: 'test-publishable-key',
    );
  });

  Future<_PasswordController> showForcedDialog(
    WidgetTester tester, {
    Size size = const Size(1200, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final controller = _PasswordController();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ChangePasswordDialog(
              controller: controller,
              forced: true,
              onLogout: () async {},
            ),
          ),
        ),
      ),
    );
    return controller;
  }

  testWidgets('forced desktop form matches the recovery password step', (
    tester,
  ) async {
    final controller = await showForcedDialog(tester);
    expect(find.text('Reset password'), findsOneWidget);
    expect(find.text('Set new password'), findsWidgets);
    expect(find.byKey(const ValueKey('Temporary password')), findsOneWidget);
    expect(find.byKey(const ValueKey('New password')), findsOneWidget);
    expect(find.byKey(const ValueKey('Confirm new password')), findsOneWidget);
    expect(find.text('YOUR PASSWORD NEEDS'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(
      find.byKey(const ValueKey('Temporary password')),
      'Temporary123!',
    );
    await tester.pump(const Duration(milliseconds: 650));
    expect(controller.verifiedPassword, 'Temporary123!');

    await tester.enterText(
      find.byKey(const ValueKey('New password')),
      'StrongNew1!',
    );
    await tester.enterText(
      find.byKey(const ValueKey('Confirm new password')),
      'StrongNew1!',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Update password'));
    await tester.tap(find.text('Update password'));
    await tester.pump();
    expect(controller.changedFrom, 'Temporary123!');
    expect(controller.changedTo, 'StrongNew1!');
  });

  testWidgets('forced password form fits a narrow screen', (tester) async {
    await showForcedDialog(tester, size: const Size(375, 800));
    expect(find.text('Uppercase and lowercase letters'), findsOneWidget);
    await tester.ensureVisible(
      find.byKey(const ValueKey('Confirm new password')),
    );
    expect(tester.takeException(), isNull);
  });
}
