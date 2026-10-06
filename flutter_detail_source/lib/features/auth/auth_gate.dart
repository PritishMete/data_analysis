import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'management_shell.dart';\nimport 'employee_management_shell.dart';
import 'auth_glass_widgets.dart';
import 'company_registration_screen.dart';
import 'organization_onboarding_screen.dart';
import 'employee_profile_onboarding_screen.dart';
import 'employee_invitation_password_setup_screen.dart';
import 'sign_in_screen.dart';
import '../../widgets/insightflow_floating_brand.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  static String? _redirectErrorMessage() {
    final fragment = Uri.base.fragment.trim();
    if (fragment.isEmpty) return null;
    try {
      final values = Uri.splitQueryString(
        fragment.startsWith('#') ? fragment.substring(1) : fragment,
      );
      final error = (values['error'] ?? '').toLowerCase();
      final code = (values['error_code'] ?? '').toLowerCase();
      if (error.isEmpty && code.isEmpty) return null;
      if (code == 'otp_expired') {
        return 'This confirmation link has expired. Please request a new confirmation email.';
      }
      return 'This confirmation link could not be completed. Please sign in and request a new confirmation email.';
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final redirectError = _redirectErrorMessage();
    if (redirectError != null) {
      return _SupabaseRedirectErrorScreen(message: redirectError);
    }
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


class _SupabaseRedirectErrorScreen extends StatelessWidget {
  const _SupabaseRedirectErrorScreen({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: 'EMAIL / CONFIRMATION LINK',
      subtitle: 'SUPABASE AUTH',
      children: [
        AuthGlassMessage(text: message, error: true),
        const SizedBox(height: 12),
        const Text(
          'Use Sign in to return to InsightFlow. Email confirmation is checked again before workspace access.',
          style: TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.35),
        ),
        const SizedBox(height: 12),
        GlassButton.custom(
          onTap: () => Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => const SignInScreen()),
          ),
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'CONTINUE TO SIGN IN',
          child: const Text('CONTINUE TO SIGN IN'),
        ),
      ],
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
class _EmployeeManagementEntry extends StatefulWidget {
  const _EmployeeManagementEntry({required this.workspaceId});
  final String workspaceId;

  @override
  State<_EmployeeManagementEntry> createState() => _EmployeeManagementEntryState();
}

class _EmployeeManagementEntryState extends State<_EmployeeManagementEntry> {
  bool loading = true;
  bool employeeCell = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 8),
      );
      if (session == null || session.accessToken.isEmpty) {
        throw StateError('Authenticated session could not be restored.');
      }
      final headers = await supabaseAuthHeaders();
      if (widget.workspaceId.isNotEmpty) {
        headers['X-InsightFlow-Workspace-ID'] = widget.workspaceId;
      }
      final response = await httpGetAuth(
        '/v1/authz/management/overview',
        headers: headers,
      );
      final data = response is Map
          ? Map<String, dynamic>.from(response)
          : const <String, dynamic>{};
      final policy = data['ui_policy'];
      final sections = policy is Map && policy['sections'] is List
          ? (policy['sections'] as List).map((value) => value.toString()).toList()
          : const <String>[];
      if (!mounted) return;
      setState(() {
        employeeCell = sections.length == 1 && sections.first == 'overview';
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const _AuthLoading();
    if (error != null) {
      return AuthGlassScaffold(
        title: 'AUTH / MANAGEMENT POLICY',
        subtitle: 'AUTHORIZATION LOOKUP',
        children: [
          AuthGlassMessage(text: error!, error: true),
          const SizedBox(height: 12),
          GlassButton.custom(
            onTap: _resolve,
            width: double.infinity,
            height: 44,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'Retry',
            child: const Text('Retry'),
          ),
        ],
      );
    }
    return employeeCell
        ? const EmployeeManagementShell()
        : const ManagementShell();
  }
}



