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
}
