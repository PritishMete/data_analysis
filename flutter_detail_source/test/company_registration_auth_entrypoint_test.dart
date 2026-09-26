import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Registration endpoint diagnostics must ship with the production web build.
  test('company registration does not require a second provider sign-in', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Company / Organization Name'));
    expect(
      source,
      contains('Sign in first, then return here to create your company'),
    );
    expect(source, isNot(contains('GoogleWebSignInButton(')));
    expect(source, isNot(contains('signInWithMicrosoft')));
    expect(source, isNot(contains('signInWithGoogleAccount')));
  });

  test('company registration posts to the authoritative bootstrap endpoint', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();
    final authSource = File(
      'lib/core/auth/authenticated_http.dart',
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
