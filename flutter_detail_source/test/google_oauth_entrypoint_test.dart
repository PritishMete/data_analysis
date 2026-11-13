import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Supabase service starts Google OAuth with the configured callback', () {
    final source = File('lib/core/auth/supabase_auth_service.dart').readAsStringSync();

    expect(source, contains('static Future<bool> signInWithGoogle'));
    expect(source, contains('OAuthProvider.google'));
    expect(source, contains('InsightFlowSupabaseConfig.authRedirectUrl'));
    expect(source, contains('AuthFlowType.pkce'));
    expect(source, isNot(contains('GoogleSignIn')));
  });

  test('primary sign-in screen uses the Supabase Google entry point', () {
    final source = File('lib/features/auth/sign_in_screen.dart').readAsStringSync();

    expect(source, contains('InsightFlowSupabaseAuthService.signInWithGoogle()'));
    expect(source, contains("label: 'Continue with Google'"));
    expect(source, contains('if (_loading || _showCreateAccount || _transitioning)'));
    expect(source, contains('Google sign-in could not start. Please try again.'));
    expect(source, isNot(contains('InsightFlowAuthService')));
  });

  test('OAuth callback errors are handled from query and fragment redirects', () {
    final source = File('lib/features/auth/auth_gate.dart').readAsStringSync();

    expect(source, contains('Uri.base.queryParameters'));
    expect(source, contains('Uri.splitQueryString'));
    expect(source, contains("error == 'access_denied'"));
    expect(source, contains('Google sign-in was cancelled.'));
  });
}
