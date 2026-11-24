import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../lib/core/auth/supabase_auth_service.dart';

void main() {
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
