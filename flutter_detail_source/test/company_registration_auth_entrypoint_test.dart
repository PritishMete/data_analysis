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
      RegExp(r'InsightFlowAuthService\\.signInWithGoogle\\(').hasMatch(webBranch),
      isFalse,
    );

    final nativeGoogleBranch = source.substring(nativeGoogleBranchStart);
    expect(
      nativeGoogleBranch,
      contains('InsightFlowAuthService.signInWithGoogle'),
    );
  });
}