class _AuthenticatedGateState extends State<_AuthenticatedGate> {
  bool _loading = true;
  bool _verificationRequired = false;
  bool _workspaceLookupFailed = false;
  InsightFlowOnboardingState _onboardingState =
      InsightFlowOnboardingState.initializing;
  List<Map<String, dynamic>> _pendingInvitations = const [];
  String? _authoritativeWorkspaceId;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh({
    bool showLoading = true,
  }) async {
    if (!mounted) return;

    if (showLoading) {
      setState(() {
        _loading = true;
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
          if (mounted) {
            setState(() {
              _loading = false;
              _workspaceLookupFailed = true;
            });
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
        // Continue to the authoritative /v1/authz/me lookup. A temporary
        // profile/identity timeout must never be interpreted as "no company".
      }

      if (currentUser == null ||
          InsightFlowSupabaseAuthService.currentUser == null) {
        return;
      }

      // A cached workspace is intentionally NOT sufficient to render the
      // authenticated application. Browser refresh/session restoration can
      // briefly contain stale continuity data. The backend authorization
      // response is the authoritative source for membership/company state.
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
        _authoritativeWorkspaceId = resolved.workspaceId;
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
          _workspaceLookupFailed = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _workspaceLookupFailed = true;
        });
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
      case InsightFlowOnboardingState.initializing:
        // Registration is never the default/fallback state. It is reachable
        // only after the authoritative backend lookup explicitly returns
        // noMembership.
        authenticatedChild = const _AuthLoading();
        break;
      case InsightFlowOnboardingState.profileIncomplete:
        authenticatedChild = EmployeeProfileOnboardingScreen(
          workspaceId: _authoritativeWorkspaceId ?? '',
          onCompleted: () async => _refresh(showLoading: false),
        );
        break;
      case InsightFlowOnboardingState.activeMember:
        authenticatedChild = _EmployeeManagementEntry(
          workspaceId: _authoritativeWorkspaceId ?? '',
        );
        break;
      case InsightFlowOnboardingState.pendingInvitation:
        final passwordInvitation = _pendingInvitations.firstWhere(
          (item) => item['password_setup_at'] == null &&
              item['email_delivery_status'] == 'initiated',
          orElse: () => <String, dynamic>{},
        );
        if (passwordInvitation.isNotEmpty) {
          authenticatedChild = EmployeeInvitationPasswordSetupScreen(
            invitation: passwordInvitation,
            onCompleted: () async {
              await _refresh(showLoading: false);
            },
          );
        } else {
          authenticatedChild = OrganizationOnboardingScreen(
            state: {'pending_invitations': _pendingInvitations},
            onCompleted: () async {
              await _refresh(showLoading: false);
            },
          );
        }
        break;
      case InsightFlowOnboardingState.noMembership:
        authenticatedChild = const CompanyRegistrationScreen();
        break;
      case InsightFlowOnboardingState.transientFailure:
        authenticatedChild = AuthGlassScaffold(
          title: 'AUTH / WORKSPACE LOOKUP',
          subtitle: 'ORGANIZATION AUTHORIZATION TEMPORARILY UNAVAILABLE',
          children: [
            const AuthGlassMessage(
              text:
                  'InsightFlow could not confirm your organization membership. Your account was not sent to company registration. Retry when the organization service is available.',
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
        break;
      case InsightFlowOnboardingState.authoritativeDenial:
        authenticatedChild = AuthGlassScaffold(
          title: 'AUTH / ACCESS DENIED',
          subtitle: 'ORGANIZATION AUTHORIZATION REJECTED',
          children: [
            const AuthGlassMessage(
              text:
                  'The organization service rejected this session. Cached workspace data cannot restore access. Sign in again to continue.',
              error: true,
            ),
            const SizedBox(height: 12),
            GlassButton.custom(
              onTap: InsightFlowSupabaseAuthService.signOut,
              width: double.infinity,
              height: 44,
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              label: 'Sign out',
              child: const Text('Sign out'),
            ),
          ],
        );
        break;
    }
    // ManagementShell provides its own InsightFlow header branding.
    // Keep the floating brand on the other authenticated app surfaces.
    if (_onboardingState == InsightFlowOnboardingState.activeMember) {
      return authenticatedChild;
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
