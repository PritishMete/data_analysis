import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import '../dashboard/data_screen.dart';
import 'auth_glass_widgets.dart';
import 'company_registration_screen.dart';
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

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      // Company registration is the organization-creation entry point. Do not
      // probe /v1/authz/me before the user has submitted an organization name.
      await loadInsightFlowWorkspaceId(widget.user.uid);
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void didUpdateWidget(covariant _AuthenticatedGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.uid != widget.user.uid) {
      _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const _AuthLoading();

    final user = InsightFlowAuthService.currentUser ?? widget.user;
    if (insightFlowWorkspaceId.isNotEmpty) {
      return DataScreen(
        key: ValueKey('${user.uid}:$insightFlowWorkspaceId'),
      );
    }
    return const CompanyRegistrationScreen();
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

class _NoOrganizationAccessScreen extends StatelessWidget {
  const _NoOrganizationAccessScreen({required this.onRegisterCompany});

  final Future<void> Function() onRegisterCompany;

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: 'ORGANIZATION / ACCESS',
      subtitle: 'Authentication succeeded, but no company access is assigned.',
      children: [
        const AuthGlassMessage(
          text:
              'No InsightFlow organization access is assigned to this account. Employees must be approved by an organization administrator.',
        ),
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: onRegisterCompany,
          enabled: true,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Register Company',
          child: const Text(
            'Register Company',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
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
