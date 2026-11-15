import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('production app entry point delegates to the Supabase auth gate', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains("import 'features/auth/auth_gate.dart';"));
    expect(source, contains('home: const AuthGate()'));
    expect(source, isNot(contains('class AuthGate extends StatefulWidget')));
    expect(source, isNot(contains('AuthScreen(')));
    expect(source, isNot(contains('onAuthenticated:')));
  });
}
