import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Management Cell and Data Screen share the authenticated navigation context', () {
    final navigation =
        File('lib/features/auth/management_navigation.dart').readAsStringSync();
    final dataScreen =
        File('lib/features/dashboard/data_screen.dart').readAsStringSync();

    expect(navigation, contains('DataScreen('));
    expect(navigation, contains('Navigator.of(context).push'));
    expect(navigation, contains('managedDatasetId'));
    expect(navigation, contains('managedVersionId'));
    expect(navigation, contains('managedWorkingCopyId'));

    expect(dataScreen, contains("tooltip: 'Access management'"));
    expect(dataScreen, contains('openInsightFlowManagement(context)'));
  });

  test('employee Management Cell does not fail on unauthorized audit/invitation requests', () {
    final shell =
        File('lib/features/auth/management_shell.dart').readAsStringSync();

    expect(shell, contains("if (permissions.contains('audit.view'))"));
    expect(shell, contains("if (permissions.contains('invitation.manage'))"));
    expect(shell, contains("if (_hasManagementPermission('audit.view'))"));
    expect(shell, contains("if (_hasManagementPermission('invitation.manage'))"));
    expect(shell, contains("request('/overview')"));
    expect(shell, contains("request('/people')"));
    expect(shell, contains("request('/assignments')"));
  });
}
