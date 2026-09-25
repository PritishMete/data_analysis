import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  // Registration endpoint diagnostics must ship with the production web build.
  test('company registration uses the shared Web Google provider path', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    final webBranchStart = source.indexOf('if (kIsWeb)');
    final nativeGoogleBranchStart = source.indexOf(
      'else\n            GlassButton.custom(',
      webBranchStart,
    );

    expect(webBranchStart, greaterThanOrEqualTo(0));
    expect(nativeGoogleBranchStart, greaterThan(webBranchStart));

    final webBranch = source.substring(webBranchStart, nativeGoogleBranchStart);
    expect(webBranch, contains('GoogleWebSignInButton('));
    expect(
      RegExp(
        r'InsightFlowAuthService\.signInWithGoogleAccount\(\s*account\s*,\s*diagnostic:\s*_authDiagnostic\s*,',
      ).hasMatch(webBranch),
      isTrue,
    );
    expect(
      RegExp(r'InsightFlowAuthService\.signInWithGoogle\(').hasMatch(webBranch),
      isFalse,
    );

    final nativeGoogleBranch = source.substring(nativeGoogleBranchStart);
    expect(
      nativeGoogleBranch,
      contains('InsightFlowAuthService.signInWithGoogle'),
    );
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
    expect(authSource, contains('Future<Map<String, String>> supabaseAuthHeaders'));
    expect(source, contains('response.statusCode == 404'));
  });

  test('company registration distinguishes backend status from network failure', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();
    final authSource = File(
      'lib/core/auth/authenticated_http.dart',
    ).readAsStringSync();

    expect(authSource, contains("diagnostic.stage = error.toString().contains('Failed to fetch')"));
    expect(authSource, contains("'NETWORK_OR_CORS'"));
    expect(authSource, contains("'NETWORK_ERROR'"));
    expect(source, contains("response.statusCode == 404"));
    expect(source, contains("response.statusCode >= 500"));
    expect(source, contains('route-not-found'));
    expect(source, contains('server-error'));
  });
}
