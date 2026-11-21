import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/core/diagnostics/auth_diagnostics.dart';

void main() {
  test('concurrent failures and retries use isolated diagnostic IDs', () async {
    final emitted = <String>[];
    final previous = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) emitted.add(message);
    };
    addTearDown(() => debugPrint = previous);

    Future<String> failedAttempt() async {
      final id = AuthDiagnostics.newCorrelationId();
      AuthDiagnostics.event(
        'excel_parent_handoff',
        correlationId: id,
        success: false,
        exceptionClass: 'TimeoutException',
        category: 'handoff_failure',
      );
      return id;
    }

    final ids = await Future.wait([failedAttempt(), failedAttempt()]);
    final retryId = await failedAttempt();

    expect(ids[0], isNot(ids[1]));
    expect(retryId, isNot(ids[0]));
    expect(retryId, isNot(ids[1]));
    expect(emitted, hasLength(3));
    expect(emitted.join('\n'), isNot(contains('FAKE_ACCESS_TOKEN')));
    expect(emitted.join('\n'), isNot(contains('FAKE_REFRESH_TOKEN')));
    expect(emitted.join('\n'), isNot(contains('authorization')));
  });
}
