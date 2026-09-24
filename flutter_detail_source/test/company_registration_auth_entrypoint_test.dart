import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('company registration uses the shared Web Google provider path', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains("import 'google_web_sign_in_button.dart';"));
    expect(source, contains('if (kIsWeb)'));
    expect(source, contains('GoogleWebSignInButton('));
    expect(
      source,
      contains('InsightFlowAuthService.signInWithGoogleAccount(account)'),
    );
    expect(
      source,
      isNot(contains('InsightFlowAuthService.signInWithGoogle),')),
    );
    expect(
      source,
      isNot(contains('InsightFlowAuthService.signInWithGoogle);')),
    );
  });
}
