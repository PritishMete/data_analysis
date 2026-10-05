import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() { // Pages deployment trigger: keep the startup authorization contract deployed.
  test('AuthGate distinguishes active, invitation, no-membership and failure states', () {
    final source = File('lib/features/auth/auth_gate.dart').readAsStringSync();
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();

    for (final state in [
      'InsightFlowOnboardingState.activeMember',
      'InsightFlowOnboardingState.pendingInvitation',
      'InsightFlowOnboardingState.noMembership',
      'InsightFlowOnboardingState.profileIncomplete',
      'InsightFlowOnboardingState.transientFailure',
      'InsightFlowOnboardingState.authoritativeDenial',
    ]) {
      expect(http, contains(state));
    }

    expect(source, contains('resolveInsightFlowOnboardingStateFromBackend'));
    expect(source, contains('OrganizationOnboardingScreen('));
    expect(source, contains('CompanyRegistrationScreen()'));
    expect(source, contains('ManagementShell()'));
    expect(
      source,
      contains("case InsightFlowOnboardingState.transientFailure:"),
    );
    expect(
      source,
      contains("case InsightFlowOnboardingState.authoritativeDenial:"),
    );
    expect(
      source,
      contains("ORGANIZATION AUTHORIZATION TEMPORARILY UNAVAILABLE"),
    );
    expect(
      source,
      contains("Cached workspace data cannot restore access."),
    );
  });

  test('pending invitation lookup and acceptance use Supabase authentication', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final onboarding =
        File('lib/features/auth/organization_onboarding_screen.dart').readAsStringSync();

    expect(http, contains('/v1/authz/invitations/pending'));
    expect(http, contains('supabaseAuthHeaders()'));
    expect(onboarding, contains('InsightFlowSupabaseAuthService.ensureSession()'));
    expect(onboarding, contains('final headers = await supabaseAuthHeaders();'));
    expect(onboarding, contains("invitation['organization_id']?.toString()"));
    expect(onboarding, isNot(contains('firebaseAuthHeaders(')));
    expect(onboarding, isNot(contains('InsightFlowAuthService.currentUser')));
  });

  test('startup waits for authoritative organization lookup before rendering registration', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final gate = File('lib/features/auth/auth_gate.dart').readAsStringSync();

    expect(http, contains('reconcileInsightFlowOnboardingWithRetry'));
    expect(http, contains('maxAttempts = 4'));
    expect(http, contains('InsightFlowOnboardingState.authoritativeDenial'));
    expect(http, contains('InsightFlowOnboardingState.noMembership'));
    expect(gate, contains('_loading = true;'));
    expect(gate, contains('resolveInsightFlowOnboardingStateFromBackend(widget.user.uid)'));
    expect(gate, contains('if (_loading) return const _AuthLoading();'));
    expect(gate, contains('case InsightFlowOnboardingState.noMembership:'));
    expect(gate, contains('Registration is never the default/fallback state'));
    expect(gate, isNot(contains('_hasCachedWorkspace')));
    expect(gate, isNot(contains('unawaited(_scheduleBackgroundRetry());')));
  });

  test('active invited employees are gated by backend profile completion before Management Cell', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final gate = File('lib/features/auth/auth_gate.dart').readAsStringSync();
    // Profile completion is read from the authoritative top-level /me response.
    expect(http, contains("decoded['profile_complete']"));
    expect(http, contains('InsightFlowOnboardingState.profileIncomplete'));
    expect(gate, contains('case InsightFlowOnboardingState.profileIncomplete:'));
    expect(gate, contains('EmployeeProfileOnboardingScreen('));
    expect(gate, contains('case InsightFlowOnboardingState.activeMember:'));
    expect(gate, contains('ManagementShell()'));
  });

  test('authoritative /me top-level state controls onboarding before workspace details', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final gate = File('lib/features/auth/auth_gate.dart').readAsStringSync();

    expect(http, contains("decoded['membership_status']"));
    expect(http, contains("decoded['profile_complete']"));
    expect(http, contains("decoded['role_ids']"));
    expect(http, contains("decoded['workspaces']"));
    expect(http, contains("if (membershipStatus == 'active')"));
    expect(http, contains("if (profileComplete != true)"));
    expect(http, contains('InsightFlowOnboardingState.profileIncomplete'));
    expect(http, isNot(contains("selected.containsKey('profile_complete')")));
    expect(http, isNot(contains("_roleIdsFromWorkspace")));
    expect(gate, contains('_authoritativeWorkspaceId'));
    expect(gate, contains('workspaceId: _authoritativeWorkspaceId ?? \'\''));
  });

  test('active employee with missing profile_complete cannot become activeMember', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final profileGuard = http.indexOf('if (profileComplete != true)');
    final activeReturn = http.indexOf(
      'InsightFlowOnboardingState.activeMember',
      profileGuard,
    );

    expect(profileGuard, greaterThanOrEqualTo(0));
    expect(activeReturn, greaterThan(profileGuard));
    expect(
      http.substring(profileGuard, activeReturn),
      contains('InsightFlowOnboardingState.profileIncomplete'),
    );
  });

  test('stale cached workspace cannot bypass authoritative profileIncomplete', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final activeBranch = http.indexOf("if (membershipStatus == 'active')");
    final profileGuard = http.indexOf('if (profileComplete != true)', activeBranch);

    expect(activeBranch, greaterThanOrEqualTo(0));
    expect(profileGuard, greaterThan(activeBranch));
    expect(
      http.substring(activeBranch, profileGuard),
      contains('setInsightFlowWorkspaceId(uid, authoritativeWorkspaceId)'),
    );
    expect(
      http.substring(profileGuard, profileGuard + 260),
      contains('InsightFlowOnboardingState.profileIncomplete'),
    );
  });

  test('completed employees and both management roles route to ManagementShell, never DataScreen', () {
    final gate = File('lib/features/auth/auth_gate.dart').readAsStringSync();
    final activeStart = gate.indexOf('case InsightFlowOnboardingState.activeMember:');
    final pendingStart = gate.indexOf(
      'case InsightFlowOnboardingState.pendingInvitation:',
      activeStart,
    );

    expect(activeStart, greaterThanOrEqualTo(0));
    expect(pendingStart, greaterThan(activeStart));
    final activeBlock = gate.substring(activeStart, pendingStart);
    expect(activeBlock, contains('const ManagementShell()'));
    expect(activeBlock, isNot(contains('DataScreen')));

    final management = File('lib/features/auth/management_shell.dart').readAsStringSync();
    expect(management, contains("contextData['role_ids']"));
    expect(management, contains("'organization_owner'"));
    expect(management, contains("'employee'"));
  });

  test('profile onboarding uses dropdowns without phone OTP and without email OTP', () {
    final registration =
        File('lib/features/auth/company_registration_screen.dart').readAsStringSync();
    final employee =
        File('lib/features/auth/employee_profile_onboarding_screen.dart').readAsStringSync();
    final geo =
        File('lib/core/profile/profile_geo_data.dart').readAsStringSync();
    final auth =
        File('lib/core/auth/supabase_auth_service.dart').readAsStringSync();

    expect(registration, contains('Country *'));
    expect(registration, contains('State / Province / Region *'));
    expect(registration, contains('ID Proof Type *'));
    expect(registration, contains('phone_country_calling_code'));
    expect(registration, isNot(contains('EMAIL OTP')));
    expect(employee, contains('Country *'));
    expect(employee, contains('State / Province / Region *'));
    expect(employee, contains("label: 'COUNTRY CODE *'"));
    expect(employee, isNot(contains('Email OTP')));
    expect(employee, isNot(contains("_field('Address Line 2'")));
    expect(geo, contains('subdivisionsForCountry'));
    expect(geo, contains('allCountries'));
    expect(geo, contains('idProofOptions'));
  });

  test('confirmation callback errors are rendered as a usable InsightFlow route', () {
    final gate = File('lib/features/auth/auth_gate.dart').readAsStringSync();
    expect(gate, contains('Uri.base.fragment'));
    expect(gate, contains('otp_expired'));
    expect(gate, contains('This confirmation link has expired'));
    expect(gate, contains('_SupabaseRedirectErrorScreen'));
  });

  test('company registration explains branch identity and initial role', () {
    final source =
        File('lib/features/auth/company_registration_screen.dart').readAsStringSync();

    expect(source, contains('initial Branch Head'));
    expect(source, contains('AUTO-GENERATED'));
    expect(source, isNot(contains("'employee_id':")));
    expect(source, contains("decoded['employee_id']"));
    expect(source, contains('Special characters are allowed.'));
    expect(source, contains('ManagementShell'));
  });

  test('management analysis route uses the existing DataScreen and returns to ManagementShell', () {
    final navigation =
        File('lib/features/auth/management_navigation.dart').readAsStringSync();
    final dataScreen =
        File('lib/features/dashboard/data_screen.dart').readAsStringSync();

    expect(navigation, contains('DataScreen('));
    expect(navigation, contains('const ManagementShell()'));
    expect(dataScreen, contains('openInsightFlowManagement(context)'));
  });

  test('protected Supabase headers restore or refresh the current session', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();

    expect(http, contains('final session = await InsightFlowSupabaseAuthService.ensureSession();'));
    expect(http, contains('final token = session?.accessToken;'));
    expect(http, contains("throw StateError('Supabase authentication required.')"));
  });

  test('execute pipeline uses the shared dock glass constants', () {
    final execute =
        File('lib/features/dashboard/execute_pipeline_fab.dart').readAsStringSync();
    final dock =
        File('lib/widgets/shared/dock_glass_material.dart').readAsStringSync();

    for (final constant in [
      'kDockLightIntensity',
      'kDockRefractiveIndex',
      'kDockSaturation',
    ]) {
      expect(dock, contains(constant));
      expect(execute, contains(constant));
    }
    expect(
      execute,
      contains("import '../../widgets/shared/dock_glass_material.dart'"),
    );
  });
  test('management Data Access is an integrated managed dataset workspace', () {
    final shell = File('lib/features/auth/management_shell.dart').readAsStringSync();
    final workspace = File('lib/features/auth/managed_dataset_access_workspace.dart').readAsStringSync();

    expect(shell, contains('ManagedDatasetAccessWorkspace'));
    expect(shell, isNot(contains("actionLabel: 'OPEN MANAGED DATASETS'")));
    expect(workspace, contains('/v1/managed-datasets'));
    expect(workspace, contains('/profile?preview_limit=5'));
    expect(workspace, contains('/rows?'));
    expect(workspace, contains("'limit=' + pageSize.toString()"));
    expect(workspace, contains('/working-copies'));
    expect(workspace, contains('/v1/authz/datasets/grants'));
    expect(workspace, contains('openInsightFlowAnalysis(context'));
    expect(workspace, contains('DOWNLOAD CSV'));
  });

  test('managed dataset backend reads physical tables when data_table_name is present', () {
    final repository = File('../datasets/repository.py').readAsStringSync();
    final physical = File('../datasets/physical_table.py').readAsStringSync();

    expect(repository, contains('if version is None or not version.data_table_name'));
    expect(repository, contains('version.data_table_name'));
    expect(repository, contains('schema="managed_data"'));
    expect(repository, contains('offset(max(0, offset))'));
    expect(repository, contains('limit(min(max(1, limit), 10000))'));
    expect(physical, contains('PHYSICAL_SCHEMA = "managed_data"'));
    expect(physical, contains('def physical_table_name(version_pk: str)'));
  });

}
