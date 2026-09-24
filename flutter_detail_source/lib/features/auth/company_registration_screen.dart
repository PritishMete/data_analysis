import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import 'auth_glass_widgets.dart';
import 'google_web_sign_in_button.dart';

class CompanyRegistrationScreen extends StatefulWidget {
  const CompanyRegistrationScreen({super.key});

  @override
  State<CompanyRegistrationScreen> createState() =>
      _CompanyRegistrationScreenState();
}

class _CompanyRegistrationScreenState extends State<CompanyRegistrationScreen> {
  final _organizationController = TextEditingController();
  bool _busy = false;
  String? _message;
  bool _error = false;

  @override
  void dispose() {
    _organizationController.dispose();
    super.dispose();
  }

  Future<void> _authenticate(Future<Object?> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final result = await action();

      // Firebase redirect initiation legitimately returns null because the
      // browser leaves the page before authentication completes. Do not turn
      // that hand-off into a company-registration error.
      if (result == null) {
        if (mounted) setState(() => _busy = false);
        return;
      }

      final user = InsightFlowAuthService.currentUser;
      if (user != null && !user.emailVerified) {
        await InsightFlowAuthService.sendEmailVerification();
        if (mounted) {
          setState(() {
            _message =
                'Verify your email, then return here to complete company registration.';
            _busy = false;
          });
        }
        return;
      }
      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message = InsightFlowAuthService.userFacingAuthError(error);
      });
    }
  }

  Future<void> _register() async {
    final name = _organizationController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _error = true;
        _message = 'Enter your company or organization name.';
      });
      return;
    }
    final user = InsightFlowAuthService.currentUser;
    if (user == null) {
      setState(() {
        _error = true;
        _message = 'Authenticate your founder identity before registering.';
      });
      return;
    }
    if (!user.emailVerified) {
      setState(() {
        _error = true;
        _message = 'Verify your email before registering the company.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final headers = await firebaseAuthHeaders(forceRefresh: true);
      final response = await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/register-company'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({'organization_name': name}),
      );
      final decoded = response.body.trim().isEmpty
          ? <String, dynamic>{}
          : jsonDecode(response.body);
      if (response.statusCode != 200) {
        throw StateError(
          decoded is Map
              ? decoded['detail']?.toString() ?? 'Company registration failed.'
              : 'Company registration failed.',
        );
      }
      final workspaceId = decoded is Map
          ? decoded['workspace_id']?.toString()
          : null;
      if (workspaceId != null && workspaceId.isNotEmpty) {
        await setInsightFlowWorkspaceId(user.uid, workspaceId);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message = error is StateError
            ? error.message.toString()
            : 'Company registration could not be completed.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = InsightFlowAuthService.currentUser;
    final authenticated = user != null;

    return AuthGlassScaffold(
      title: 'REGISTER / COMPANY',
      subtitle: authenticated
          ? 'Create a new organization for the verified founder identity.'
          : 'Authenticate the founder identity first.',
      children: [
        if (!authenticated) ...[
          GlassButton.custom(
            onTap: _busy
                ? () {}
                : () => _authenticate(InsightFlowAuthService.signInWithMicrosoft),
            enabled: !_busy,
            width: double.infinity,
            height: 44,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'Continue with Microsoft',
            child: const Text(
              'Continue with Microsoft',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 8),
          if (kIsWeb)
            GoogleWebSignInButton(
              enabled: !_busy,
              onStarted: () {
                if (mounted) {
                  setState(() {
                    _busy = true;
                    _message = null;
                    _error = false;
                  });
                }
              },
              onAuthenticated: (account) async {
                await _authenticate(
                  () => InsightFlowAuthService.signInWithGoogleAccount(account),
                );
              },
              onError: (error) {
                if (!mounted) return;
                setState(() {
                  _busy = false;
                  _error = true;
                  _message = InsightFlowAuthService.userFacingAuthError(error);
                });
              },
            )
          else
            GlassButton.custom(
              onTap: _busy
                  ? () {}
                  : () => _authenticate(InsightFlowAuthService.signInWithGoogle),
              enabled: !_busy,
              width: double.infinity,
              height: 44,
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              label: 'Continue with Google',
              child: const Text(
                'Continue with Google',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ),
        ] else ...[
          const AuthGlassFieldLabel('Company / Organization Name'),
          GlassTextField(
            controller: _organizationController,
            placeholder: 'Company / Organization Name',
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _register(),
          ),
          const SizedBox(height: 12),
          GlassButton.custom(
            onTap: _busy ? () {} : _register,
            enabled: !_busy,
            width: double.infinity,
            height: 46,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: _busy ? 'Registering…' : 'Register Company',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_busy) const CupertinoActivityIndicator(),
                if (_busy) const SizedBox(width: 8),
                Text(
                  _busy ? 'Registering…' : 'Register Company',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _message!, error: _error),
        ],
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
      ],
    );
  }
}
