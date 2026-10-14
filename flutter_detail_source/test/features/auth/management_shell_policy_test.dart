import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/features/auth/management_shell.dart';

Future<Map<String, dynamic>> _responseFor(
  String path, {
  Object? sections = const <String>[],
  bool includePolicy = true,
}) async {
  switch (path) {
    case '/overview':
      return <String, dynamic>{
        if (includePolicy)
          'ui_policy': <String, dynamic>{'sections': sections},
        'actor': <String, dynamic>{'role_id': 'branch_head'},
        'summary': <String, dynamic>{},
        'organization': <String, dynamic>{'name': 'Test organization'},
      };
    case '/locations':
      return <String, dynamic>{'locations': <dynamic>[]};
    case '/sections':
      return <String, dynamic>{'sections': <dynamic>[]};
    case '/people':
      return <String, dynamic>{'people': <dynamic>[]};
    case '/assignments':
      return <String, dynamic>{'assignments': <dynamic>[]};
    case '':
      return <String, dynamic>{
        'audit': <dynamic>[],
        'invitations': <dynamic>[],
      };
    default:
      return <String, dynamic>{};
  }
}

void main() {
  testWidgets(
    'an explicit empty policy does not fall back to Branch Head defaults',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ManagementShell(
            requestOverride: (path) => _responseFor(path, sections: <String>[]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('NO MANAGEMENT ACCESS'), findsOneWidget);
      expect(find.text('ORGANIZATION'), findsNothing);
      expect(find.text('PEOPLE'), findsNothing);
      expect(find.text('INVITATIONS'), findsNothing);
      expect(find.text('AUDIT'), findsNothing);
    },
  );

  testWidgets(
    'an unknown-only policy does not fall back to Branch Head defaults',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ManagementShell(
            requestOverride: (path) => _responseFor(
              path,
              sections: <String>['not-a-real-section'],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('NO MANAGEMENT ACCESS'), findsOneWidget);
      expect(find.text('ORGANIZATION'), findsNothing);
      expect(find.text('PEOPLE'), findsNothing);
    },
  );

  testWidgets('a missing policy is shown as a management service error',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ManagementShell(
          requestOverride: (path) => _responseFor(
            path,
            includePolicy: false,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('MANAGEMENT SERVICE ERROR'), findsOneWidget);
    expect(
      find.textContaining('invalid permissions policy'),
      findsOneWidget,
    );
  });
}
