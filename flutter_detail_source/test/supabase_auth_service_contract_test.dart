import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('authentication service uses Supabase Auth rather than Firebase Auth', () {
    final source = File('lib/core/auth/supabase_auth_service.dart').readAsStringSync();

    expect(source, contains('SupabaseClient'));
    expect(source, contains('client.auth.signInWithPassword'));
    expect(source, contains('client.auth.signUp'));
    expect(source, contains('client.auth.verifyOTP'));
    expect(source, contains('client.auth.signOut'));
    expect(source, isNot(contains('FirebaseAuth')));
    expect(source, isNot(contains('firebase_auth/firebase_auth.dart')));
  });
}
