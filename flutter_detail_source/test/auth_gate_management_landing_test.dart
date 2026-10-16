import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every active member is routed through the Management Cell', () {
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
    expect(activeMemberBlock, contains('const ManagementShell()'));
    expect(activeMemberBlock, isNot(contains('const DataScreen()')));
    expect(activeMemberBlock, isNot(contains('managementRoles')));
  });
}
