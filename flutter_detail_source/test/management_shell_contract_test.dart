import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Phase 3 management shell exposes required navigation and existing DataScreen route', () {
    final source = File('lib/features/auth/management_shell.dart').readAsStringSync();

    for (final label in [
      'Overview',
      'Organization',
      'People',
      'Locations',
      'Sections',
      'Invitations',
      'Data Access',
      'Audit Log',
      'Analysis',
    ]) {
      expect(source, contains(label));
    }

    expect(source, contains("const DataScreen()"));
    expect(source, contains("MaterialPageRoute(builder: (_) => const DataScreen())"));
    expect(source, contains("MaterialPageRoute(builder: (_) => const AuthorizationManagementScreen())"));
    expect(source, contains("'/overview'"));
    expect(source, contains("'/locations'"));
    expect(source, contains("'/sections'"));
    expect(source, contains("'/people'"));
    expect(source, contains("'/assignments'"));
    expect(source, contains("'/audit?limit=100'"));
    expect(source, contains("'/assignments/manager'"));
    expect(source, contains("'/assignments/manager/change'"));
    expect(source, contains("'/assignments/team-lead'"));
    expect(source, contains("'/assignments/reporting'"));
  });
}
