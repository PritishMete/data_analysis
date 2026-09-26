import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Google Web completion consumes the GIS ID token without OAuth scopes', () {
    final source = File('lib/core/auth/insightflow_auth_service.dart').readAsStringSync();
    final start = source.indexOf('static Future<UserCredential> signInWithGoogleAccount');
    final end = source.indexOf('static void _logGoogleException', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final method = source.substring(start, end);
    expect(method, contains('googleUser.authentication.idToken'));
    expect(method, contains('GoogleAuthProvider.credential(idToken: idToken)'));
    expect(method, isNot(contains('authorizeScopes')));
    expect(method, isNot(contains('authorizationClient')));
  });

  test('Google Web UI uses authenticationEvents and the shared account callback', () {
    final button = File('lib/features/auth/google_web_sign_in_button_web.dart').readAsStringSync();
    final signIn = File('lib/features/auth/sign_in_screen.dart').readAsStringSync();
    expect(button, contains('authenticationEvents'));
    expect(button, contains('onAuthenticated(event.user)'));
    expect(signIn, contains('GoogleWebSignInButton('));
    expect(
      RegExp(
        r'InsightFlowAuthService\.signInWithGoogleAccount\(\s*account\s*(?:,\s*diagnostic:\s*_authDiagnostic\s*)?\)',
      ).hasMatch(signIn),
      isTrue,
    );
  });

  test('native Google path still uses authenticate and account completion', () {
    final source = File('lib/core/auth/insightflow_auth_service.dart').readAsStringSync();
    final start = source.indexOf('static Future<UserCredential> signInWithGoogle()');
    final end = source.indexOf('static Future<UserCredential> signInWithGoogleAccount', start);
    final method = source.substring(start, end);
    expect(
      method,
      matches(RegExp(r'GoogleSignIn\.instance\s*\.authenticate\(\)')),
    );
    expect(
      method,
      matches(RegExp(
        r'return\s+await\s+signInWithGoogleAccount\(\s*googleUser\s*\)',
      )),
    );
  });
}
