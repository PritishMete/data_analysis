import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('active-member routing uses authoritative role resolution', () {
    final source =
        File('lib/features/auth/auth_gate.dart').readAsStringSync();
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
    expect(activeMemberBlock, contains('resolveInsightFlowLandingRole'));
    expect(activeMemberBlock, contains("case 'branch_head':"));
    expect(activeMemberBlock, contains("case 'manager':"));
    expect(activeMemberBlock, contains("case 'employee':"));
    expect(activeMemberBlock, contains("case 'external_viewer':"));
    expect(activeMemberBlock, contains('ManagedDatasetAccessWorkspace(readOnly: true)'));
    expect(activeMemberBlock, contains('NO UNAMBIGUOUS ACTIVE ROLE'));
  });

  test('role resolver fails closed for missing, unknown, or conflicting roles', () {
    final source =
        File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    expect(source, contains('String? resolveInsightFlowLandingRole'));
    expect(source, contains('if (roles.isEmpty || roles.any'));
    expect(source, contains('if (roles.length != 1) return null;'));
  });

  test('external viewer workspace hides mutation controls', () {
    final source = File(
      'lib/features/auth/managed_dataset_access_workspace.dart',
    ).readAsStringSync();
    expect(source, contains('this.readOnly = false'));
    expect(source, contains('!widget.readOnly && roles.contains'));
    expect(source, contains('if (!widget.readOnly) ...['));
  });
}
