import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sign-in uses Supabase email and password only', () {
    final source = File('lib/features/auth/sign_in_screen.dart').readAsStringSync();
    expect(source, contains('InsightFlowSupabaseAuthService.signInWithPassword'));
    expect(source, isNot(contains('signInWithGoogle')));
    expect(source, isNot(contains('signInWithMicrosoft')));
    expect(source, isNot(contains('FirebaseAuth')));
    expect(source, isNot(contains('GoogleAuthProvider')));
  });

  test('sign-up uses Supabase Auth only', () {
    final source = File('lib/features/auth/sign_up_screen.dart').readAsStringSync();
    expect(source, contains('InsightFlowSupabaseAuthService.signUp'));
    expect(source, isNot(contains('FirebaseAuth')));
    expect(source, isNot(contains('GoogleAuthProvider')));
    expect(source, isNot(contains('signInWithMicrosoft')));
  });

  test('compatibility auth facade delegates bearer tokens to Supabase', () {
    final source = File('lib/core/auth/insightflow_auth_service.dart').readAsStringSync();
    expect(source, contains('InsightFlowSupabaseAuthService.ensureSession'));
    expect(source, contains('session?.accessToken'));
    expect(source, isNot(contains('FirebaseAuth')));
    expect(source, isNot(contains('GoogleSignIn')));
    expect(source, isNot(contains('MicrosoftAuthProvider')));
  });
}
