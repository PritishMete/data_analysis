import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/auth/insightflow_auth_service.dart';

void main() {
  test('maps credential failures to a safe generic message', () {
    final error = FirebaseAuthException(
      code: 'invalid-credential',
      message: 'private provider details',
    );
    expect(
      InsightFlowAuthService.userFacingAuthError(error),
      'Email or password is incorrect.',
    );
  });

  test('does not expose private Firebase error details', () {
    final error = FirebaseAuthException(
      code: 'unknown-provider-error',
      message: 'secret token or internal response',
    );
    final message = InsightFlowAuthService.userFacingAuthError(error);
    expect(message, isNot(contains('secret token')));
    expect(message, isNot(contains('internal response')));
  });

  test('maps disabled accounts without exposing account metadata', () {
    final error = FirebaseAuthException(
      code: 'user-disabled',
      message: 'internal account identifier',
    );
    expect(
      InsightFlowAuthService.userFacingAuthError(error),
      'This account is disabled.',
    );
  });
}
