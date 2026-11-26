import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../lib/core/auth/supabase_auth_service.dart';

void main() {
  test('Supabase service starts Google OAuth with the configured callback', () {
    final source = File('lib/core/auth/supabase_auth_service.dart').readAsStringSync();

    expect(source, contains('static Future<bool> signInWithGoogle'));
    expect(source, contains('OAuthProvider.google'));
    expect(source, contains('InsightFlowSupabaseConfig.authRedirectUrl'));
    expect(source, contains('AuthFlowType.pkce'));
    expect(source, isNot(contains('GoogleSignIn')));
  });

  test('website OAuth callback follows the current Cloudflare Pages origin', () {
    final source = File('lib/core/auth/supabase_auth_service.dart').readAsStringSync();

    expect(
      source,
      contains('static String resolveAuthRedirectUrl'),
    );
    expect(
      source,
      contains('isOffice: isRunningInsideOffice'),
    );
    expect(
      source,
      isNot(contains("defaultValue: 'https://pritishmete.github.io/data_analysis/'")),
    );
    expect(
      source,
      contains('emailRedirectTo: InsightFlowSupabaseConfig.authRedirectUrl'),
    );
  });

  test('OAuth redirect resolver preserves website and Excel origins', () {
    final cloudflare = Uri.parse('https://insightflow-3e8.pages.dev/');
    final local = Uri.parse('http://localhost:5173/');
    const legacyExcel = 'https://pritishmete.github.io/data_analysis/';

    expect(
      InsightFlowSupabaseConfig.resolveAuthRedirectUrl(
        isWeb: true,
        isOffice: false,
        currentUri: cloudflare,
      ),
      'https://insightflow-3e8.pages.dev/',
    );
    expect(
      InsightFlowSupabaseConfig.resolveAuthRedirectUrl(
        isWeb: true,
        isOffice: false,
        currentUri: local,
      ),
      'http://localhost:5173/',
    );
    expect(
      InsightFlowSupabaseConfig.resolveAuthRedirectUrl(
        isWeb: true,
        isOffice: true,
        currentUri: cloudflare,
      ),
      legacyExcel,
    );
    expect(
      InsightFlowSupabaseConfig.resolveAuthRedirectUrl(
        isWeb: true,
        isOffice: false,
        currentUri: cloudflare,
        configuredUrl: 'https://auth.example.test/callback',
      ),
      'https://auth.example.test/callback',
    );
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
