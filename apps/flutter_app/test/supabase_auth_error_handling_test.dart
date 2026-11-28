import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../lib/core/auth/supabase_auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://test-project.supabase.co',
      anonKey: 'test-anon-key',
      authOptions: FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUri: false,
      ),
    );
  });

  setUp(() {
    InsightFlowSupabaseAuthService.clearPasswordRecoveryPending();
  });

  group('Supabase signup account-enumeration protection', () {
    test('duplicate-account error uses the generic signup response', () {
      final message =
          InsightFlowSupabaseAuthService.userFacingAuthError(
        AuthException('User already registered', code: 'user_already_exists'),
      );

      expect(message, InsightFlowSupabaseAuthService.signupResultMessage);
      expect(message.toLowerCase(), isNot(contains('already exists')));
      expect(message.toLowerCase(), isNot(contains('already registered')));
    });

    test('duplicate-account message is normalized even without an error code', () {
      final message =
          InsightFlowSupabaseAuthService.userFacingAuthError(
        AuthException('User already registered'),
      );

      expect(message, InsightFlowSupabaseAuthService.signupResultMessage);
    });

    test('successful signup screens use the same generic response', () {
      final signIn = File('lib/features/auth/sign_in_screen.dart').readAsStringSync();
      final signUp = File('lib/features/auth/sign_up_screen.dart').readAsStringSync();

      expect(signIn, contains('InsightFlowSupabaseAuthService.signupResultMessage'));
      expect(signUp, contains('InsightFlowSupabaseAuthService.signupResultMessage'));
    });

    test('duplicate signup errors are classified as enumeration-safe', () {
      expect(
        InsightFlowSupabaseAuthService.isSignupEnumerationSafeResponse(
          AuthException('User already registered', code: 'user_already_exists'),
        ),
        isTrue,
      );
      expect(
        InsightFlowSupabaseAuthService.isSignupEnumerationSafeResponse(
          AuthException('User already exists'),
        ),
        isTrue,
      );
    });

    test('unrelated authentication errors are not treated as signup success', () {
      expect(
        InsightFlowSupabaseAuthService.isSignupEnumerationSafeResponse(
          AuthException('Invalid login credentials', code: 'invalid_credentials'),
        ),
        isFalse,
      );
    });
    test('password recovery callback is replayed to the late auth listener', () async {
      final user = User(
        id: '00000000-0000-4000-8000-000000000001',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-01-01T00:00:00Z',
        email: 'recovery@example.invalid',
      );
      final session = Session(
        accessToken: 'test-access-token',
        refreshToken: 'test-refresh-token',
        tokenType: 'bearer',
        user: user,
      );

      // Supabase Flutter 2.17.2 uses a replaying auth event stream. Model the
      // PASSWORD_RECOVERY callback being emitted during initialize, before
      // AuthGate attaches its listener after runApp.
      // ignore: invalid_use_of_internal_member
      InsightFlowSupabaseAuthService.client.auth.notifyAllSubscribers(
        AuthChangeEvent.passwordRecovery,
        session: session,
      );

      final state = await InsightFlowSupabaseAuthService.authStateChanges
          .firstWhere((state) => state.event == AuthChangeEvent.passwordRecovery);

      expect(state.session?.user.id, user.id);
      expect(InsightFlowSupabaseAuthService.isPasswordRecoveryPending, isTrue);
    });

    test('unconfirmed and invalid-password login errors share one message', () {
      final invalidPassword =
          InsightFlowSupabaseAuthService.userFacingAuthError(
        AuthException('Invalid login credentials', code: 'invalid_credentials'),
      );
      final unconfirmed =
          InsightFlowSupabaseAuthService.userFacingAuthError(
        AuthException('Email not confirmed', code: 'email_not_confirmed'),
      );

      expect(invalidPassword, InsightFlowSupabaseAuthService.loginFailureMessage);
      expect(unconfirmed, invalidPassword);
    });

    test('unconfirmed login text is normalized when only message is available', () {
      expect(
        InsightFlowSupabaseAuthService.userFacingAuthError(
          AuthException('Email not verified'),
        ),
        InsightFlowSupabaseAuthService.loginFailureMessage,
      );
    });

    test('unknown account recovery responses use the same safe confirmation', () {
      expect(
        InsightFlowSupabaseAuthService.isRecoveryEnumerationSafeResponse(
          AuthException('User not found', code: 'user_not_found'),
        ),
        isTrue,
      );
      expect(
        InsightFlowSupabaseAuthService.isRecoveryEnumerationSafeResponse(
          AuthException('Email not found'),
        ),
        isTrue,
      );
      expect(
        InsightFlowSupabaseAuthService.isRecoveryEnumerationSafeResponse(
          AuthException('Too many requests', code: 'over_request_rate_limit'),
        ),
        isFalse,
      );
    });

    test('reset and resend actions use generic provider-neutral messaging', () {
      final signIn = File('lib/features/auth/sign_in_screen.dart').readAsStringSync();

      expect(
        signIn,
        contains('InsightFlowSupabaseAuthService.passwordResetRequestMessage'),
      );
      expect(
        signIn,
        contains('InsightFlowSupabaseAuthService.verificationLinkRequestMessage'),
      );
      expect(signIn, contains('_emailVerificationRequired = true'));
      expect(signIn, isNot(contains('Email not verified. Please verify your email first.')));
    });
  });
  group('Supabase password-change enforcement support', () {
    test('current password is serialized for provider-side enforcement', () {
      final attributes = UserAttributes(
        password: 'new-test-password',
        currentPassword: 'old-test-password',
      );

      expect(attributes.toJson()['current_password'], 'old-test-password');
    });

    test('account password changes pass current password to Supabase Auth', () {
      final account =
          File('lib/features/auth/account_management_screen.dart').readAsStringSync();

      expect(account, contains('currentPassword: currentPassword'));
    });
  });

}
