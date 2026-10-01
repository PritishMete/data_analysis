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

    expect(source, contains('openInsightFlowAnalysis(context)'));
    expect(source, contains('LiquidGlassScope'));
    expect(source, contains('GlassBackgroundSource'));
    expect(source, contains('TechAnimatedBackground'));
    expect(source, contains('GlassCard'));
    expect(source, contains('GlassChip'));
    expect(source, contains('AdaptiveLiquidGlassLayer'));
    expect(source, contains('_managementAnalysisNavChip'));
    expect(source, contains('kInsightFlowNavigationGlassSettings'));
    expect(source, contains('management_navigation.dart'));
    expect(source, contains('AuthorizationManagementScreen('));
    expect(source, contains('onStartWorking:'));
    expect(source, contains("'/overview'"));
    expect(source, contains("'/locations'"));
    expect(source, contains("'/sections'"));
    expect(source, contains("'/people'"));
    expect(source, contains("'/assignments'"));
    expect(source, contains("'/audit?limit=100'"));
    expect(source, contains('Future<void>? _refreshFuture'));
    expect(source, contains('final active = _refreshFuture'));
    expect(source, contains('identical(_refreshFuture, future)'));
    expect(source, contains('Management service timed out while loading'));
    expect(source, isNot(contains('return await sendWithHeaders(')));
    expect(source, contains("'/assignments/manager'"));
    expect(source, contains("'/assignments/manager/change'"));
    expect(source, contains("'/assignments/team-lead'"));
    expect(source, contains("'/assignments/reporting'"));
    // Assignment Registry layout contract: keep compact identifiers intact,
    // bound the action control, and provide an explicit narrow-width path.
    expect(source, contains('Widget _assignmentRegistryValue('));
    expect(source, contains('maxLines: 1'));
    expect(source, contains('softWrap: false'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
    expect(source, contains('final compact = constraints.maxWidth < 620;'));
    expect(source, contains('final reportingAction = SizedBox('));
    expect(source, contains('width: 132'));
    expect(source, contains('_glassRow(child: _assignmentRegistryRow(a))'));
    expect(source, contains("a['employee_id']"));
    expect(source, contains("a['role_id']"));
    expect(source, contains("a['location_name']"));
    expect(source, contains("a['section_name']"));
    expect(source, contains("a['status']"));
  });
}
