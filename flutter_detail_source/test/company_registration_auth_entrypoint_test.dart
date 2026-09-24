import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
      webBranch,
      contains('InsightFlowAuthService.signInWithGoogleAccount(account)'),
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

    expect(
      source,
      contains(r'$insightFlowBackendBaseUrl/v1/authz/organizations/register'),
    );
    expect(source, isNot(contains('/v1/authz/bootstrap-owner')));
    expect(source, contains("'organization_name': name"));
    expect(source, contains('firebaseAuthHeaders(forceRefresh: true)'));
    expect(source, contains('response.statusCode == 404'));
  });

  test('company registration distinguishes backend status from network failure', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains('category=network'));
    expect(source, contains("response.statusCode == 404"));
    expect(source, contains("response.statusCode >= 500"));
    expect(source, contains('route-not-found'));
    expect(source, contains('server-error'));
  });
}
