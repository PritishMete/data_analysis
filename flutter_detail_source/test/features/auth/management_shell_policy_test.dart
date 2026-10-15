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

Future<void> _pumpManagementShell(
  WidgetTester tester,
  ManagementRequestOverride override,
) async {
  await tester.pumpWidget(
    MaterialApp(home: ManagementShell(requestOverride: override)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('explicit empty policy does not grant default Branch Head sections',
      (tester) async {
    await _pumpManagementShell(
      tester,
      (path) => _responseFor(path, sections: <String>[]),
    );

    expect(find.text('NO MANAGEMENT ACCESS'), findsOneWidget);
    expect(find.text('ORGANIZATION'), findsNothing);
    expect(find.text('PEOPLE'), findsNothing);
    expect(find.text('INVITATIONS'), findsNothing);
    expect(find.text('AUDIT'), findsNothing);
  });

  testWidgets('unknown-only policy does not grant default sections',
      (tester) async {
    await _pumpManagementShell(
      tester,
      (path) => _responseFor(
        path,
        sections: <String>['not-a-real-section'],
      ),
    );

    expect(find.text('NO MANAGEMENT ACCESS'), findsOneWidget);
    expect(find.text('ORGANIZATION'), findsNothing);
    expect(find.text('PEOPLE'), findsNothing);
  });

  testWidgets('missing policy is rejected as an invalid authorization response',
      (tester) async {
    await _pumpManagementShell(
      tester,
      (path) => _responseFor(path, includePolicy: false),
    );

    expect(find.text('MANAGEMENT SERVICE ERROR'), findsOneWidget);
    expect(find.textContaining('invalid permissions policy'), findsOneWidget);
  });

  testWidgets('malformed section policy is rejected',
      (tester) async {
    await _pumpManagementShell(
      tester,
      (path) => _responseFor(path, sections: 'overview'),
    );

    expect(find.text('MANAGEMENT SERVICE ERROR'), findsOneWidget);
    expect(find.textContaining('invalid permissions policy'), findsOneWidget);
  });
}
