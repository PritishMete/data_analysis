import 'dart:async';

import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../app_colors.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
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
    final invitationId = invitation['invitation_id']?.toString() ?? '';
    if (invitationId.isEmpty) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final session = await InsightFlowSupabaseAuthService.ensureSession();
      if (session == null || session.accessToken.isEmpty) {
        throw StateError('Your authentication session could not be restored.');
      }
      final headers = await supabaseAuthHeaders();
      final response = await http
          .post(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/accept'),
            headers: {...headers, 'Content-Type': 'application/json'},
            body: jsonEncode({'invitation_id': invitationId}),
          )
          .timeout(const Duration(seconds: 10));
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
      // The server resolves the accepted invitation's organization and workspace.
      // Refresh authenticated onboarding state instead of trusting a client-supplied ID.
      await widget.onCompleted().timeout(const Duration(seconds: 10));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
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

  Widget _accessHeader({
    required String title,
    required String subtitle,
    required IconData icon,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 420;
        return GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: TechColors.fieldGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          padding: EdgeInsets.all(compact ? 14 : 20),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: TechColors.statusGreen.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: TechColors.statusGreen.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(icon, color: TechColors.statusGreen, size: 23),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    )),
                    const SizedBox(height: 5),
                    Text(subtitle, style: const TextStyle(
                      color: TechColors.textMuted,
                      fontSize: 12,
                      height: 1.4,
                    )),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _invitationSummary({
    required String organization,
    required String role,
    required String? employeeId,
  }) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.minimal,
      settings: TechColors.fieldGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('ACCESS SUMMARY', style: TextStyle(
            color: TechColors.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2,
            fontFamily: 'monospace',
          )),
          const SizedBox(height: 12),
          _summaryRow(Icons.apartment_rounded, 'Organization', organization),
          const SizedBox(height: 10),
          _summaryRow(Icons.verified_user_outlined, 'Assigned role', role),
          if (employeeId != null && employeeId.isNotEmpty) ...[
            const SizedBox(height: 10),
            _summaryRow(Icons.badge_outlined, 'Employee ID', employeeId),
          ],
        ],
      ),
    );
  }

  Widget _summaryRow(IconData icon, String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: TechColors.statusGreen, size: 18),
        const SizedBox(width: 10),
        SizedBox(
          width: 94,
          child: Text(label, style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 10,
          )),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text(value, style: const TextStyle(
          color: TechColors.textPrimary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ))),
      ],
    );
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
    final organization = primary?['organization_name']?.toString().trim() ?? '';
    final displayOrganization = organization.isEmpty ? 'your organization' : organization;
    final role = primary?['role_id']?.toString() ?? 'assigned role';
    final employeeId = primary?['employee_id']?.toString();

    return AuthGlassScaffold(
      title: 'EMPLOYEE / ACCESS',
      subtitle: 'Your authenticated identity must be approved by an organization.',
      wideContent: true,
      children: [
        _accessHeader(
          title: primary == null ? 'Your workspace access' : 'You’re invited to join',
          subtitle: primary == null
              ? 'Your organization will appear here when access is approved.'
              : 'Complete your employee onboarding to access $displayOrganization.',
          icon: primary == null ? Icons.hourglass_top_rounded : Icons.apartment_rounded,
        ),
        const SizedBox(height: 14),
        if (primary != null) ...[
          _invitationSummary(
            organization: displayOrganization,
            role: role,
            employeeId: employeeId,
          ),
          const SizedBox(height: 14),
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
          _invitationSummary(
            organization: 'Approval pending',
            role: 'Not assigned yet',
            employeeId: null,
          ),
          const SizedBox(height: 10),
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
          onPressed: _busy ? null : InsightFlowSupabaseAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
