import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../lib/core/auth/supabase_auth_service.dart';

void main() {
  group('Supabase multi-device session policy', () {
    test('uses PKCE for browser and native clients', () {
      final options = InsightFlowSupabaseAuthService.authOptions;

      expect(options.persistSession, isTrue);
      expect(options.autoRefreshToken, isTrue);
      expect(options.authFlowType, AuthFlowType.pkce);
      expect(options.detectSessionInUri, isTrue);
    });

    test('local sign-out only ends this installation', () {
      expect(
        InsightFlowSupabaseAuthService.localSignOutScope,
        SignOutScope.local,
      );
    });

    test('other-session sign-out keeps the current session', () {
      expect(
        InsightFlowSupabaseAuthService.otherSessionsSignOutScope,
        SignOutScope.others,
      );
    });

    test('global sign-out ends all account sessions', () {
      expect(
        InsightFlowSupabaseAuthService.globalSignOutScope,
        SignOutScope.global,
      );
    });
  });
}
