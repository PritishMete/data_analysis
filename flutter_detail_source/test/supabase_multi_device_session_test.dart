import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../lib/core/auth/supabase_auth_service.dart';

void main() {
  group('Supabase multi-device session policy', () {
    test('persists and automatically refreshes a session on each installation', () {
      final options = InsightFlowSupabaseAuthService.authOptions;

      expect(options.persistSession, isTrue);
      expect(options.autoRefreshToken, isTrue);
      expect(
        options.authFlowType,
        kIsWeb ? AuthFlowType.implicit : AuthFlowType.pkce,
      );
      expect(options.detectSessionInUri, isTrue);
    });

    test('normal sign-out is scoped to this installation', () {
      expect(
        InsightFlowSupabaseAuthService.localSignOutScope,
        SignOutScope.local,
      );
    });
  });
}
