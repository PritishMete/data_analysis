import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'authorization_management_screen.dart';
import 'auth_glass_widgets.dart';
import 'company_registration_screen.dart';
import 'sign_in_screen.dart';
import '../../widgets/insightflow_floating_brand.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: InsightFlowSupabaseAuthService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoading();
        }
        if (snapshot.hasError) {
          return const _AuthError();
        }
        final user = InsightFlowSupabaseAuthService.currentUser;
        if (user == null) return const SignInScreen();
        if (!user.emailVerified) {
          return const _SupabaseEmailVerificationScreen();
        }
        return _AuthenticatedGate(user: user);
      },
    );
  }
}


class _SupabaseEmailVerificationScreen extends StatefulWidget {
  const _SupabaseEmailVerificationScreen();

  @override
  State<_SupabaseEmailVerificationScreen> createState() =>
      _SupabaseEmailVerificationScreenState();
}

class _SupabaseEmailVerificationScreenState
    extends State<_SupabaseEmailVerificationScreen> {
  bool _busy = false;
  String? _message;
  bool _error = false;

  Future<void> _resend() async {
    final email = InsightFlowSupabaseAuthService.currentUser?.email;
    if (email == null || email.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await InsightFlowSupabaseAuthService.resendSignupVerification(email);
      if (!mounted) return;
      setState(() {
        _message = 'Verification email sent. Check your inbox and spam folder.';
        _error = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _message = 'Could not send the verification email. Please try again.';
        _error = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkVerification() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final authoritativeUser =
          await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
      final verified = authoritativeUser?.emailConfirmedAt != null;
      if (!mounted) return;
      setState(() {
        _message = verified
            ? 'Email verified. Continuing…'
            : 'Your email is still unverified. Open the latest verification email and try again.';
        _error = !verified;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = 'Your email is still unverified. Please verify it first.';
        _error = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signOut() async {
    await InsightFlowSupabaseAuthService.signOut();
  }

  @override
  Widget build(BuildContext context) {
    final email = InsightFlowSupabaseAuthService.currentUser?.email ?? '';
    return AuthGlassScaffold(
      title: 'EMAIL / VERIFICATION REQUIRED',
      subtitle: email,
      children: [
        AuthGlassMessage(
          text: _message ??
              'Your account is created, but your email address is not verified yet. Verify your email before continuing.',
          error: _error,
        ),
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: _busy ? () {} : _checkVerification,
          enabled: !_busy,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Check verification',
          child: const Text('Check verification',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        GlassButton.custom(
          onTap: _busy ? () {} : _resend,
          enabled: !_busy,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Resend verification email',
          child: const Text('Resend verification email',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : _signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}

class _AuthenticatedGate extends StatefulWidget {
  const _AuthenticatedGate({required this.user});

  final SupabaseAuthUser user;

  @override
  State<_AuthenticatedGate> createState() => _AuthenticatedGateState();
}

class _AuthenticatedGateState extends State<_AuthenticatedGate> {
  bool _loading = true;
  bool _verificationRequired = false;
  bool _workspaceLookupFailed = false;
  bool _hasCachedWorkspace = false;
  bool _backgroundRetryScheduled = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _scheduleBackgroundRetry() async {
    if (_backgroundRetryScheduled) return;
    _backgroundRetryScheduled = true;
    await Future<void>.delayed(const Duration(seconds: 2));
    _backgroundRetryScheduled = false;
    if (!mounted || InsightFlowSupabaseAuthService.currentUser == null) {
      return;
    }
    await _refresh(showLoading: false);
  }

  Future<void> _refresh({bool showLoading = true}) async {
    if (!mounted) return;

    // Restore the cached workspace before doing network work. Returning
    // devices should not be held on the Auth / Initializing screen while the
    // backend is waking up or the browser is restoring a session.
    await loadInsightFlowWorkspaceId(widget.user.uid);
    _hasCachedWorkspace = insightFlowWorkspaceId.trim().isNotEmpty;

    if (mounted) {
      setState(() {
        _loading = showLoading && !_hasCachedWorkspace;
        _verificationRequired = false;
        _workspaceLookupFailed = false;
      });
    }

    try {
      // This is authoritative when it responds, but it is deliberately
      // bounded. A restored session is allowed to use the cached workspace
      // while this check is being performed.
      SupabaseAuthUser? currentUser = InsightFlowSupabaseAuthService.currentUser;
      try {
        final authoritativeUser =
            await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
        if (authoritativeUser == null) {
          if (!_hasCachedWorkspace && mounted) {
            setState(() => _loading = false);
          }
          return;
        }
        currentUser = InsightFlowSupabaseAuthService.currentUser;
        final email = authoritativeUser.email;
        if (email != null &&
            email.isNotEmpty &&
            !await InsightFlowSupabaseAuthService.rememberDevice(email) &&
            !InsightFlowSupabaseAuthService.allowsCurrentSession(email)) {
          await InsightFlowSupabaseAuthService.signOut();
          return;
        }
        if (authoritativeUser.emailConfirmedAt == null) {
          if (mounted) {
            setState(() {
              _verificationRequired = true;
              _loading = false;
            });
          }
          return;
        }
      } on TimeoutException {
        // Do not turn a slow Supabase Auth response into a blocking screen.
        // The cached workspace remains usable while the backend reconciliation
        // below establishes the authoritative organization state.
      }

      if (currentUser == null ||
          InsightFlowSupabaseAuthService.currentUser == null) {
        return;
      }

      // The backend is the final source of truth for organization membership.
      // This no longer blocks a returning device's already-renderable portal.
      final resolved = await resolveInsightFlowWorkspaceFromBackend(
        widget.user.uid,
      );

      if (!mounted) return;

      if (InsightFlowSupabaseAuthService.currentUser == null) {
        // Workspace reconciliation may have invalidated a stale session.
        // Never render Company Registration from that intermediate state;
        // let the auth-state stream take the user back to Sign In.
        return;
      }

      if (resolved == null) {
        if (_hasCachedWorkspace) {
          // A temporary backend/cold-start failure must not replace a working
          // portal with an error screen. Retry in the background instead.
          setState(() {
            _loading = false;
            _workspaceLookupFailed = false;
          });
          await _scheduleBackgroundRetry();
          return;
        }

        setState(() {
          _loading = false;
          _workspaceLookupFailed = true;
        });
        return;
      }

      setState(() {
        _loading = false;
        _verificationRequired = false;
        _workspaceLookupFailed = false;
      });
    } on AuthException catch (error) {
      final message = error.message.toLowerCase();
      final invalidSession = message.contains('user not found') ||
          message.contains('user does not exist') ||
          message.contains('does not exist') ||
          message.contains('invalid jwt') ||
          message.contains('session not found') ||
          message.contains('session does not exist');
      if (invalidSession) {
        await InsightFlowSupabaseAuthService.signOut();
        return;
      }
      if (mounted) {
        setState(() {
          _loading = false;
          _workspaceLookupFailed = !_hasCachedWorkspace;
        });
        if (_hasCachedWorkspace) {
          await _scheduleBackgroundRetry();
        }
      }
    } catch (_) {
      // A returning device keeps its cached portal during transient network
      // failures. New users still receive the explicit retry state.
      if (mounted) {
        setState(() {
          _loading = false;
          _workspaceLookupFailed = !_hasCachedWorkspace;
        });
        if (_hasCachedWorkspace) {
          await _scheduleBackgroundRetry();
        }
      }
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
    if (_verificationRequired) {
      return const _SupabaseEmailVerificationScreen();
    }
    if (_workspaceLookupFailed) {
      return AuthGlassScaffold(
        title: 'AUTH / WORKSPACE LOOKUP',
        subtitle: 'AUTHENTICATED IDENTITY VERIFIED',
        children: [
          const AuthGlassMessage(
            text: 'InsightFlow could not confirm your organization membership. Your account was not sent to the data workspace. Retry when the organization service is available.',
          ),
          const SizedBox(height: 12),
          GlassButton.custom(
            onTap: _refresh,
            width: double.infinity,
            height: 44,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'Retry',
            child: const Text('Retry'),
          ),
        ],
      );
    }

    final authenticatedChild = insightFlowWorkspaceId.isNotEmpty
        ? const AuthorizationManagementScreen()
        : const CompanyRegistrationScreen();
    return AuthenticatedBrandShell(child: authenticatedChild);
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
