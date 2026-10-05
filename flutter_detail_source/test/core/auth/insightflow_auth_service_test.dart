import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:liquid_glass_widgets/core/auth/insightflow_auth_service.dart';
import 'package:liquid_glass_widgets/core/auth/supabase_auth_service.dart';

void main() {
  group('Supabase authentication boundaries', () {
    test('email_not_confirmed is detected as an unverified email', () {
      final error = AuthException(
        'Email not confirmed',
        code: 'email_not_confirmed',
        statusCode: '400',
      );

      expect(
        InsightFlowSupabaseAuthService.isEmailVerificationError(error),
        isTrue,
      );
    });

    test('invalid credentials are not mislabeled as email verification', () {
      final error = AuthException(
        'Invalid login credentials',
        code: 'invalid_credentials',
        statusCode: '400',
      );

      expect(
        InsightFlowSupabaseAuthService.isEmailVerificationError(error),
        isFalse,
      );
    });

    test('signup does not fall through to an uninitialized Supabase client', () async {
      if (InsightFlowSupabaseConfig.isConfigured) {
        return;
      }

      await expectLater(
        InsightFlowSupabaseAuthService.signUp(
          email: 'signup-regression@example.invalid',
          password: 'not-a-real-password',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message.toString(),
            'message',
            'Supabase authentication is not configured for this build.',
          ),
        ),
      );
    });

    test('Supabase auth facade never uses Firebase-specific configuration errors', () {
      final message = InsightFlowAuthService.userFacingAuthError(
        AuthException(
          'Email not confirmed',
          code: 'email_not_confirmed',
          statusCode: '400',
        ),
      );

      expect(message, 'Email not verified. Please verify your email first.');
      expect(
        message,
        isNot(contains('Firebase')),
      );
    });
  });
}
