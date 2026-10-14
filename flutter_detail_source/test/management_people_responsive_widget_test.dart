import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/features/auth/management_shell.dart';

Future<Map<String, dynamic>> _fixtureResponse(String path) async {
  switch (path) {
    case '/overview':
      return {
        'actor': {'role_id': 'branch_head'},
        'ui_policy': {'sections': ['overview', 'people']},
        'summary': {
          'total_people': 4,
          'role_counts': {'branch_head': 1, 'manager': 1, 'team_lead': 1},
        },
      };
    case '/locations':
      return {'locations': []};
    case '/sections':
      return {'sections': []};
    case '/people':
      return {
        'people': [
          {
            'principal_id': 'principal-1',
            'full_name': 'Asha Banerjee',
            'email': 'asha@example.test',
            'employee_id': 'EMP-001',
            'role_id': 'branch_head',
            'status': 'active',
            'location_name': 'Kolkata',
            'section_name': 'Operations',
            'assignment_id': 'assignment-1',
          },
          {
            'principal_id': 'principal-2',
            'full_name': 'Rahul Das',
            'email': 'rahul@example.test',
            'employee_id': 'EMP-002',
            'role_id': 'manager',
            'status': 'active',
            'location_name': 'Kolkata',
            'section_name': 'Analytics',
            'assignment_id': 'assignment-2',
          },
          {
            'principal_id': 'principal-3',
            'full_name': 'Mira Sen',
            'email': 'mira@example.test',
            'employee_id': 'EMP-003',
            'role_id': 'team_lead',
            'status': 'active',
            'location_name': 'New Town',
            'section_name': 'Operations',
            'assignment_id': 'assignment-3',
          },
          {
            'principal_id': 'principal-4',
            'full_name': 'Dev Roy',
            'email': 'dev@example.test',
            'employee_id': 'EMP-004',
            'role_id': 'data_analyst',
            'status': 'active',
            'location_name': 'New Town',
            'section_name': 'Analytics',
            'assignment_id': 'assignment-4',
          },
        ],
      };
    case '/assignments':
      return {'assignments': []};
    case '':
      return {'audit': [], 'invitations': []};
    default:
      throw StateError('Unexpected management request: $path');
  }
}

void main() {
  const viewports = <({String label, Size size})>[
    (label: '375x812 mobile', size: Size(375, 812)),
    (label: '768x1024 tablet portrait', size: Size(768, 1024)),
    (label: '1024x768 tablet landscape', size: Size(1024, 768)),
    (label: '1366x768 desktop', size: Size(1366, 768)),
    (label: '1920x1080 wide desktop', size: Size(1920, 1080)),
  ];

  for (final viewport in viewports) {
    testWidgets('People view renders without layout exceptions at ${viewport.label}', (tester) async {
      tester.view.physicalSize = viewport.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(MaterialApp(
        home: ManagementShell(
          initialSection: ManagementSection.people,
          requestOverride: _fixtureResponse,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      await tester.pump();

      expect(find.text('Search people'), findsOneWidget);
      expect(find.text('Total people'), findsOneWidget);
      expect(find.text('Asha Banerjee'), findsOneWidget);
      expect(find.text('Rahul Das'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('People search empty state can be cleared on a narrow screen', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: ManagementShell(
        initialSection: ManagementSection.people,
        requestOverride: _fixtureResponse,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    final search = find.byType(TextField).first;
    await tester.ensureVisible(search);
    await tester.enterText(search, 'no-such-person');
    await tester.pump();

    expect(find.text('No people match your search'), findsOneWidget);
    await tester.ensureVisible(find.text('Clear search and filters'));
    await tester.tap(find.text('Clear search and filters'));
    await tester.pump();

    expect(find.text('Asha Banerjee'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
