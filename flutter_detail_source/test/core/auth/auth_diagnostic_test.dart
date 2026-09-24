import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/core/auth/auth_diagnostic.dart';
import 'package:liquid_glass_widgets/core/auth/insightflow_auth_service.dart';

void main() {
  test('Firebase sign-in failure exposes safe stage and code', () {
    final attempt = AuthDiagnosticAttempt(id: 'AUTH-7F2A');
    attempt.record('FIREBASE_SIGN_IN_FAILED', code: 'invalid-credential');
    expect(attempt.failureSummary, contains('Stage: FIREBASE_SIGN_IN_FAILED'));
    expect(attempt.failureSummary, contains('Code: invalid-credential'));
    expect(attempt.failureSummary, contains('Attempt: AUTH-7F2A'));
  });

  test('Firebase success followed by backend failure remains AUTHZ', () {
    final attempt = AuthDiagnosticAttempt(id: 'AUTH-7F2A');
    attempt.record('FIREBASE_SIGN_IN_SUCCESS');
    attempt.record('FIREBASE_CURRENT_USER_PRESENT');
    attempt.record('FIREBASE_ID_TOKEN_REFRESH_SUCCESS');
    attempt.record('AUTHZ_RESOLUTION_HTTP_404', httpStatus: 404);
    expect(attempt.failureSummary, contains('Stage: AUTHZ_RESOLUTION_HTTP_404'));
    expect(attempt.failureSummary, contains('HTTP: 404'));
  });

  test('current-user presence stage is safe', () {
    final attempt = AuthDiagnosticAttempt(id: 'AUTH-7F2A');
    attempt.record('FIREBASE_CURRENT_USER_PRESENT');
    expect(attempt.failureSummary, isNot(contains('uid')));
    expect(attempt.failureSummary, isNot(contains('email')));
  });

  test('token refresh failure has a distinct stage', () {
    final attempt = AuthDiagnosticAttempt(id: 'AUTH-7F2A');
    attempt.record('FIREBASE_TOKEN_REFRESH_FAILED', code: 'user-token-expired');
    expect(attempt.failureSummary, contains('Stage: FIREBASE_TOKEN_REFRESH_FAILED'));
    expect(attempt.failureSummary, contains('Code: user-token-expired'));
  });

  test('reload failure has a distinct stage', () {
    final attempt = AuthDiagnosticAttempt(id: 'AUTH-7F2A');
    attempt.record('FIREBASE_USER_RELOAD_FAILED', code: 'user-not-found');
    expect(attempt.failureSummary, contains('Stage: FIREBASE_USER_RELOAD_FAILED'));
    expect(attempt.failureSummary, contains('Code: user-not-found'));
  });

  test('diagnostic output contains no private identity or token fields', () {
    final attempt = AuthDiagnosticAttempt(id: 'AUTH-7F2A');
    attempt.record('FIREBASE_SIGN_IN_FAILED', code: 'invalid-credential');
    final output = attempt.failureSummary.toLowerCase();
    expect(output, isNot(contains('token')));
    expect(output, isNot(contains('email')));
    expect(output, isNot(contains('provider_subject')));
    expect(output, isNot(contains('access_token')));
    expect(output, isNot(contains('refresh_token')));
  });

  test('stale Firebase recovery is allowed only once for stale-session codes', () {
    expect(
      InsightFlowAuthService.shouldRecoverStaleSession(
        code: 'user-not-found',
        currentUserPresent: true,
        retryAttempted: false,
      ),
      isTrue,
    );
    expect(
      InsightFlowAuthService.shouldRecoverStaleSession(
        code: 'user-not-found',
        currentUserPresent: true,
        retryAttempted: true,
      ),
      isFalse,
    );
    expect(
      InsightFlowAuthService.shouldRecoverStaleSession(
        code: 'invalid-credential',
        currentUserPresent: true,
        retryAttempted: false,
      ),
      isFalse,
    );
    expect(
      InsightFlowAuthService.shouldRecoverStaleSession(
        code: 'user-token-expired',
        currentUserPresent: false,
        retryAttempted: false,
      ),
      isFalse,
    );
  });

}
