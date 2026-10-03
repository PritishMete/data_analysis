import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Phase 3 management shell exposes required navigation and existing DataScreen route', () {
    final source = File('lib/features/auth/management_shell.dart').readAsStringSync();

    final navigationStart = source.indexOf('const tabs = <MapEntry<ManagementSection, String>>[');
    final navigationEnd = source.indexOf('];', navigationStart);
    expect(navigationStart, greaterThanOrEqualTo(0));
    expect(navigationEnd, greaterThan(navigationStart));
    final navigation = source.substring(navigationStart, navigationEnd);
    for (final label in [
      "MapEntry(ManagementSection.overview, 'OVERVIEW')",
      "MapEntry(ManagementSection.organization, 'ORGANIZATION')",
      "MapEntry(ManagementSection.people, 'PEOPLE')",
      "MapEntry(ManagementSection.dataAccess, 'ACCESS')",
      "MapEntry(ManagementSection.invitations, 'INVITATIONS')",
      "MapEntry(ManagementSection.audit, 'AUDIT')",
    ]) {
      expect(navigation, contains(label));
    }
    expect(navigation, isNot(contains('LOCATIONS')));
    expect(navigation, isNot(contains('SECTIONS')));
    expect(navigation, isNot(contains('DATA ACCESS')));
    expect(navigation, isNot(contains('AUDIT LOG')));
    expect(navigation, isNot(contains('ANALYSIS')));
    expect(source, isNot(contains('_managementAnalysisNavChip')));
    expect(source, contains("_title('Audit', detail: 'SYSTEM EVENT STREAM'"));
    expect(source, contains('enum ManagementSection { overview, organization, people, invitations, dataAccess, audit }'));
    expect(source, isNot(contains('ManagementSection.locations')));
    expect(source, isNot(contains('ManagementSection.sections')));
    expect(source, contains("'CREATE LOCATION'"));
    expect(source, contains("'CREATE SECTION'"));
    expect(source, contains("'LOCATION → BRANCH HEAD / MANAGER → SECTION → TEAM LEAD → EMPLOYEE'"));
    expect(source, contains('selectedLocation = id'));
    expect(source, contains('selectedSection = sectionId'));
    expect(source, contains('selectedSection ?? sections.first'));
    expect(source, contains('assignmentList()'));
    expect(source, contains('actions()'));

    expect(source, contains('openInsightFlowAnalysis('));
    expect(source, contains('managedDatasetId: datasetId'));
    expect(source, contains('LiquidGlassScope'));
    expect(source, contains('GlassBackgroundSource'));
    expect(source, contains('TechAnimatedBackground'));
    expect(source, contains('backgroundColor: kAppBackgroundColor'));
    expect(source, contains('GlassCard'));
    expect(source, contains('GlassChip'));
    expect(source, contains('AdaptiveLiquidGlassLayer'));
    expect(source, isNot(contains('_managementAnalysisNavChip')));
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
      "Divider(",
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
    expect(source, contains('Widget _overviewSummaryCard('));
    expect(source, contains('Widget _overviewQuickAction('));
    expect(source, contains('Widget _overviewActivityItem('));
    expect(source, contains('Widget _overviewStructureStep('));
    expect(source, contains('Widget _overviewSkeleton()'));
    expect(source, contains('Organization overview'));
    expect(source, contains('Organization summary'));
    expect(source, contains('Quick actions'));
    expect(source, contains('Management attention'));
    expect(source, contains('Recent activity'));
    expect(source, contains('Organization structure'));
    expect(source, contains('Manage organization'));
    expect(source, contains('Review invitations'));
    expect(source, contains('Manage access'));
    expect(source, contains('View audit'));
    expect(source, contains('View organization'));
    expect(source, contains('ManagementSection.organization'));
    expect(source, contains('ManagementSection.people'));
    expect(source, contains('ManagementSection.invitations'));
    expect(source, contains('ManagementSection.dataAccess'));
    expect(source, contains('ManagementSection.audit'));
    expect(source, contains('_unassignedPeople()'));
    expect(source, contains('audit.take(5)'));
    expect(source, contains('_overviewSkeleton()'));
    expect(source, contains("Widget peopleView()"));
    expect(source, contains("View and manage the people in your organization"));
    expect(source, contains("Search people"));
    expect(source, contains("No people match your search"));
    expect(source, contains("No people match these filters"));
    expect(source, contains("No people yet"));
    expect(source, contains("Clear search and filters"));
    expect(source, contains("Total people"));
    expect(source, contains("Active members"));
    expect(source, contains("Assigned"));
    expect(source, contains("View details"));
    expect(source, contains("selectedLocation"));
    expect(source, contains("selectedSection"));
    expect(source, contains("constraints.maxWidth < 680"));
    expect(source, contains("request('')"));
    expect(source, contains("maps(r[6]['invitations'])"));
    expect(source, contains('Widget invitationView()'));
    expect(source, contains("maps(r[6]['invitations'])"));
    expect(source, isNot(contains('pendingInvitations = 0')));
    expect(source, contains('observedStatuses'));
    expect(source, contains('View invitation details'));
    expect(source, contains('_invitationPerson(item)'));
    expect(source, contains('full_name'));
    expect(source, contains('_invitationStatusChip'));
    expect(source, contains('_formatInvitationExpiry'));
    expect(source, contains('_invitationSkeleton()'));
    expect(source, contains("section == ManagementSection.invitations"));
    expect(source, contains('Invitation details'));
    expect(source, contains("item['invitation_id']"));
    expect(source, contains("item['expires_at']"));
    final invitationStart = source.indexOf('Widget invitationView()');
    final invitationEnd = source.indexOf('String _sectionLabel', invitationStart);
    expect(invitationStart, greaterThanOrEqualTo(0));
    expect(invitationEnd, greaterThan(invitationStart));
    final invitationUi = source.substring(invitationStart, invitationEnd);
    expect(source, contains('void _showInvitationDetails('));
    expect(source, contains('showDialog<void>'));
    expect(invitationUi, contains('_showInvitationDetails(item)'));
    expect(invitationUi, contains('Search invitations'));
    expect(invitationUi, contains('Clear filters'));
    expect(invitationUi, isNot(contains('Resend')));
    expect(invitationUi, isNot(contains('Cancel invitation')));
    expect(invitationUi, isNot(contains('Revoke invitation')));
    expect(source, contains('Search invitations'));
    expect(source, contains("tooltip: 'Clear search'"));
    expect(source, contains('Clear filters'));
    expect(source, contains('No invitations'));
    expect(source, contains('No invitations match your search'));
    expect(source, contains('No invitations match the selected status'));
    expect(source, contains("item['expires_at']"));
    expect(source, contains("item['role_id']"));
    expect(source, contains('constraints.maxWidth < 480'));
    expect(source, contains('Manage invitations sent to people in your organization'));
    expect(source, isNot(contains('INVITATION CONTROL')));
    expect(source, isNot(contains('CONTROL PLANE')));

    final access = File('lib/features/auth/managed_dataset_access_workspace.dart').readAsStringSync();
    expect(source, contains("MapEntry(ManagementSection.dataAccess, 'ACCESS')"));
    expect(access, contains("Text('Access'"));
    expect(access, contains('People and dataset access'));
    expect(access, contains('Search managed resources'));
    expect(access, contains('Clear search'));
    expect(access, contains('No managed resources are available in this scope yet.'));
    expect(access, contains('No resources match your search.'));
    expect(access, contains('Access is temporarily unavailable'));
    expect(access, contains("_action('RETRY'"));
    expect(access, contains('People and dataset access'));
    expect(access, contains("['dataset.view_original']"));
    expect(access, contains("'dataset.create_working_copy'"));
    expect(access, contains("'dataset.edit_working_copy'"));
    expect(access, contains('_accessPanel'));
    expect(access, isNot(contains('ORGANIZATION CONTROL PLANE')));


  });
}
