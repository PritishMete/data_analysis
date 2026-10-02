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
    expect(source, contains("'organization_name': _organization.text.trim()"));
    expect(source, contains('organizationServiceRequest('));
    expect(source, contains("decoded['employee_id']"));
    expect(source, isNot(contains("'employee_id':")));
    expect(source, contains('AUTO-GENERATED'));
    expect(source, contains("label: 'COUNTRY CODE *'"));
    expect(source, contains('ProfileTextField('));
    expect(source, contains("label: 'Phone Number'"));
    expect(source, contains('full_name'));
    expect(source, contains('address_line1'));
    expect(source, contains('id_proof_number'));
    expect(source, isNot(contains('sendEmailOtp')));
    expect(source, isNot(contains('verifyEmailOtp')));
    expect(source, isNot(contains('EMAIL OTP')));
    expect(source, isNot(contains('beginPhoneVerification')));
    expect(source, isNot(contains('verifyPhoneChangeOtp')));
    expect(source, isNot(contains('resendPhoneChangeOtp')));
    expect(source, contains('phone_country_calling_code'));
    expect(source, contains('phone_national_number'));
    expect(source, contains('Country *'));
    expect(source, contains('State / Province / Region *'));
    expect(source, contains('ID Proof Type *'));
    expect(source, contains("required: false"));
    expect(source, contains('national/local number only'));
    expect(supabaseAuthSource, contains("emailRedirectTo: 'https://pritishmete.github.io/data_analysis/'"));
    expect(supabaseAuthSource, contains("type: OtpType.signup"));
    expect(source, isNot(contains('PHONE VERIFIED')));
    expect(source, contains('ID PROOF • PROVIDED'));
    expect(
      authSource,
      contains('Future<Map<String, String>> supabaseAuthHeaders'),
    );
    expect(source, contains('response.statusCode == 401'));
    expect(source, contains('response.statusCode == 403'));
    expect(source, contains('response.statusCode == 409'));
    expect(source, contains('response.statusCode == 422'));
    expect(source, contains('InsightFlowSupabaseAuthService.ensureSession('));
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

  test('Supabase auth-state stream restores the current session safely', () {
    final source = File(
      'lib/core/auth/supabase_auth_service.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('yield AuthState(AuthChangeEvent.initialSession, initialSession);'),
    );
    expect(
      source,
      contains('await for (final state in client.auth.onAuthStateChange)'),
    );
    expect(
      source,
      contains('yield AuthState(AuthChangeEvent.initialSession, currentSession);'),
    );
  });

  test('company registration reports session restoration failure clearly', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Your authenticated Supabase session could not be restored.'));
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
    expect(source, contains("response.statusCode == 401"));
    expect(source, contains("response.statusCode == 403"));
    expect(source, contains("response.statusCode == 409"));
    expect(source, contains("response.statusCode == 422"));
    expect(source, contains("response.statusCode >= 500"));
  });
}
