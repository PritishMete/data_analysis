import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import 'auth_glass_widgets.dart';

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

  Future<void> _acceptInvitation(Map<String, dynamic> invitation) async {
    final workspaceId = invitation['workspace_id']?.toString() ?? '';
    final invitationId = invitation['invitation_id']?.toString() ?? '';
    if (workspaceId.isEmpty || invitationId.isEmpty) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final headers = await firebaseAuthHeaders(forceRefresh: true);
      final response = await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/accept'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'workspace_id': workspaceId,
          'invitation_id': invitationId,
        }),
      );
      final decoded = response.body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw StateError(
          decoded is Map
              ? decoded['detail']?.toString() ?? 'Invitation could not be accepted.'
              : 'Invitation could not be accepted.',
        );
      }
      final uid = InsightFlowAuthService.currentUser?.uid;
      if (uid != null) {
        await setInsightFlowWorkspaceId(uid, workspaceId);
      }
      await widget.onCompleted();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = error is StateError
            ? error.message.toString()
            : 'Invitation could not be accepted.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitations = (widget.state['pending_invitations'] is List)
        ? (widget.state['pending_invitations'] as List)
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
        : <Map<String, dynamic>>[];

    final primary = invitations.isNotEmpty ? invitations.first : null;
    final organization =
        primary?['organization_name']?.toString() ?? 'your organization';
    final role = primary?['role_id']?.toString() ?? 'assigned role';
    final employeeId = primary?['employee_id']?.toString();

    return AuthGlassScaffold(
      title: 'EMPLOYEE / ACCESS',
      subtitle: 'Your authenticated identity must be approved by an organization.',
      children: [
        if (primary != null) ...[
          AuthGlassMessage(
            text: 'You have an active invitation to ' +
                organization + '. Role: ' + role +
                (employeeId == null ? '' : ' · Employee ID: ' + employeeId),
          ),          const SizedBox(height: 14),
          GlassButton.custom(
            onTap: _busy ? () {} : () => _acceptInvitation(primary),
            enabled: !_busy,
            width: double.infinity,
            height: 46,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: _busy ? 'Activating…' : 'Accept Invitation',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy) const CupertinoActivityIndicator(),
                if (_busy) const SizedBox(width: 8),
                Text(
                  _busy ? 'Activating…' : 'Accept Invitation',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          const AuthGlassMessage(
            text:
                'This account is awaiting organization approval. Employees do not enter workspace IDs or create organization relationships themselves.',
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _message!, error: true),
        ],
        const SizedBox(height: 10),
        TextButton(
          onPressed: _busy ? null : InsightFlowAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
