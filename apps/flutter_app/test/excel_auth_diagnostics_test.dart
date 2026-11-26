import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/auth/excel_auth_diagnostics.dart';

void main() {
  setUp(() {
    ExcelAuthDiagnostics.enableForTest();
    ExcelAuthDiagnostics.resetForTest();
  });

  test('records ordered events with one shared correlation id', () {
    ExcelAuthDiagnostics.start('excel-test-correlation');
    ExcelAuthDiagnostics.record('oauth_started', operation: 'google');
    ExcelAuthDiagnostics.record(
      'message_parent_returned',
      result: 'synchronous_return',
    );

    final events = (jsonDecode(ExcelAuthDiagnostics.exportJson()) as List)
        .cast<Map<String, dynamic>>();
    expect(events.map((event) => event['event']), [
      'attempt_started',
      'oauth_started',
      'message_parent_returned',
    ]);
    expect(events.map((event) => event['correlation_id']).toSet(), {
      'excel-test-correlation',
    });
  });

  test('redacts token-like fields by construction', () {
    ExcelAuthDiagnostics.start('excel-redaction');
    ExcelAuthDiagnostics.record('set_session', result: 'succeeded');
    final output = ExcelAuthDiagnostics.exportJson();
    expect(output, isNot(contains('refreshToken')));
    expect(output, isNot(contains('accessToken')));
    expect(output, isNot(contains('nonce')));
    expect(output, isNot(contains('state')));
  });

  test('preserves late-error ordering after completion for diagnosis', () {
    ExcelAuthDiagnostics.start('excel-late-error');
    ExcelAuthDiagnostics.record('dialog_completed', result: 'state_set');
    ExcelAuthDiagnostics.record(
      'auth_state_stream_error',
      result: 'received',
      errorCode: 'timeout',
      completed: true,
    );
    final events = (jsonDecode(ExcelAuthDiagnostics.exportJson()) as List)
        .cast<Map<String, dynamic>>();
    expect(events[1]['event'], 'dialog_completed');
    expect(events[2]['event'], 'auth_state_stream_error');
    expect(events[2]['completed'], true);
  });

  test('records safe stage events without accepting sensitive fields', () {
    ExcelAuthDiagnostics.start('excel-stage-test');
    ExcelAuthDiagnostics.record('oauth_callback_detected', sessionAvailable: true);
    ExcelAuthDiagnostics.record('user_verification_failed', errorCode: 'timeout');
    ExcelAuthDiagnostics.record('handoff_failed', result: 'failed');

    final output = ExcelAuthDiagnostics.exportJson();
    expect(output, contains('oauth_callback_detected'));
    expect(output, contains('user_verification_failed'));
    expect(output, contains('handoff_failed'));
    expect(output, isNot(contains('refresh_token')));
    expect(output, isNot(contains('authorization')));
    expect(output, isNot(contains('callback_url')));
  });

  test('diagnostics remain disabled by default until explicitly activated', () {
    ExcelAuthDiagnostics.disableForTest();
    ExcelAuthDiagnostics.resetForTest();
    expect(ExcelAuthDiagnostics.isEnabled, isFalse);
    expect(ExcelAuthDiagnostics.exportJson(), '[]');
  });
}
