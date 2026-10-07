import 'dart:async';

import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'auth_glass_widgets.dart';

class EmployeeInvitationPasswordSetupScreen extends StatefulWidget {
  const EmployeeInvitationPasswordSetupScreen({
    super.key,
    required this.invitation,
    required this.onCompleted,
  });

  final Map<String, dynamic> invitation;
  final Future<void> Function() onCompleted;

  @override
  State<EmployeeInvitationPasswordSetupScreen> createState() =>
      _EmployeeInvitationPasswordSetupScreenState();
}

class _EmployeeInvitationPasswordSetupScreenState
    extends State<EmployeeInvitationPasswordSetupScreen> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    final password = _password.text;
    final confirm = _confirm.text;
    if (password.length < 8) {
      setState(() {
        _error = true;
        _message = 'Choose a password with at least 8 characters.';
      });
      return;
    }
    if (password != confirm) {
      setState(() {
        _error = true;
        _message = 'The passwords do not match.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      final authenticatedUser = InsightFlowSupabaseAuthService.currentUser;
      final invitedAuthUserId = widget.invitation['auth_user_id']?.toString().trim() ?? '';
      final invitedEmail = widget.invitation['email']?.toString().trim().toLowerCase() ?? '';
      final authenticatedEmail = authenticatedUser?.email?.trim().toLowerCase() ?? '';
      if (authenticatedUser == null || authenticatedUser.uid.isEmpty) {
        throw StateError('Open this invitation in a signed-in Supabase session for the invited email, then retry.');
      }
      // Do not change any account password until the invitation identity is verified.
      if (invitedAuthUserId.isNotEmpty && authenticatedUser.uid != invitedAuthUserId) {
        throw StateError('This invitation belongs to a different Supabase account. Sign out, reopen the invitation link, and retry.');
      }
      if (invitedEmail.isNotEmpty && authenticatedEmail != invitedEmail) {
        throw StateError('This invitation was sent to $invitedEmail. Sign out, reopen the invitation link, and use that account.');
      }
      debugPrint('invitation_lifecycle identity_verified=true');
      debugPrint('invitation_lifecycle password_setup_started');
      await InsightFlowSupabaseAuthService.setPassword(
        password,
        timeout: const Duration(seconds: 10),
      );
      debugPrint('invitation_lifecycle password_setup_response status=success');
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 5),
      );
      if (session == null || session.accessToken.isEmpty) {
        debugPrint('invitation_lifecycle session_available=false');
        throw StateError('Your authenticated session could not be restored.');
      }
      final authenticatedEmail = InsightFlowSupabaseAuthService.currentUser?.email;
      debugPrint('invitation_lifecycle session_available=true');
      debugPrint('invitation_lifecycle authenticated_email_available=${authenticatedEmail?.trim().isNotEmpty == true}');

      final response = await http
          .post(
            Uri.parse(
              '$insightFlowBackendBaseUrl/v1/authz/invitations/password-setup-complete',
            ),
        headers: {
          ...await supabaseAuthHeaders(),
          'Content-Type': 'application/json',
        },
            body: jsonEncode({
              'invitation_id': widget.invitation['invitation_id']?.toString() ?? '',
            }),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('invitation_lifecycle password_setup_response status=${response.statusCode}');
      if (response.statusCode != 200) {
        dynamic decoded;
        try {
          decoded = jsonDecode(response.body);
        } catch (_) {}
        throw StateError(
          decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : 'Password setup could not be completed.',
        );
      }
      final invitationId = widget.invitation['invitation_id']?.toString() ?? '';
      if (invitationId.isEmpty) {
        throw StateError('This invitation is incomplete. Please request a new invitation.');
      }
      debugPrint('invitation_lifecycle pending_invitation_loaded=true');
      debugPrint('invitation_lifecycle invitation_acceptance_started');
      final acceptResponse = await http
          .post(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/accept'),
            headers: {
              ...await supabaseAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'invitation_id': invitationId}),
          )
          .timeout(const Duration(seconds: 10));
      debugPrint('invitation_lifecycle invitation_acceptance_response status=${acceptResponse.statusCode}');
      dynamic acceptDecoded;
      try {
        acceptDecoded = acceptResponse.body.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(acceptResponse.body);
      } catch (_) {}
      if (acceptResponse.statusCode != 200) {
        throw StateError(
          acceptDecoded is Map && acceptDecoded['detail'] != null
              ? acceptDecoded['detail'].toString()
              : 'Invitation could not be activated. Please try again.',
        );
      }
      debugPrint('invitation_lifecycle onboarding_navigation_started');
      await widget.onCompleted().timeout(const Duration(seconds: 10));
    } catch (error, stackTrace) {
      debugPrint('invitation_lifecycle failure error_class=${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message = error is StateError
            ? error.message.toString()
            : error is TimeoutException
                ? 'The invitation setup took too long. Please retry.'
                : 'Invitation setup could not be completed. Please retry.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final organization = widget.invitation['organization_name']?.toString().trim() ?? '';
    final displayOrganization = organization.isEmpty ? 'your organization' : organization;
    final role = widget.invitation['role_id']?.toString() ?? 'data_analyst';

    return AuthGlassScaffold(
      title: 'INVITED ACCOUNT SETUP',
      subtitle: 'Secure your invited InsightFlow account.',
      children: [
        AuthGlassMessage(
          text: "You’re invited to join $displayOrganization. Complete your employee onboarding to access your organization workspace as ${role.replaceAll('_', ' ')}. Your email is verified through Supabase Auth.",
          error: false,
        ),
        const SizedBox(height: 14),
        const AuthGlassFieldLabel('NEW PASSWORD'),
        const SizedBox(height: 6),
        GlassTextField(
          controller: _password,
          placeholder: 'Create password',
          enabled: !_busy,
          obscureText: _obscure,
        ),
        const SizedBox(height: 10),
        const AuthGlassFieldLabel('CONFIRM PASSWORD'),
        const SizedBox(height: 6),
        GlassTextField(
          controller: _confirm,
          placeholder: 'Confirm password',
          enabled: !_busy,
          obscureText: _obscure,
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _busy ? null : () => setState(() => _obscure = !_obscure),
            child: Text(_obscure ? 'Show password' : 'Hide password'),
          ),
        ),
        if (_message != null) ...[
          AuthGlassMessage(text: _message!, error: _error),
          const SizedBox(height: 10),
        ],
        GlassButton.custom(
          onTap: _busy ? () {} : _complete,
          enabled: !_busy,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: _busy ? 'Setting up…' : 'Set password',
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_busy) const CupertinoActivityIndicator(),
              if (_busy) const SizedBox(width: 8),
              Text(_busy ? 'Setting up…' : 'Set password'),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : InsightFlowSupabaseAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
