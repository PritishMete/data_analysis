import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import '../dashboard/data_screen.dart';
import 'auth_glass_widgets.dart';
import 'organization_onboarding_screen.dart';
import 'sign_in_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: InsightFlowAuthService.userChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoading();
        }
        if (snapshot.hasError) {
          return const _AuthError();
        }
        final user = snapshot.data;
        if (user == null) return const SignInScreen();
        return _AuthenticatedGate(user: user);
      },
    );
  }
}

class _AuthenticatedGate extends StatefulWidget {
  const _AuthenticatedGate({required this.user});

  final User user;

  @override
  State<_AuthenticatedGate> createState() => _AuthenticatedGateState();
}

class _AuthenticatedGateState extends State<_AuthenticatedGate> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic>? _context;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await loadInsightFlowWorkspaceId(widget.user.uid);
      final verified = await InsightFlowAuthService.reloadCurrentUser();
      if (!verified) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      final headers = await firebaseAuthHeaders();
      if (insightFlowWorkspaceId.isNotEmpty) {
        headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
      }
      final response = await http.get(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/me'),
        headers: headers,
      );
      Map<String, dynamic> body = {};
      if (response.body.trim().isNotEmpty) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          body = Map<String, dynamic>.from(decoded);
        }
      }
      if (response.statusCode != 200) {
        throw _AuthorizationGateException(
          body['detail']?.toString() ??
              'Authorization status could not be verified.',
        );
      }
      if (mounted) {
        setState(() {
          _context = body;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      final disabled = error is FirebaseAuthException &&
          (error.code == 'user-disabled' || error.code == 'user-not-found');
      setState(() {
        _loading = false;
        _error = disabled
            ? 'ACCOUNT_SUSPENDED'
            : error is _AuthorizationGateException
                ? error.message
                : 'Authorization status could not be verified. Check your connection and try again.';
      });
    }
  }

  @override
  void didUpdateWidget(covariant _AuthenticatedGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.emailVerified != widget.user.emailVerified ||
        oldWidget.user.uid != widget.user.uid) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _AuthLoading();

    final user = InsightFlowAuthService.currentUser ?? widget.user;
    if (!user.emailVerified) {
      return EmailVerificationScreen(user: user);
    }

    if (_error == 'ACCOUNT_SUSPENDED') {
      return _AccessStateScreen(
        title: 'ACCOUNT / SUSPENDED',
        message: 'This Firebase account is disabled or no longer available. Contact your administrator.',
        action: InsightFlowAuthService.signOut,
        actionLabel: 'Sign out',
      );
    }

    final state = _context;
    if (state == null) {
      return _AccessStateScreen(
        title: 'AUTHORIZATION / UNAVAILABLE',
        message: _error ?? 'Organization access could not be established.',
        action: _refresh,
      );
    }

    final accountStatus = state['account_status']?.toString() ?? 'pending';
    final membershipStatus =
        state['membership_status']?.toString() ?? 'none';
    final workspaceAuthorized = state['workspace_authorized'] == true;

    if (accountStatus == 'suspended') {
      return _AccessStateScreen(
        title: 'ACCOUNT / SUSPENDED',
        message:
            'This account is suspended. Contact your organization administrator.',
        action: InsightFlowAuthService.signOut,
        actionLabel: 'Sign out',
      );
    }

    final authorizationState = state['authorization_state']?.toString() ?? '';
    if (authorizationState == 'suspended' || membershipStatus == 'suspended') {
      return _AccessStateScreen(
        title: 'ACCESS / SUSPENDED',
        message: 'Your organization access is suspended. Contact your organization administrator.',
        action: InsightFlowAuthService.signOut,
        actionLabel: 'Sign out',
      );
    }

    if (authorizationState == 'bootstrap_candidate' ||
        authorizationState == 'pending_invitation' ||
        authorizationState == 'no_membership' ||
        membershipStatus == 'invited' ||
        membershipStatus == 'approved') {
      return OrganizationOnboardingScreen(
        state: state,
        onCompleted: _refresh,
      );
    }

    if (membershipStatus != 'active' || !workspaceAuthorized) {
      return _AccessStateScreen(
        title: 'WORKSPACE / ACCESS PENDING',
        message: 'Your organization membership is not active yet. Check your access again or contact your organization administrator.',
        action: _refresh,
        actionLabel: 'Check access again',
      );
    }

    final resolvedWorkspaceId = state['workspace_id']?.toString();
    if (resolvedWorkspaceId != null && resolvedWorkspaceId.isNotEmpty) {
      setInsightFlowWorkspaceId(user.uid, resolvedWorkspaceId);
    }

    return DataScreen(
      key: ValueKey(
        '${user.uid}:${state['workspace_id'] ?? insightFlowWorkspaceId}',
      ),
    );
  }
}

