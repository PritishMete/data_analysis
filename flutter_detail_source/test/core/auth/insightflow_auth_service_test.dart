import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:liquid_glass_widgets/core/auth/insightflow_auth_service.dart';

void main() {
  group('InsightFlowAuthService startup boundaries', () {
    test('Google initialization failure maps to a provider-specific error', () {
      final message = InsightFlowAuthService.userFacingAuthError(
        FirebaseAuthException(
          code: 'google-sign-in-initialization-failed',
          message: 'Google SDK initialization failed internally',
        ),
      );

      expect(
        message,
        'Google sign-in could not start. Try email/password or Microsoft sign-in, or try Google again later.',
      );
      expect(message, isNot(contains('Firebase authentication is not configured for this build.')));
    });

    test('Firebase configuration error message is not used for Google provider errors', () {
      final googleError = FirebaseAuthException(
        code: 'google-sign-in-initialization-failed',
      );

      expect(
        InsightFlowAuthService.userFacingAuthError(googleError),
        isNot('Firebase authentication is not configured for this build.'),
      );
    });
  });

  group('InsightFlowAuthService provider error mapping', () {
    test('Google web UI required error is provider-specific', () {
      expect(InsightFlowAuthService.userFacingAuthError(FirebaseAuthException(code: 'google-web-ui-required')), 'Google sign-in must be started with the Google sign-in button.');
    });

    test('Google provider error does not expose raw details', () {
      final message = InsightFlowAuthService.userFacingAuthError(FirebaseAuthException(code: 'google-provider-error', message: 'sensitive provider details'));
      expect(message, 'Google sign-in could not be completed. Please try again.');
      expect(message, isNot(contains('sensitive provider details')));
    });

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
  group('Google Web authentication boundary', () {
    test('Web account completion does not authorize additional scopes', () {
      // signInWithGoogleAccount must consume the GIS authentication ID token
      // directly. This static regression guard prevents reintroducing an
      // interactive authorizeScopes call into the shared Web completion path.
      final source = '''
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'package:liquid_glass_widgets/core/auth/insightflow_auth_service.dart';

void main() {
  group('InsightFlowAuthService startup boundaries', () {
    test('Google initialization failure maps to a provider-specific error', () {
      final message = InsightFlowAuthService.userFacingAuthError(
        FirebaseAuthException(
          code: 'google-sign-in-initialization-failed',
          message: 'Google SDK initialization failed internally',
        ),
      );

      expect(
        message,
        'Google sign-in could not start. Try email/password or Microsoft sign-in, or try Google again later.',
      );
      expect(message, isNot(contains('Firebase authentication is not configured for this build.')));
    });

    test('Firebase configuration error message is not used for Google provider errors', () {
      final googleError = FirebaseAuthException(
        code: 'google-sign-in-initialization-failed',
      );

      expect(
        InsightFlowAuthService.userFacingAuthError(googleError),
        isNot('Firebase authentication is not configured for this build.'),
      );
    });
  });

  group('InsightFlowAuthService provider error mapping', () {
    test('Google web UI required error is provider-specific', () {
      expect(InsightFlowAuthService.userFacingAuthError(FirebaseAuthException(code: 'google-web-ui-required')), 'Google sign-in must be started with the Google sign-in button.');
    });

    test('Google provider error does not expose raw details', () {
      final message = InsightFlowAuthService.userFacingAuthError(FirebaseAuthException(code: 'google-provider-error', message: 'sensitive provider details'));
      expect(message, 'Google sign-in could not be completed. Please try again.');
      expect(message, isNot(contains('sensitive provider details')));
    });

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

''';
      final start = source.indexOf('signInWithGoogleAccount');
      final end = source.indexOf('static void _logGoogleException', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final method = source.substring(start, end);
      expect(method, contains('googleUser.authentication.idToken'));
      expect(method, contains('GoogleAuthProvider.credential(idToken: idToken)'));
      expect(method, isNot(contains('authorizeScopes')));
      expect(method, isNot(contains('authorizationClient')));
    });

    test('Google cancellation is not reported as popup blocked', () {
      final error = GoogleSignInException(
        code: GoogleSignInExceptionCode.canceled,
        description: 'user cancelled',
      );
      expect(
        InsightFlowAuthService.userFacingAuthError(error),
        'Sign-in was cancelled.',
      );
      expect(
        InsightFlowAuthService.userFacingAuthError(error),
        isNot(contains('popup')),
      );
    });

    test('missing Google ID token has a distinct error', () {
      expect(
        InsightFlowAuthService.userFacingAuthError(
          FirebaseAuthException(code: 'google-id-token-missing'),
        ),
        'Google authentication did not provide an ID token. Please try again.',
      );
    });
  });

}
