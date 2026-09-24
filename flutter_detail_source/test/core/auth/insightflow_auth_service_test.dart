import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:liquid_glass_widgets/core/auth/insightflow_auth_service.dart';

void main() {
  group('InsightFlowAuthService provider error mapping', () {
    test('Google cancellation is user-facing cancellation', () {
      final error = GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'user cancelled',
      );

      expect(
        InsightFlowAuthService.userFacingAuthError(error),
        'Sign-in was cancelled.',
      );
    });

    test('Google configuration failure is not exposed as a raw exception', () {
      final message = InsightFlowAuthService.userFacingAuthError(
        FirebaseAuthException(
          code: 'invalid-configuration',
          message: 'provider configuration details',
        ),
      );

      expect(
        message,
        'This sign-in provider is not configured correctly. Check the Firebase provider settings.',
      );
      expect(message, isNot(contains('provider configuration details')));
    });

    test('popup blocked has a specific recovery message', () {
      expect(
        InsightFlowAuthService.userFacingAuthError(
          FirebaseAuthException(code: 'popup-blocked'),
        ),
        'The sign-in window was blocked. Allow pop-ups and try again.',
      );
    });

    test('Microsoft provider-disabled error remains actionable', () {
      expect(
        InsightFlowAuthService.userFacingAuthError(
          FirebaseAuthException(code: 'operation-not-allowed'),
        ),
        'This sign-in method is not enabled for this Firebase project.',
      );
    });

    test('email/password errors retain the existing path', () {
      expect(
        InsightFlowAuthService.userFacingAuthError(
          FirebaseAuthException(code: 'wrong-password'),
        ),
        'Email or password is incorrect.',
      );
    });
  });
}
