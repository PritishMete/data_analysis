import 'dart:io';

import 'package:test/test.dart';

void main() {
  test(
    'invalid refresh sessions are cleared instead of remaining authenticated',
    () {
      final auth = File(
        'lib/core/auth/supabase_auth_service.dart',
      ).readAsStringSync();
      expect(auth, contains("normalized.contains('invalid refresh token')"));
      expect(auth, contains("normalized.contains('refresh_token_not_found')"));
      expect(auth, contains('await _clearInvalidLocalSession();'));
      expect(auth, contains('signOut(scope: localSignOutScope)'));
    },
  );

  test('logout unwinds pushed management routes after successful sign-out', () {
    final shell = File(
      'lib/features/auth/management_shell.dart',
    ).readAsStringSync();
    final access = File(
      'lib/features/auth/authorization_management_screen.dart',
    ).readAsStringSync();
    expect(
      shell,
      contains('Navigator.of(context).popUntil((route) => route.isFirst)'),
    );
    expect(
      access,
      contains('Navigator.of(context).popUntil((route) => route.isFirst)'),
    );
  });

  test('Excel clears stale task-pane sessions before opening a new dialog', () {
    final excel = File(
      'lib/features/auth/excel_auth_gate.dart',
    ).readAsStringSync();
    expect(excel, contains('hadPersistedSession'));
    expect(excel, contains('shouldClearPersistedSession = hadPersistedSession'));
    expect(excel, contains('if (shouldClearPersistedSession)'));
    expect(excel, contains('await InsightFlowSupabaseAuthService.signOut();'));
  });
}
