import 'package:flutter_test/flutter_test.dart';

import '../lib/core/auth/oauth_callback_cleanup_logic.dart';
import '../lib/core/auth/oauth_callback_cleanup_stub.dart';

void main() {
  test('removes OAuth callback parameters and preserves fragment', () {
    final calls = <String>[];
    final changed = cleanOAuthCallbackUrlFromUri(
      Uri.parse(
        '/?code=test&state=abc&error=example&error_description=failed'
        '&tenant=demo#after-login',
      ),
      calls.add,
    );

    expect(changed, isTrue);
    expect(calls, ['/??tenant=demo#after-login']);
  });

  test('preserves Excel handoff parameters during cleanup', () {
    final calls = <String>[];
    cleanOAuthCallbackUrlFromUri(
      Uri.parse('/?code=test&excelAuthDialog=1&excelAuthState=x'),
      calls.add,
    );

    expect(calls, ['/?excelAuthDialog=1&excelAuthState=x']);
  });

  test('replaces history exactly once without reloading', () {
    final calls = <String>[];
    final current = Uri.parse('/?code=test&workspace=one');

    expect(cleanOAuthCallbackUrlFromUri(current, calls.add), isTrue);
    expect(calls, ['/?workspace=one']);
    expect(cleanOAuthCallbackUrlFromUri(Uri.parse(calls.single), calls.add), isFalse);
    expect(calls, ['/?workspace=one']);
  });

  test('does not replace history when no OAuth callback parameters exist', () {
    final calls = <String>[];
    final changed = cleanOAuthCallbackUrlFromUri(
      Uri.parse('/?excelAuthDialog=1&excelAuthState=x#sheet'),
      calls.add,
    );

    expect(changed, isFalse);
    expect(calls, isEmpty);
  });

  test('non-web stub performs no browser operation', () {
    expect(() => cleanOAuthCallbackUrl(), returnsNormally);
  });
}
