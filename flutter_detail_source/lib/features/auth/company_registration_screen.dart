import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../dashboard/data_screen.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../core/auth/auth_diagnostic.dart';
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
  AuthDiagnosticAttempt? _authDiagnostic;
  OrganizationServiceDiagnostic? _organizationDiagnostic;

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

      if (mounted) setState(() => _busy = false);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message =
            '${InsightFlowAuthService.userFacingAuthError(error)}\n\nDiagnostic:\n${_authDiagnostic?.failureSummary ?? 'Stage: UNKNOWN\nAttempt: unavailable'}';
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
    final user = InsightFlowSupabaseAuthService.currentUser;
    if (user == null) {
      setState(() {
        _error = true;
        _message = 'Authenticate your identity before registering.';
      });
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });

    try {
      final result = await organizationServiceRequest(
        method: 'POST',
        path: '/v1/authz/organizations/register',
        contentType: 'application/json',
        send: (headers) => http.post(
          Uri.parse(
            '$insightFlowBackendBaseUrl/v1/authz/organizations/register',
          ),
          headers: headers,
          body: jsonEncode({'organization_name': name}),
        ),
      );
      _organizationDiagnostic = result.diagnostic;
      if (mounted) setState(() {});
      final response = result.response;
      dynamic decoded;
      try {
        decoded = response.body.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
      final detail = decoded is Map
          ? decoded['detail']?.toString().trim()
          : null;
      if (response.statusCode == 401) {
        throw StateError('InsightFlow authentication could not be verified.');
      }
      if (response.statusCode == 403) {
        throw StateError(
          detail?.isNotEmpty == true
              ? detail!
              : 'Your InsightFlow account is not authorized for this organization.',
        );
      }
      if (response.statusCode == 404) {
        throw StateError(
          'Organization registration is unavailable on this server version.',
        );
      }
      if (response.statusCode == 422) {
        throw StateError(
          'Organization registration request was rejected by the server.',
        );
      }
      if (response.statusCode >= 500) {
        throw StateError(
          "InsightFlow's organization service returned a server error.",
        );
      }
      if (response.statusCode != 200) {
        throw StateError(
          detail?.isNotEmpty == true
              ? detail!
              : 'InsightFlow could not create the organization.',
        );
      }
      final workspaceId = decoded is Map
          ? decoded['workspace_id']?.toString()
          : null;
      final organizationId = decoded is Map
          ? decoded['organization_id']?.toString()
          : null;
      if (workspaceId == null ||
          workspaceId.isEmpty ||
          organizationId == null ||
          organizationId.isEmpty) {
        throw StateError(
          'InsightFlow could not create the organization. The server returned an incomplete response.',
        );
      }
      await setInsightFlowWorkspaceId(user.uid, workspaceId);
      if (!mounted) return;
      Navigator.of(
        context,
      ).pushReplacement(MaterialPageRoute(builder: (_) => const DataScreen()));
    } on OrganizationServiceRequestException catch (error) {
      _organizationDiagnostic = error.diagnostic;
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = true;
        _message = 'InsightFlow couldn’t reach the organization service.';
      });
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

  String _registrationResponseCategory(int statusCode) {
    if (statusCode == 401) return 'authentication';
    if (statusCode == 403) return 'authorization';
    if (statusCode == 404) return 'route-not-found';
    if (statusCode == 422) return 'validation';
    if (statusCode >= 500) return 'server-error';
    if (statusCode >= 400) return 'client-error';
    return 'success';
  }

  @override
  Widget build(BuildContext context) {
    final user = InsightFlowSupabaseAuthService.currentUser;
    final authenticated = user != null;

    return AuthGlassScaffold(
      title: 'REGISTER / COMPANY',
      subtitle: authenticated
          ? 'Create a new organization for the authenticated identity.'
          : 'Authenticate the founder identity first.',
      children: [
        if (!authenticated) ...[
          GlassButton.custom(
            onTap: _busy
                ? () {}
                : () =>
                      _authenticate(InsightFlowAuthService.signInWithMicrosoft),
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
                _authDiagnostic = AuthDiagnosticAttempt();
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
                  () => InsightFlowAuthService.signInWithGoogleAccount(
                    account,
                    diagnostic: _authDiagnostic,
                  ),
                );
              },
              onError: (error) {
                if (!mounted) return;
                setState(() {
                  _busy = false;
                  _error = true;
                  _message =
                      '${InsightFlowAuthService.userFacingAuthError(error)}\n\nDiagnostic:\n${_authDiagnostic?.failureSummary ?? 'Stage: UNKNOWN\nAttempt: unavailable'}';
                });
              },
            )
          else
            GlassButton.custom(
              onTap: _busy
                  ? () {}
                  : () =>
                        _authenticate(InsightFlowAuthService.signInWithGoogle),
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
        if (_organizationDiagnostic != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(
            text: _organizationDiagnostic!.displayText,
            error: _organizationDiagnostic!.stage != 'HTTP_SUCCESS',
          ),
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
