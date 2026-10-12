import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../lib/core/auth/insightflow_auth_service.dart';

void main() {
  test('maps invalid Supabase credentials to a safe message', () {
    final error = AuthException(
      'private provider details',
      code: 'invalid_credentials',
    );

    expect(
      InsightFlowAuthService.userFacingAuthError(error),
      'Email or password is incorrect.',
    );
  });

  test('does not expose unrecognized Supabase auth error details', () {
    final error = AuthException(
      'secret token or internal response',
      code: 'unknown_provider_error',
    );

    final message = InsightFlowAuthService.userFacingAuthError(error);
    expect(message, 'Authentication could not be completed. Please try again.');
    expect(message, isNot(contains('secret token')));
    expect(message, isNot(contains('internal response')));
  });

  test('maps email verification failures to a clear safe message', () {
    final error = AuthException(
      'Email not confirmed',
      code: 'email_not_confirmed',
    );

    expect(
      InsightFlowAuthService.userFacingAuthError(error),
      'Please verify your email using the confirmation link before signing in.',
    );
  });
}
