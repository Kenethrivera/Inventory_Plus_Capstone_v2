import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inventory_plus/login/auth_service.dart';
import 'package:inventory_plus/services/app_error_mapper.dart';
import 'package:inventory_plus/ui/login_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _RecoveryAuthService extends AuthService {
  bool rejectQuestions = false;
  String? requestedUsername;
  String? requestedChannel;

  @override
  Future<RecoveryQuestionChallenge> beginQuestionRecovery(
    String username,
  ) async {
    if (rejectQuestions) {
      throw const AppUserFacingException(
        'If you are staff, ask your administrator to reset your password.',
      );
    }
    return const RecoveryQuestionChallenge('question-challenge', [
      'first',
      'second',
      'third',
    ]);
  }

  @override
  Future<String> requestPasswordRecovery(
    String username,
    String channel,
  ) async {
    requestedUsername = username;
    requestedChannel = channel;
    return 'sms-challenge';
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

  Future<void> showRecovery(
    WidgetTester tester,
    _RecoveryAuthService auth,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ForgotPasswordModal(authService: auth)),
      ),
    );
  }

  testWidgets('forgot-password dialog opens above the dimmed login screen', (
    tester,
  ) async {
    final auth = _RecoveryAuthService();
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ForgotPasswordModal(authService: auth),
              ),
              child: const Text('Forgot password?'),
            ),
          ),
        ),
      ),
    );

    expect(
      MediaQuery.sizeOf(tester.element(find.text('Forgot password?'))).width,
      1200,
    );

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();
    expect(find.text('STEP 1 OF 3'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SMS switch sits in the action row and sends a code', (
    tester,
  ) async {
    final auth = _RecoveryAuthService();
    await showRecovery(tester, auth);
    await tester.enterText(find.byType(TextField).first, 'admin');
    await tester.tap(find.text('Security questions'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    final switchLink = find.text('Send an SMS code instead');
    expect(switchLink, findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
    expect(
      (tester.getCenter(switchLink).dy -
              tester.getCenter(find.text('Verify')).dy)
          .abs(),
      lessThan(15),
    );

    await tester.ensureVisible(switchLink);
    await tester.pump();
    await tester.tap(switchLink);
    await tester.pump();
    expect(auth.requestedUsername, 'admin');
    expect(auth.requestedChannel, 'sms');
    expect(find.text('Enter the code'), findsOneWidget);
  });

  testWidgets('invalid recovery account shows staff guidance toast', (
    tester,
  ) async {
    final auth = _RecoveryAuthService()..rejectQuestions = true;
    await showRecovery(tester, auth);
    await tester.enterText(find.byType(TextField).first, 'unknown');
    await tester.tap(find.text('Security questions'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(
      find.text(
        'If you are staff, ask your administrator to reset your password.',
      ),
      findsOneWidget,
    );
  });
}