class _AuthorizationGateException implements Exception {
  const _AuthorizationGateException(this.message);
  final String message;
}

class EmailVerificationScreen extends StatefulWidget {
  const EmailVerificationScreen({super.key, required this.user});

  final User user;

  @override
  State<EmailVerificationScreen> createState() => _EmailVerificationScreenState();
}

class _EmailVerificationScreenState extends State<EmailVerificationScreen> {
  bool _busy = false;
  String? _message;
  bool _error = false;

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await InsightFlowAuthService.sendEmailVerification();
      if (!mounted) return;
      setState(() {
        _message =
            'Verification email sent. Check your inbox and spam folder.';
        _error = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = InsightFlowAuthService.userFacingAuthError(error);
        _error = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final verified = await InsightFlowAuthService.reloadCurrentUser();
      if (!verified) {
        if (!mounted) return;
        setState(() {
          _message =
              'Your email is still unverified. Open the latest verification email and try again.';
          _error = true;
        });
        return;
      }
      if (mounted) {
        setState(() {
          _message = 'Email verified. Rechecking organization access…';
          _error = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _message = InsightFlowAuthService.userFacingAuthError(error);
          _error = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: 'EMAIL / VERIFICATION REQUIRED',
      subtitle: widget.user.email ?? 'Verify your email address to continue.',
      children: [
        AuthGlassMessage(
          text: _message ??
              'InsightFlow requires a verified email before organization or workspace authorization can begin.',
          error: _error,
        ),
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: _busy ? () {} : _check,
          enabled: !_busy,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Check verification',
          child: const Text(
            'Check verification',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        GlassButton.custom(
          onTap: _busy ? () {} : _resend,
          enabled: !_busy,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Resend verification email',
          child: const Text(
            'Resend verification email',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : InsightFlowAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _AccessStateScreen extends StatelessWidget {
  const _AccessStateScreen({
    required this.title,
    required this.message,
    required this.action,
    this.actionLabel = 'Retry',
  });

  final String title;
  final String message;
  final Future<void> Function() action;
  final String actionLabel;

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: title,
      subtitle: 'Authentication is separate from organization authorization.',
      children: [
        AuthGlassMessage(text: message),
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: action,
          enabled: true,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: actionLabel,
          child: Text(
            actionLabel,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: InsightFlowAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _AuthLoading extends StatelessWidget {
  const _AuthLoading();

  @override
  Widget build(BuildContext context) {
    return const AuthGlassScaffold(
      title: 'AUTH / INITIALIZING',
      subtitle: 'CHECKING IDENTITY AND WORKSPACE AUTHORIZATION',
      children: [
        Center(
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: TechColors.borderActive,
          ),
        ),
      ],
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError();

  @override
  Widget build(BuildContext context) {
    return const AuthGlassScaffold(
      title: 'AUTH / ERROR',
      subtitle: 'AUTHENTICATION CHANNEL UNAVAILABLE',
      children: [
        AuthGlassMessage(
          text:
              'Authentication could not be initialized. Please reload the add-in.',
        ),
      ],
    );
  }
}
