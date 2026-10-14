import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/features/auth/management_shell.dart';

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

Future<Map<String, dynamic>> _emptyPeopleResponse(String path) async {
  final result = await _fixtureResponse(path);
  if (path == '/people') return {'people': <Map<String, dynamic>>[]};
  return result;
}

Future<Map<String, dynamic>> _errorPeopleResponse(String path) async {
  if (path == '/people') throw StateError('People fixture failed');
  return _fixtureResponse(path);
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

  testWidgets('People role filter and clear action restore the full list', (tester) async {
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

    final roleFilter = find.byType(DropdownButtonFormField<String>).last;
    await tester.ensureVisible(roleFilter);
    await tester.tap(roleFilter);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tap(find.text('Manager').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('Rahul Das'), findsOneWidget);
    expect(find.text('Asha Banerjee'), findsNothing);

    await tester.scrollUntilVisible(
      find.text('Clear filters'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Clear filters'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('Asha Banerjee'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('People loading state transitions to populated content', (tester) async {
    final peopleCompleter = Completer<Map<String, dynamic>>();

    Future<Map<String, dynamic>> delayedResponse(String path) {
      if (path == '/people') return peopleCompleter.future;
      return _fixtureResponse(path);
    }

    await tester.pumpWidget(MaterialApp(
      home: ManagementShell(
        initialSection: ManagementSection.people,
        requestOverride: delayedResponse,
      ),
    ));
    await tester.pump();

    expect(find.text('Asha Banerjee'), findsNothing);
    expect(tester.takeException(), isNull);

    peopleCompleter.complete({
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
      ],
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(find.text('Asha Banerjee'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('People empty state renders when there are no members', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ManagementShell(
        initialSection: ManagementSection.people,
        requestOverride: _emptyPeopleResponse,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(find.text('No people yet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Management error state renders when People request fails', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ManagementShell(
        initialSection: ManagementSection.people,
        requestOverride: _errorPeopleResponse,
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.pump();

    expect(find.text('MANAGEMENT SERVICE ERROR'), findsOneWidget);
    expect(find.text('People fixture failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

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
    await tester.scrollUntilVisible(
      find.text('Clear search and filters'),
      160,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Clear search and filters'));
    await tester.pump();

    expect(find.text('Asha Banerjee'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
