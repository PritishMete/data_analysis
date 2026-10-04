import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
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
      await InsightFlowSupabaseAuthService.setPassword(password);
      final session = await InsightFlowSupabaseAuthService.ensureSession();
      if (session == null || session.accessToken.isEmpty) {
        throw StateError('Your authenticated session could not be restored.');
      }

      final response = await http.post(
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
      );
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
      await widget.onCompleted();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message = error is StateError
            ? error.message.toString()
            : InsightFlowSupabaseAuthService.userFacingAuthError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final organization = widget.invitation['organization_name']?.toString() ??
        widget.invitation['organization_id']?.toString() ??
        'your organization';
    final role = widget.invitation['role_id']?.toString() ?? 'employee';

    return AuthGlassScaffold(
      title: 'EMPLOYEE / ACCOUNT SETUP',
      subtitle: 'Secure your invited InsightFlow account.',
      children: [
        AuthGlassMessage(
          text: 'You are invited to join $organization as ${role.replaceAll('_', ' ')}. Your email is verified through Supabase Auth.',
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
