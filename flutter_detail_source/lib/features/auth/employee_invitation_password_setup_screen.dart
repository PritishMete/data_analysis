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
    final existingSessionUser = InsightFlowSupabaseAuthService.currentUser;

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      final invitationToken =
          widget.invitation['token']?.toString().trim() ??
          Uri.base.queryParameters['token']?.trim() ??
          '';
      final invitedEmail =
          widget.invitation['email']?.toString().trim().toLowerCase() ?? '';
      if (invitationToken.isEmpty || invitedEmail.isEmpty) {
        throw StateError('This invitation link is incomplete or expired. Request a new invitation.');
      }
      if (existingSessionUser == null && password.length < 8) {
        throw StateError('Choose a password with at least 8 characters.');
      }
      if (existingSessionUser == null && password != confirm) {
        throw StateError('The passwords do not match.');
      }
      if (existingSessionUser != null &&
          existingSessionUser.email?.trim().toLowerCase() != invitedEmail) {
        throw StateError('Sign in with the exact email address this invitation was sent to.');
      }

      // The backend validates the token before creating the Auth user. The
      // password is never sent to a privileged endpoint or stored by Flutter.
      final redeemHeaders = <String, String>{
        'Content-Type': 'application/json',
      };
      if (existingSessionUser != null) {
        redeemHeaders.addAll(await supabaseAuthHeaders());
      }
      final redeemResponse = await http
          .post(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations/redeem'),
            headers: redeemHeaders,
            body: jsonEncode({'token': invitationToken, 'password': password}),
          )
          .timeout(const Duration(seconds: 20));
      dynamic redeemDecoded;
      try {
        redeemDecoded = jsonDecode(redeemResponse.body);
      } catch (_) {}
      if (redeemResponse.statusCode != 200) {
        throw StateError(
          redeemDecoded is Map && redeemDecoded['detail'] != null
              ? redeemDecoded['detail'].toString()
              : 'Invitation could not be activated. Please request a new invitation or retry.',
        );
      }

      // Redemption creates the account server-side; sign in only after the
      // backend has finalized organization and branch membership.
      if (existingSessionUser == null) {
        await InsightFlowSupabaseAuthService.signInWithPassword(
          email: invitedEmail,
          password: password,
        ).timeout(const Duration(seconds: 10));
      }
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 5),
      );
      if (session == null || session.accessToken.isEmpty) {
        throw StateError('Your account was created, but sign-in could not be completed. Sign in with your new password.');
      }
      debugPrint('invitation_lifecycle redemption_response status=${redeemResponse.statusCode}');
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
