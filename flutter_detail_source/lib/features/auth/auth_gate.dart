import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'management_shell.dart';
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
  InsightFlowOnboardingState _onboardingState =
      InsightFlowOnboardingState.noMembership;
  List<Map<String, dynamic>> _pendingInvitations = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _scheduleBackgroundRetry() async {
    if (_backgroundRetryScheduled) return;
    _backgroundRetryScheduled = true;
    await Future<void>.delayed(const Duration(seconds: 1));
    if (!mounted || InsightFlowSupabaseAuthService.currentUser == null) {
      _backgroundRetryScheduled = false;
      return;
    }

    final resolved = await reconcileInsightFlowOnboardingWithRetry(
      resolve: () => resolveInsightFlowOnboardingStateFromBackend(widget.user.uid),
    );
    _backgroundRetryScheduled = false;
    if (!mounted || InsightFlowSupabaseAuthService.currentUser == null) {
      return;
    }

    if (resolved == null) return;

    setState(() {
      _loading = false;
      _workspaceLookupFailed = false;
      _onboardingState = resolved.state;
      _pendingInvitations = resolved.pendingInvitations;
    });
  }

  Future<void> _refresh({
    bool showLoading = true,
    bool allowBackgroundRetry = true,
  }) async {
    if (!mounted) return;

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
      SupabaseAuthUser? currentUser =
          InsightFlowSupabaseAuthService.currentUser;
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
        // Auth restoration can be temporarily slow; workspace reconciliation
        // remains authoritative and bounded below.
      }

      if (currentUser == null ||
          InsightFlowSupabaseAuthService.currentUser == null) {
        return;
      }

      if (_hasCachedWorkspace) {
        // The cache is render-time continuity only. ManagementShell still
        // performs backend authorization on every protected request while the
        // authoritative reconciliation runs in the background.
        if (mounted) {
          setState(() {
            _loading = false;
            _verificationRequired = false;
            _workspaceLookupFailed = false;
            _onboardingState = InsightFlowOnboardingState.activeMember;
          });
        }
        unawaited(_scheduleBackgroundRetry());
        return;
      }

      final resolved = await reconcileInsightFlowOnboardingWithRetry(
        resolve: () =>
            resolveInsightFlowOnboardingStateFromBackend(widget.user.uid),
      );

      if (!mounted) return;

      if (InsightFlowSupabaseAuthService.currentUser == null) {
        return;
      }

      if (resolved == null) {
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
        _onboardingState = resolved.state;
        _pendingInvitations = resolved.pendingInvitations;
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
        if (_hasCachedWorkspace && allowBackgroundRetry) {
          await _scheduleBackgroundRetry();
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _workspaceLookupFailed = !_hasCachedWorkspace;
        });
        if (_hasCachedWorkspace && allowBackgroundRetry) {
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
            text:
                'InsightFlow could not confirm your organization membership. Your account was not sent to the data workspace. Retry when the organization service is available.',
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

    final Widget authenticatedChild;
    switch (_onboardingState) {
      case InsightFlowOnboardingState.activeMember:
        authenticatedChild = const ManagementShell();
        break;
      case InsightFlowOnboardingState.pendingInvitation:
        authenticatedChild = OrganizationOnboardingScreen(
          state: {'pending_invitations': _pendingInvitations},
          onCompleted: () async {
            await _refresh(showLoading: false);
          },
        );
        break;
      case InsightFlowOnboardingState.noMembership:
        authenticatedChild = const CompanyRegistrationScreen();
        break;
      case InsightFlowOnboardingState.transientFailure:
      case InsightFlowOnboardingState.authoritativeDenial:
        authenticatedChild = const CompanyRegistrationScreen();
        break;
    }
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
