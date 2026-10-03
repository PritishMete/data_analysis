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
    expect(source, contains('backgroundColor: kAppBackgroundColor'));
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
    expect(source, contains("a['full_name']"));
    expect(source, contains("a['email_verified']"));
    expect(source, contains("a['phone_verified']"));
    expect(source, contains("a['id_proof_supplied']"));
    expect(source, contains('_showAssignmentProfile(a)'));
    expect(source, contains("request('/assignments/\${Uri.encodeComponent(assignmentId)}/profile')"));
    expect(source, contains('FutureBuilder<Map<String, dynamic>>'));
    expect(source, contains("'Loading profile…'"));
    expect(source, contains('_assignmentProfileFuture'));
    expect(source, contains('_selectedAssignmentProfile'));
    expect(source, contains('GestureDetector'));
    expect(source, contains('onTap: _closeAssignmentProfile'));
    expect(source, contains("'Close'"));
    expect(source, isNot(contains('barrierDismissible: false')));
    expect(source, isNot(contains('profile[\'full_name\']!')));
    expect(source, isNot(contains('profile[\'employee_id\']!')));
    expect(source, contains("fontSize: 11"));
    expect(source, contains("fontSize: 12"));
    expect(source, contains("fontSize: 19"));
    expect(source, isNot(contains("month + '/' + day + '/' + ist.year.toString()")));
    expect(source, contains("'PROFILE COMPLETENESS'"));
    expect(source, contains('BRANCH HEAD'));
    expect(source, contains('No separate manager assigned'));
    // Assignment Registry layout contract: keep compact identifiers intact,
    // bound the action control, and provide an explicit narrow-width path.
    expect(source, contains('Widget _assignmentRegistryValue('));
    expect(source, contains('maxLines: 1'));
    expect(source, contains('softWrap: false'));
    expect(source, contains('overflow: TextOverflow.ellipsis'));
    expect(source, contains('final compact = constraints.maxWidth < 620;'));
    expect(source, contains('final reportingAction = SizedBox('));
    expect(source, contains('width: 132'));
    expect(source, contains('_assignmentRegistryRow(a)'));
    expect(source, contains("_profileFieldHeight = 72"));
    expect(source, contains("height: dialogHeight"));
    expect(source, contains("MediaQuery.sizeOf(context).height * 0.85"));
    expect(source, contains("constraints.maxWidth >= 560"));
    expect(source, contains("crossAxisCount: 2"));
    expect(source, contains("mainAxisExtent: _profileFieldHeight"));
    final profileOverlayStart = source.indexOf('_buildAssignmentProfileOverlay');
    final profileHeaderStart = source.indexOf(
      'final employeeId =',
      profileOverlayStart,
    );
    final profileHeaderEnd = source.indexOf(
      "const SizedBox(height: 8),\n                              Divider(",
      profileHeaderStart,
    );
    expect(profileHeaderStart, greaterThanOrEqualTo(0));
    expect(profileHeaderEnd, greaterThan(profileHeaderStart));
    final profileHeader = source.substring(
      profileHeaderStart,
      profileHeaderEnd,
    );
    expect(profileHeader, contains("employeeId.isEmpty ? '—' : employeeId"));
    expect(profileHeader, contains("textAlign: TextAlign.right"));
    expect(profileHeader, contains("const Spacer()"));
    expect(profileHeader, isNot(contains("'EMPLOYEE ID'")));
    expect(profileHeader, isNot(contains("Icons.close_rounded")));
    expect(profileHeader, isNot(contains("tooltip: 'Close'")));
    expect(source, contains("final profileCompletion = completion != 100"));
    expect(source, contains("if (profileCompletion != null)"));
    expect(source, contains("profileCompletion,"));
    expect(source, contains("GridView.count("));
    expect(source, contains("children: gridChildren"));

    expect(source, contains("glowIntensity: 0"));
    expect(source, contains("shadowElevation: 0"));
    expect(source, contains("glowColor: Colors.transparent"));
    expect(source, contains("if (completion != 100)"));
    expect(source, contains("return '\$month/\$day/\${ist.year}"));
    expect(source, isNot(contains("day + '/' + month + '/' + ist.year.toString()")));

    final detailsStart = source.indexOf('final details = <Widget>[');
    final detailsEnd = source.indexOf('return LayoutBuilder', detailsStart);
    expect(detailsStart, greaterThanOrEqualTo(0));
    expect(detailsEnd, greaterThan(detailsStart));
    final detailsBlock = source.substring(detailsStart, detailsEnd);
    final fieldOrder = [
      'ROLE',
      'EMAIL',
      'EMAIL VERIFIED',
      'PHONE',
      'PHONE VERIFIED',
      'ADDRESS LINE 1',
      'ADDRESS LINE 2',
      'STATE',
      'COUNTRY',
      'PIN / POSTAL CODE',
      'ID PROOF TYPE',
      'ID PROOF NUMBER',
      'BRANCH',
      'SECTION',
      'REPORTS TO',
      'ASSIGNMENT STATUS',
      'CREATED',
      'UPDATED',
      'PROFILE COMPLETENESS',
    ];
    var previous = -1;
    for (final field in fieldOrder) {
      final index = detailsBlock.indexOf("'$field'");
      expect(index, greaterThan(previous), reason: 'Field order changed at $field');
      previous = index;
    }

    expect(source, contains("a['employee_id']"));
    expect(source, contains("a['role_id']"));
    expect(source, contains("a['location_name']"));
    expect(source, contains("a['section_name']"));
    expect(source, contains("a['status']"));
  });
}
