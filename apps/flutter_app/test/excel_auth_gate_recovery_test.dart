import 'package:flutter_test/flutter_test.dart';

import '../lib/features/auth/excel_auth_gate.dart';
import '../lib/core/auth/supabase_auth_service.dart';

void main() {
  group('Excel Supabase session persistence', () {
    test('task pane persists its independent session', () {
      expect(
        shouldPersistSupabaseSession(isExcelAuthDialog: false),
        isTrue,
      );
    });

    test('Office dialog never persists the refresh token being handed off', () {
      expect(
        shouldPersistSupabaseSession(isExcelAuthDialog: true),
        isFalse,
      );
    });
  });

  group('Excel task-pane late dialog recovery', () {
    test('preserves a verified task-pane session when the dialog callback fails late', () async {
      var showAuthenticationError = false;

      // The Office dialog has closed unexpectedly after the task pane already
      // authenticated. The gate re-checks getUser rather than trusting the
      // late dialog callback result.
      final paneStillAuthenticated =
          await isAuthoritativeExcelSessionAvailable(() async => true);

      if (!paneStillAuthenticated) {
        showAuthenticationError = true;
      }

      expect(paneStillAuthenticated, isTrue);
      expect(showAuthenticationError, isFalse);
    });

    test('does not preserve an expired or absent task-pane session', () async {
      final paneStillAuthenticated =
          await isAuthoritativeExcelSessionAvailable(() async => false);

      expect(paneStillAuthenticated, isFalse);
    });

    test('treats an unavailable authoritative check as unverified', () async {
      final paneStillAuthenticated =
          await isAuthoritativeExcelSessionAvailable(() async {
        throw StateError('test-only verification failure');
      });

      expect(paneStillAuthenticated, isFalse);
    });
  });
}
