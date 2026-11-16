import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/supabase_auth_service.dart';
import '../../core/interop/excel_auth_bridge.dart';
import 'sign_in_screen.dart';

/// Task-pane gate. It restores the add-in's own Supabase session first, then
/// opens an Office dialog for sign-in only when the task pane has no valid one.
class ExcelAuthGate extends StatefulWidget {
  const ExcelAuthGate({super.key});

  @override
  State<ExcelAuthGate> createState() => _ExcelAuthGateState();
}

class _ExcelAuthGateState extends State<ExcelAuthGate> {
  bool _checking = true;
  bool _openingDialog = false;
  String? _error;
  bool _attempted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSession());
  }

  Future<void> _checkSession() async {
    try {
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 5),
      );
      if (session != null) {
        final user = await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
          timeout: const Duration(seconds: 6),
        );
        if (user != null && user.emailConfirmedAt != null) {
          if (mounted) setState(() => _checking = false);
          return;
        }
      }
    } catch (_) {
      // A stale local session must not prevent the user from signing in again.
    }

    if (!mounted) return;
    setState(() => _checking = false);
    await _openDialog();
  }

  Future<void> _openDialog() async {
    if (_openingDialog || _attempted || !mounted) return;
    _attempted = true;
    setState(() {
      _openingDialog = true;
      _error = null;
    });

    try {
      final refreshToken = await ExcelAuthBridge.openSignInDialog();
      if (refreshToken.isEmpty) {
        throw StateError('InsightFlow did not return a session to Excel.');
      }

      // Supabase refresh tokens are rotated. The host consumes the one-time
      // handoff token and stores its own independently refreshed session.
      await InsightFlowSupabaseAuthService.client.auth.setSession(refreshToken);
      final user = await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
        timeout: const Duration(seconds: 8),
      );
      if (user == null || user.emailConfirmedAt == null) {
        throw StateError('The InsightFlow account could not be verified.');
      }
      // AuthGate observes the new Supabase session and opens the workspace.
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error is StateError
            ? error.message
            : InsightFlowSupabaseAuthService.userFacingAuthError(error);
      });
    } finally {
      if (mounted) setState(() => _openingDialog = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking || _openingDialog) {
      return const _ExcelAuthStatus(
        title: 'Checking your InsightFlow sign-in…',
        detail: 'Your Excel session is being verified.',
        busy: true,
      );
    }

    return _ExcelAuthStatus(
      title: _error == null ? 'Sign in to InsightFlow' : 'Sign-in needs attention',
      detail: _error ??
          'A secure sign-in window will open. After you sign in, Excel will continue automatically.',
      actionLabel: 'Continue to sign in',
      onAction: () {
        _attempted = false;
        _openDialog();
      },
    );
  }
}

/// Sign-in page hosted inside Office's separate authentication dialog.
class ExcelAuthDialogGate extends StatefulWidget {
  const ExcelAuthDialogGate({super.key});

  @override
  State<ExcelAuthDialogGate> createState() => _ExcelAuthDialogGateState();
}

class _ExcelAuthDialogGateState extends State<ExcelAuthDialogGate> {
  StreamSubscription<AuthState>? _subscription;
  bool _handoffStarted = false;
  bool _completed = false;
  bool _needsVerification = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subscription =
        InsightFlowSupabaseAuthService.authStateChanges.listen((_) {
      _handoffAuthenticatedSession();
    }, onError: (_) {
      if (mounted) setState(() => _error = 'Sign-in could not be verified. Try again.');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handoffAuthenticatedSession();
    });
  }

  Future<void> _handoffAuthenticatedSession() async {
    if (_handoffStarted || _completed || !mounted) return;
    final session = InsightFlowSupabaseAuthService.currentSession;
    if (session == null || session.refreshToken.isEmpty) return;

    _handoffStarted = true;
    try {
      final user = await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
        timeout: const Duration(seconds: 8),
      );
      if (!mounted) return;
      if (user == null || user.emailConfirmedAt == null) {
        setState(() {
          _needsVerification = true;
          _handoffStarted = false;
        });
        return;
      }

      final rotatedSession = InsightFlowSupabaseAuthService.currentSession;
      final handoffToken = rotatedSession?.refreshToken ?? session.refreshToken;
      ExcelAuthBridge.completeDialog(handoffToken);
      if (mounted) setState(() => _completed = true);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'InsightFlow could not verify this sign-in. Please try again.';
        _handoffStarted = false;
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_completed) {
      return const _ExcelAuthStatus(
        title: 'You’re signed in',
        detail: 'Return to Excel. Your InsightFlow workspace will open automatically.',
        busy: true,
      );
    }
    if (_needsVerification || _error != null) {
      return _ExcelAuthStatus(
        title: _needsVerification ? 'Verify your email first' : 'Sign-in could not finish',
        detail: _error ??
            'Confirm your InsightFlow email address, then return here and sign in again.',
        actionLabel: 'Back to sign in',
        onAction: () => setState(() {
          _needsVerification = false;
          _error = null;
        }),
      );
    }
    return const SignInScreen();
  }
}

class _ExcelAuthStatus extends StatelessWidget {
  const _ExcelAuthStatus({
    required this.title,
    required this.detail,
    this.busy = false,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String detail;
  final bool busy;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050B18),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 38, color: Color(0xFF55D6E8)),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    detail,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF9BAAC1),
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                  if (busy) ...[
                    const SizedBox(height: 24),
                    const CircularProgressIndicator(color: Color(0xFF55D6E8)),
                  ],
                  if (actionLabel != null && onAction != null) ...[
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: onAction,
                      child: Text(actionLabel!),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
