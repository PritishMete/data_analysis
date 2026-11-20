import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../lib/core/auth/local_session_logout.dart';

void main() {
  group('website logout', () {
    test('signs out only this installation and leaves Excel handoff state alone', () async {
      SignOutScope? observedScope;
      var excelStateCleared = false;

      await performInsightFlowLocalSignOut(
        signOut: (scope) async {
          observedScope = scope;
        },
      );

      expect(observedScope, SignOutScope.local);
      expect(excelStateCleared, isFalse);
    });
  });

  group('Excel-local logout', () {
    test('clears Excel capabilities and signs out only this installation', () async {
      SignOutScope? observedScope;
      var excelStateCleared = false;

      await performInsightFlowLocalSignOut(
        beforeSignOut: () => excelStateCleared = true,
        signOut: (scope) async => observedScope = scope,
      );

      expect(excelStateCleared, isTrue);
      expect(observedScope, SignOutScope.local);
    });
  });
}
