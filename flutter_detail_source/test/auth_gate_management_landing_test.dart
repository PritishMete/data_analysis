import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active members use the role-aware management entry', () {
    final source = File('lib/features/auth/auth_gate.dart').readAsStringSync();
    final start = source.indexOf(
      'case InsightFlowOnboardingState.activeMember:',
    );
    final end = source.indexOf(
      'case InsightFlowOnboardingState.pendingInvitation:',
      start,
    );

    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final activeMemberBlock = source.substring(start, end);
    expect(activeMemberBlock, contains('_EmployeeManagementEntry('));
    expect(activeMemberBlock, isNot(contains('const DataScreen()')));
  });

  test(
    'management roles remain in ManagementShell with overview-only policy',
    () {
      final source = File(
        'lib/features/auth/auth_gate.dart',
      ).readAsStringSync();

      expect(source, contains("'organization_owner'"));
      expect(source, contains("'branch_head'"));
      expect(source, contains("'manager'"));
      expect(source, contains("'team_lead'"));
      expect(
        source,
        contains('final managementRole = managementRoles.contains(roleId)'),
      );
      expect(source, contains('employeeCell = !managementRole &&'));
    },
  );

  test('shell state is keyed to the authenticated user and workspace', () {
    final source = File('lib/features/auth/auth_gate.dart').readAsStringSync();

    expect(source, contains(r"ValueKey('$userId:${widget.workspaceId}')"));
    expect(source, contains('ManagementShell(key: shellKey)'));
    expect(source, contains('EmployeeManagementShell(key: shellKey)'));
  });
}
