import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('application startup cannot activate Firebase as an auth provider', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('InsightFlowSupabaseAuthService.initialize()'));
    expect(source, contains('home: const AuthGate()'));
    expect(source, isNot(contains('Firebase.initializeApp')));
    expect(source, isNot(contains('initializeFirebasePersistence')));
    expect(source, isNot(contains('initializeGoogleSignIn')));
    expect(source, isNot(contains('firebaseInitError')));
  });

  test('sign-in screen does not expose a Firebase Microsoft fallback', () {
    final source = File('lib/features/auth/sign_in_screen.dart').readAsStringSync();

    expect(source, contains('InsightFlowSupabaseAuthService.signInWithPassword'));
    expect(source, isNot(contains('signInWithMicrosoft')));
    expect(source, isNot(contains('Continue with Microsoft')));
  });

  test('account management reads and mutates the Supabase identity', () {
    final source =
        File('lib/features/auth/account_management_screen.dart').readAsStringSync();

    expect(source, contains('InsightFlowSupabaseAuthService.currentSupabaseUser'));
    expect(source, contains('InsightFlowSupabaseAuthService.setPassword'));
    expect(source, contains('InsightFlowSupabaseAuthService.signOut'));
    expect(source, contains('/v1/authz/account/cleanup'));
    expect(source, isNot(contains('InsightFlowAuthService')));
    expect(source, isNot(contains('Firebase Authentication')));
    expect(source, isNot(contains('getIdToken')));
  });
}
