import 'dart:convert';

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
  State<OrganizationOnboardingScreen> createState() => _OrganizationOnboardingScreenState();
}

class _OrganizationOnboardingScreenState extends State<OrganizationOnboardingScreen> {
  final _organizationNameController = TextEditingController();
  bool _creating = false;
  bool _accepting = false;
  String? _error;
  List<Map<String, dynamic>> _liveInvitations = [];

  List<Map<String, dynamic>> get _invitations {
    if (_liveInvitations.isNotEmpty) return _liveInvitations;
    final raw = widget.state['pending_invitations'];
    return raw is List
        ? raw.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList()
        : <Map<String, dynamic>>[];
  }

  bool get _canCreateOrganization =>
      widget.state['authorization_state'] == 'bootstrap_candidate' && _invitations.isEmpty;

  @override
  void dispose() {
    _organizationNameController.dispose();
    super.dispose();
  }

  Future<void> _createOrganization() async {
    final name = _organizationNameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter an organization name.');
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final headers = await firebaseAuthHeaders();
      headers['Content-Type'] = 'application/json';
      final response = await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/bootstrap-owner'),
        headers: headers,
        body: jsonEncode({'organization_name': name}),
      );
      final decoded = response.body.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (response.statusCode != 200) {
        throw StateError(decoded['detail']?.toString() ??
            'Organization could not be created. Please try again.');
      }
      final workspaceId = decoded['workspace_id']?.toString();
      final uid = InsightFlowAuthService.currentUser?.uid;
      if (uid != null && workspaceId != null && workspaceId.isNotEmpty) {
        await setInsightFlowWorkspaceId(uid, workspaceId);
      }
      await widget.onCompleted();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error is StateError
          ? error.message.toString()
          : 'Organization could not be created. Please try again.');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _acceptInvitation(Map<String, dynamic> invitation) async {
    final workspaceId = invitation['workspace_id']?.toString();
    final invitationId = invitation['invitation_id']?.toString();
    if (workspaceId == null || workspaceId.isEmpty ||
        invitationId == null || invitationId.isEmpty) {
      setState(() => _error = 'This invitation is no longer available.');
      return;
    }
    setState(() {
      _accepting = true;
      _error = null;
    });
    try {
      final headers = await firebaseAuthHeaders();
      headers['Content-Type'] = 'application/json';
      final response = await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/accept'),
        headers: headers,
        body: jsonEncode({
          'workspace_id': workspaceId,
          'invitation_id': invitationId,
        }),
      );
      final decoded = response.body.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (response.statusCode != 200) {
        throw StateError(decoded['detail']?.toString() ??
            'The invitation could not be accepted.');
      }
      final uid = InsightFlowAuthService.currentUser?.uid;
      if (uid != null) await setInsightFlowWorkspaceId(uid, workspaceId);
      await widget.onCompleted();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error is StateError
          ? error.message.toString()
          : 'The invitation could not be accepted. Please try again.');
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  Future<void> _loadInvitations() async {
    setState(() {
      _error = null;
      _accepting = true;
    });
    try {
      final response = await http.get(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/pending'),
        headers: await firebaseAuthHeaders(),
      );
      final decoded = response.body.trim().isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      if (response.statusCode != 200) {
        throw StateError(decoded['detail']?.toString() ??
            'Organization invitations could not be checked.');
      }
      final invitations = (decoded['invitations'] as List?)
              ?.whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList() ??
          <Map<String, dynamic>>[];
      if (!mounted) return;
      setState(() {
        _liveInvitations = invitations;
        _error = invitations.isEmpty
            ? 'No organization invitation was found for this account. Ask your organization Manager or Owner to invite or approve your account.'
            : null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error is StateError
          ? error.message.toString()
          : 'Organization invitations could not be checked. Please try again.');
    } finally {
      if (mounted) setState(() => _accepting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitations = _invitations;
    final hasInvitations = invitations.isNotEmpty;
    return AuthGlassScaffold(
      title: hasInvitations ? 'ORGANIZATION / INVITATION' : 'WELCOME TO INSIGHTFLOW',
      subtitle: hasInvitations
          ? 'An organization invitation is waiting for this verified account.'
          : 'Your account is authenticated. Choose how you want to continue.',
      children: [
        if (_error != null) ...[
          AuthGlassMessage(text: _error!, error: true),
          const SizedBox(height: 12),
        ],
        if (hasInvitations)
          for (final invitation in invitations)
            GlassCard(
              padding: const EdgeInsets.all(14),
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "You've been invited to " +
                        (invitation['organization_name'] ??
                                invitation['organization_id'] ??
                                'an organization')
                            .toString(),
                    style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Role: ' +
                        (invitation['role_id'] ??
                                'Assigned organization role')
                            .toString(),
                    style: const TextStyle(
                      color: TechColors.textMuted,
                      fontSize: 11,
                    ),
                  ),
                  if (invitation['employee_id'] != null)
                    Text(
                      'Employee ID: ' + invitation['employee_id'].toString(),
                      style: const TextStyle(
                        color: TechColors.textMuted,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  const SizedBox(height: 10),
                  GlassButton.custom(
                    onTap: _accepting
                        ? () {}
                        : () => _acceptInvitation(invitation),
                    enabled: !_accepting,
                    width: double.infinity,
                    height: 44,
                    shape: const LiquidRoundedSuperellipse(borderRadius: 14),
                    label: 'Accept Invitation',
                    child: Text(
                      _accepting ? 'Accepting…' : 'Accept Invitation',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            )
        else ...[
          const Text(
            'Welcome to InsightFlow',
            style: TextStyle(
              color: TechColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'You are signed in and your email is verified, but you are not yet connected to an organization.',
            style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4),
          ),
          const SizedBox(height: 16),
          const AuthGlassFieldLabel('Organization Name'),
          GlassTextField(
            controller: _organizationNameController,
            placeholder: 'Organization Name',
            enabled: !_creating,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _createOrganization(),
          ),
          const SizedBox(height: 12),
          GlassButton.custom(
            onTap: _creating ? () {} : _createOrganization,
            enabled: !_creating && _canCreateOrganization,
            width: double.infinity,
            height: 46,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: _creating ? 'Creating…' : 'Create Organization',
            child: Text(
              _creating ? 'Creating…' : 'Create Organization',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: _creating || _accepting ? null : _loadInvitations,
            child: const Text('Join Organization'),
          ),
          const SizedBox(height: 4),
          const Text(
            'Joining is invitation-based. An organization name or workspace ID cannot be used to join automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(color: TechColors.textMuted, fontSize: 9),
          ),
        ],
      ],
    );
  }
}
