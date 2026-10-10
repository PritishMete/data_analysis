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
      final invitedEmail =
          widget.invitation['email']?.toString().trim().toLowerCase() ?? '';
      final invitationId =
          widget.invitation['invitation_id']?.toString().trim() ?? '';
      final invitationToken =
          widget.invitation['token']?.toString().trim() ??
          Uri.base.queryParameters['token']?.trim() ??
          '';
      final legacyInvitation =
          widget.invitation['auth_user_id']?.toString().trim().isNotEmpty == true;
      if (invitedEmail.isEmpty ||
          invitationId.isEmpty ||
          (!legacyInvitation && invitationToken.isEmpty)) {
        throw StateError('This invitation is incomplete. Please request a new invitation.');
      }

      if (!legacyInvitation) {
        // Revalidate the one-time invitation immediately before creating an
        // Auth account. A page may have been open after its token expired or
        // was revoked; never create auth.users for an invalid invitation.
        final previewResponse = await http
            .get(
              Uri.parse(
                '$insightFlowBackendBaseUrl/v1/authz/invitations/preview',
              ).replace(queryParameters: {'token': invitationToken}),
            )
            .timeout(const Duration(seconds: 10));
        dynamic previewDecoded;
        try {
          previewDecoded = jsonDecode(previewResponse.body);
        } catch (_) {}
        if (previewResponse.statusCode != 200 ||
            previewDecoded is! Map ||
            previewDecoded['invitation_id']?.toString() != invitationId ||
            previewDecoded['email']?.toString().trim().toLowerCase() != invitedEmail) {
          throw StateError(
            previewDecoded is Map && previewDecoded['detail'] != null
                ? previewDecoded['detail'].toString()
                : 'This invitation is invalid, expired, or no longer active. Request a new invitation.',
          );
        }
      }

      var authenticatedUser = InsightFlowSupabaseAuthService.currentUser;
      var signedUpNow = false;

      if (authenticatedUser == null && legacyInvitation) {
        throw StateError(
          'Open this legacy invitation in the existing Supabase account for the invited email.',
        );
      }

      if (authenticatedUser == null) {
        final redirect = Uri.base.replace(
          queryParameters: <String, String>{
            ...Uri.base.queryParameters,
            'token': invitationToken,
          },
        ).toString();
        final signup = await InsightFlowSupabaseAuthService.signUp(
          email: invitedEmail,
          password: password,
          emailRedirectTo: redirect,
        );
        signedUpNow = signup.user != null;
        authenticatedUser = InsightFlowSupabaseAuthService.currentUser;

        if (signup.session == null || authenticatedUser == null) {
          if (!mounted) return;
          setState(() {
            _busy = false;
            _error = false;
            _message =
                'Your account has been created. Open the Supabase verification email, then return to this invitation link to finish activation.';
          });
          return;
        }
      }

      final authenticatedEmail =
          authenticatedUser.email?.trim().toLowerCase() ?? '';
      if (authenticatedUser.uid.isEmpty || authenticatedEmail != invitedEmail) {
        throw StateError(
          'This invitation was sent to $invitedEmail. Sign out, reopen the invitation link, and use that account.',
        );
      }

      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 5),
      );
      if (session == null || session.accessToken.isEmpty) {
        throw StateError('Your authenticated session could not be restored.');
      }

      // Legacy invitations created before the disposable-token model still
      // use password setup. New invitations already set the password during
      // signUp(), so never overwrite an existing account password.
      if (!signedUpNow && widget.invitation['auth_user_id'] != null) {
        await http
            .post(
              Uri.parse(
                '$insightFlowBackendBaseUrl/v1/authz/invitations/password-setup-complete',
              ),
              headers: {
                ...await supabaseAuthHeaders(),
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'invitation_id': invitationId,
                'token': invitationToken,
              }),
            )
            .timeout(const Duration(seconds: 10));
      }

      final acceptResponse = await http
          .post(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/accept'),
            headers: {
              ...await supabaseAuthHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'invitation_id': invitationId,
              'token': invitationToken,
            }),
          )
          .timeout(const Duration(seconds: 10));

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
      debugPrint('invitation_lifecycle invitation_acceptance_response status=200');
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
