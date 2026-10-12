import 'package:flutter_test/flutter_test.dart';

import '../lib/core/auth/insightflow_auth_service.dart';

void main() {
  test('surfaces an explicit safe authentication state message', () {
    expect(
      InsightFlowAuthService.userFacingAuthError(
        StateError('Email or password is incorrect.'),
      ),
      'Email or password is incorrect.',
    );
  });

  test('does not expose unknown provider exception details', () {
    final message = InsightFlowAuthService.userFacingAuthError(
      Exception('private token and internal provider response'),
    );
    expect(message, 'Authentication could not be completed. Please try again.');
    expect(message, isNot(contains('private token')));
    expect(message, isNot(contains('internal provider response')));
  });

  test('requires a Supabase session for bearer tokens', () {
    expect(
      InsightFlowAuthService.userFacingAuthError(
        StateError('Supabase authentication required.'),
      ),
      'Supabase authentication required.',
    );
  });
}
