import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AuthGate distinguishes active, invitation, no-membership and failure states', () {
    final source = File('lib/features/auth/auth_gate.dart').readAsStringSync();
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();

    for (final state in [
      'InsightFlowOnboardingState.activeMember',
      'InsightFlowOnboardingState.pendingInvitation',
      'InsightFlowOnboardingState.noMembership',
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
    expect(onboarding, isNot(contains('firebaseAuthHeaders(')));
    expect(onboarding, isNot(contains('InsightFlowAuthService.currentUser')));
  });

  test('cached workspace is only continuity and authoritative reconciliation is bounded', () {
    final http = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final gate = File('lib/features/auth/auth_gate.dart').readAsStringSync();

    expect(http, contains('reconcileInsightFlowOnboardingWithRetry'));
    expect(http, contains('maxAttempts = 4'));
    expect(http, contains('InsightFlowOnboardingState.authoritativeDenial'));
    expect(http, contains('InsightFlowOnboardingState.noMembership'));
    expect(gate, contains('_hasCachedWorkspace'));
    expect(gate, contains('unawaited(_scheduleBackgroundRetry());'));
  });

  test('company registration explains branch identity and initial role', () {
    final source =
        File('lib/features/auth/company_registration_screen.dart').readAsStringSync();

    expect(source, contains('initial branch head'));
    expect(source, contains('unique identity label'));
    expect(source, contains('Active branches cannot reuse it'));
    expect(source, contains('special characters are allowed'));
    expect(source, contains('ManagementShell'));
  });

  test('management analysis route uses the existing DataScreen and returns to ManagementShell', () {
    final navigation =
        File('lib/features/auth/management_navigation.dart').readAsStringSync();
    final dataScreen =
        File('lib/features/dashboard/data_screen.dart').readAsStringSync();

    expect(navigation, contains('const DataScreen()'));
    expect(navigation, contains('const ManagementShell()'));
    expect(dataScreen, contains('openInsightFlowManagement(context)'));
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
}
