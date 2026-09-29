import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('company registrant routes to ManagementShell, not legacy management', () {
    final source = File(
      'lib/features/auth/company_registration_screen.dart',
    ).readAsStringSync();

    expect(source, contains("import 'management_shell.dart';"));
    expect(
      source,
      contains(
        "MaterialPageRoute(builder: (_) => const ManagementShell())",
      ),
    );
    expect(source, isNot(contains('AuthorizationManagementScreen()')));
  });

  test('cached startup reconciliation retries transient failures and stops on authorization result', () {
    final source = File(
      'lib/core/auth/authenticated_http.dart',
    ).readAsStringSync();
    final authGate = File(
      'lib/features/auth/auth_gate.dart',
    ).readAsStringSync();

    expect(source, contains('reconcileCachedWorkspaceWithRetry'));
    expect(source, contains('maxAttempts = 4'));
    expect(source, contains('if (result != null) return result;'));
    expect(source, contains('return null;'));
    expect(authGate, contains('_hasCachedWorkspace'));
    expect(
      authGate,
      contains('unawaited(_scheduleBackgroundRetry());'),
    );
    expect(
      authGate,
      contains('resolveInsightFlowWorkspaceFromBackend(widget.user.uid)'),
    );
  });

  test('workspace reconciliation: transient failure then success is bounded and recovers', () async {
    final attempts = <int>[];
    var call = 0;

    final result = await reconcileCachedWorkspaceWithRetry(
      resolve: () async {
        call += 1;
        attempts.add(call);
        if (call == 1) return null;
        return true;
      },
      maxAttempts: 4,
      initialDelay: Duration.zero,
    );

    expect(result, isTrue);
    expect(attempts, [1, 2]);
  });

  test('workspace reconciliation: authoritative denial stops without retrying', () async {
    var calls = 0;

    final result = await reconcileCachedWorkspaceWithRetry(
      resolve: () async {
        calls += 1;
        return false;
      },
      maxAttempts: 4,
      initialDelay: Duration.zero,
    );

    expect(result, isFalse);
    expect(calls, 1);
  });

  test('workspace reconciliation: transient failures are bounded', () async {
    var calls = 0;

    final result = await reconcileCachedWorkspaceWithRetry(
      resolve: () async {
        calls += 1;
        return null;
      },
      maxAttempts: 4,
      initialDelay: Duration.zero,
    );

    expect(result, isNull);
    expect(calls, 4);
  });
}
