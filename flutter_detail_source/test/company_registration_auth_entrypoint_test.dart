import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Registration endpoint diagnostics must ship with the production web build.
  test('company registration starts Google auth for unauthenticated users', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Company / Organization Name'));
    expect(source, contains("InsightFlowSupabaseAuthService.signInWithOAuth("));
    expect(source, contains('OAuthProvider.google'));
    expect(source, contains("label: 'Continue with Google'"));
  });

  test('company registration posts to the authoritative bootstrap endpoint', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();
    final authSource = File(
      'lib/core/auth/authenticated_http.dart',
    ).readAsStringSync();
    final supabaseAuthSource = File(
      'lib/core/auth/supabase_auth_service.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(r'$insightFlowBackendBaseUrl/v1/authz/organizations/register'),
    );
    expect(source, isNot(contains('/v1/authz/bootstrap-owner')));
    expect(source, contains("'organization_name': name"));
    expect(source, contains('organizationServiceRequest('));
    expect(
      authSource,
      contains('Future<Map<String, String>> supabaseAuthHeaders'),
    );
    expect(source, contains('response.statusCode == 404'));
    expect(source, contains('InsightFlowSupabaseAuthService.ensureSession()'));
    expect(
      supabaseAuthSource,
      contains('static Future<Session?> ensureSession'),
    );
    expect(supabaseAuthSource, contains('refreshSession()'));
    expect(
      supabaseAuthSource,
      contains('if (session?.accessToken.isEmpty ?? true) return null;'),
    );
  });

  test('company registration reports session restoration failure clearly', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Your Google sign-in session could not be restored.'));
    expect(source, contains('if (session == null || user == null)'));
  });

  test('company registration distinguishes backend status from network failure', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();
    final authSource = File(
      'lib/core/auth/authenticated_http.dart',
    ).readAsStringSync();

    expect(
      authSource,
      contains("diagnostic.stage = error.toString().contains('Failed to fetch')"),
    );
    expect(authSource, contains("'NETWORK_OR_CORS'"));
    expect(authSource, contains("'NETWORK_ERROR'"));
    expect(source, contains("response.statusCode == 404"));
    expect(source, contains("response.statusCode >= 500"));
    expect(source, contains('route-not-found'));
    expect(source, contains('server-error'));
  });
}
