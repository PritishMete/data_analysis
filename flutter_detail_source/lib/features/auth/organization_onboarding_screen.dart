import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'auth_glass_widgets.dart';
import 'employee_invitation_password_setup_screen.dart';

class OrganizationOnboardingScreen extends StatefulWidget {
  const OrganizationOnboardingScreen({
    super.key,
    required this.state,
    required this.onCompleted,
  });

  final Map<String, dynamic> state;
  final Future<void> Function() onCompleted;

  @override
  State<OrganizationOnboardingScreen> createState() =>
      _OrganizationOnboardingScreenState();
}

class _OrganizationOnboardingScreenState
    extends State<OrganizationOnboardingScreen> {
  bool _busy = false;
  String? _message;

  bool _requiresPasswordSetup(Map<String, dynamic> invitation) =>
      invitation['password_setup_at'] == null &&
      invitation['email_delivery_status'] == 'initiated';

  Future<void> _openPasswordSetup(
    Map<String, dynamic> invitation,
  ) async {
    if (_busy) return;
    final invitationId = invitation['invitation_id']?.toString().trim() ?? '';
    if (invitationId.isEmpty) {
      setState(() => _message =
          'This invitation is incomplete. Please ask your Branch Head to resend it.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
    final navigator = Navigator.of(context);
    try {
      await navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (routeContext) => EmployeeInvitationPasswordSetupScreen(
            invitation: invitation,
            onCompleted: () async {
              await widget.onCompleted();
              if (routeContext.mounted && navigator.canPop()) {
                navigator.pop();
              }
            },
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _acceptInvitation(Map<String, dynamic> invitation) async {
    if (_busy) return;
    final workspaceValue = invitation['workspace_id']?.toString().trim() ?? '';
    final workspaceId = workspaceValue.isNotEmpty
        ? workspaceValue
        : invitation['organization_id']?.toString().trim() ?? '';
    final invitationId = invitation['invitation_id']?.toString().trim() ?? '';
    if (workspaceId.isEmpty || invitationId.isEmpty) {
      setState(() => _message =
          'This invitation is incomplete. Please ask your Branch Head to resend it.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final session = await InsightFlowSupabaseAuthService.ensureSession();
      if (session == null || session.accessToken.isEmpty) {
        throw StateError('Your authentication session could not be restored.');
      }
      final uid = InsightFlowSupabaseAuthService.currentUser?.uid;
      if (uid == null || uid.isEmpty) {
        throw StateError('Your authenticated identity could not be verified.');
      }
      // Bind the selected invitation's workspace before building request
      // headers. Never reuse a workspace cached from a different invitation.
      await setInsightFlowWorkspaceId(uid, workspaceId);
      final headers = await supabaseAuthHeaders();
      final response = await http
          .post(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/accept'),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'invitation_id': invitationId}),
          )
          .timeout(const Duration(seconds: 10));
      dynamic decoded;
      try {
        decoded = response.body.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
      if (response.statusCode != 200) {
        throw StateError(
          decoded is Map
              ? decoded['detail']?.toString() ?? 'Invitation could not be accepted.'
              : 'Invitation could not be accepted.',
        );
      }
      if (decoded is Map && decoded['accepted'] == false) {
        throw StateError('The invitation was not activated. Please retry.');
      }
      await widget.onCompleted().timeout(const Duration(seconds: 10));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = error is StateError
            ? error.message.toString()
            : error is TimeoutException
                ? 'Invitation activation took too long. Please retry.'
                : 'Invitation could not be accepted. Please retry.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleInvitation(Map<String, dynamic> invitation) async {
    if (_requiresPasswordSetup(invitation)) {
      await _openPasswordSetup(invitation);
    } else {
      await _acceptInvitation(invitation);
    }
  }

  Widget _invitationCard(Map<String, dynamic> invitation) {
    final organization =
        invitation['organization_name']?.toString().trim() ?? '';
    final displayOrganization =
        organization.isEmpty ? 'your organization' : organization;
    final role = invitation['role_id']?.toString() ?? 'assigned role';
    final employeeId = invitation['employee_id']?.toString().trim() ?? '';
    final needsPassword = _requiresPasswordSetup(invitation);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthGlassMessage(
          text: 'Your invitation to $displayOrganization is ready. '
              'Your Branch Head assigned the role: ${role.replaceAll('_', ' ')}. '
              'This role cannot be changed during onboarding.'
              '${employeeId.isEmpty ? '' : ' · Employee ID: $employeeId'}',
        ),
        const SizedBox(height: 10),
        GlassButton.custom(
          onTap: _busy ? () {} : () => _handleInvitation(invitation),
          enabled: !_busy,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: _busy
              ? 'Please wait…'
              : needsPassword
                  ? 'Set password & join'
                  : 'Accept invitation',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) const CupertinoActivityIndicator(),
              if (_busy) const SizedBox(width: 8),
              Text(
                _busy
                    ? 'Please wait…'
                    : needsPassword
                        ? 'Set password & join'
                        : 'Accept invitation',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final invitations = widget.state['pending_invitations'] is List
        ? (widget.state['pending_invitations'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .where((item) =>
                item['invitation_id']?.toString().trim().isNotEmpty == true)
            .toList()
        : <Map<String, dynamic>>[];

    return AuthGlassScaffold(
      brandedLayout: true,
      fitViewport: true,
      title: 'INVITATION / YOUR WORKSPACE',
      subtitle: invitations.length > 1
          ? 'Choose the organization invitation you want to accept.'
          : 'Review your invitation and the access assigned by your Branch Head.',
      children: [
        if (invitations.isNotEmpty)
          for (var index = 0; index < invitations.length; index++) ...[
            if (index > 0) const SizedBox(height: 16),
            _invitationCard(invitations[index]),
          ]
        else
          const AuthGlassMessage(
            text:
                'Your account is awaiting organization approval. Employees do not enter workspace IDs or create organization relationships themselves.',
          ),
        if (_message != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _message!, error: true),
        ],
        const SizedBox(height: 10),
        TextButton(
          onPressed: _busy ? null : InsightFlowSupabaseAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
