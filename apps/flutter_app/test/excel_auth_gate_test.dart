import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/auth/excel_auth_gate.dart';

void main() {
  testWidgets('Excel browser handoff asks for pairing code and supports both sign-in methods',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ExcelAuthBrowserGate()));
    await tester.pump();

    expect(find.text('Sign in to InsightFlow'), findsOneWidget);
    expect(find.text('Excel pairing code'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Continue with email'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
  });
}
