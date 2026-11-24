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
  });
}
