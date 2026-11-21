import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/supabase_auth_service.dart';
import '../../core/diagnostics/auth_diagnostics.dart';
import '../../core/interop/excel_auth_bridge.dart';
import 'auth_glass_widgets.dart';
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
  String _correlationId = AuthDiagnostics.newCorrelationId();

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
    _correlationId = AuthDiagnostics.newCorrelationId();
    setState(() {
      _openingDialog = true;
      _error = null;
    });

    try {
      final refreshToken = await ExcelAuthBridge.openSignInDialog();
      AuthDiagnostics.event(
        'excel_dialog_message_received',
        correlationId: _correlationId,
        success: refreshToken.isNotEmpty,
        category: refreshToken.isEmpty ? 'empty_session_message' : 'session_message',
      );
      if (refreshToken.isEmpty) {
        throw StateError('InsightFlow did not return a session to Excel.');
      }

      // Supabase refresh tokens are rotated. The host consumes the one-time
      // handoff token and stores its own independently refreshed session.
      try {
        await InsightFlowSupabaseAuthService.client.auth.setSession(refreshToken);
      } catch (error) {
        AuthDiagnostics.event(
          'excel_set_session',
          correlationId: _correlationId,
          success: false,
          exceptionClass: error.runtimeType.toString(),
          category: 'session_establishment_failure',
        );
        rethrow;
      }
      AuthDiagnostics.event(
        'excel_set_session',
        correlationId: _correlationId,
        success: true,
      );
      late final User? user;
      try {
        user = await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
          timeout: const Duration(seconds: 8),
        );
      } catch (error) {
        AuthDiagnostics.event(
          'excel_fetch_authoritative_user',
          correlationId: _correlationId,
          success: false,
          exceptionClass: error.runtimeType.toString(),
          category: 'authoritative_user_failure',
        );
        rethrow;
      }
      if (user == null || user.emailConfirmedAt == null) {
        throw StateError('The InsightFlow account could not be verified.');
      }
      AuthDiagnostics.event(
        'excel_fetch_authoritative_user',
        correlationId: _correlationId,
        success: true,
      );
      // AuthGate observes the new Supabase session and opens the workspace.
    } catch (error) {
      AuthDiagnostics.event(
        'excel_parent_handoff',
        correlationId: _correlationId,
        success: false,
        exceptionClass: error.runtimeType.toString(),
        category: 'handoff_failure',
      );
      if (!mounted) return;
      setState(() {
        _error = error is StateError
            ? error.message.toString()
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
        messageIsError: false,
      );
    }

    return _ExcelAuthStatus(
      title: 'Sign in to InsightFlow',
      detail: _error ??
          'A secure sign-in window will open. After you sign in, Excel will continue automatically.',
      messageIsError: _error != null,
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
  final String _correlationId = AuthDiagnostics.newCorrelationId();

  @override
  void initState() {
    super.initState();
    _subscription =
        InsightFlowSupabaseAuthService.authStateChanges.listen((_) {
      AuthDiagnostics.event(
        'excel_oauth_callback_session_available',
        correlationId: _correlationId,
        success: InsightFlowSupabaseAuthService.currentSession != null,
      );
      _handoffAuthenticatedSession();
    }, onError: (_) {
      AuthDiagnostics.event(
        'excel_oauth_callback',
        correlationId: _correlationId,
        success: false,
        category: 'auth_state_stream_error',
      );
      if (mounted) setState(() => _error = 'Sign-in could not be verified. Try again.');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handoffAuthenticatedSession();
    });
  }

  Future<void> _handoffAuthenticatedSession() async {
    if (_handoffStarted || _completed || !mounted) return;
    final session = InsightFlowSupabaseAuthService.currentSession;
    if (session == null) return;
    final refreshToken = session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return;

    _handoffStarted = true;
    try {
      late final User? user;
      try {
        user = await InsightFlowSupabaseAuthService.refreshAuthenticatedUser(
          timeout: const Duration(seconds: 8),
        );
      } catch (error) {
        AuthDiagnostics.event(
          'excel_refresh_authenticated_user',
          correlationId: _correlationId,
          success: false,
          exceptionClass: error.runtimeType.toString(),
          category: 'session_refresh_failure',
        );
        rethrow;
      }
      AuthDiagnostics.event(
        'excel_refresh_authenticated_user',
        correlationId: _correlationId,
        success: user != null,
      );
      if (!mounted) return;
      if (user == null || user.emailConfirmedAt == null) {
        setState(() {
          _needsVerification = true;
          _handoffStarted = false;
        });
        return;
      }

      // Refresh before handoff so a token left behind by a previously closed
      // dialog cannot be replayed into the task pane.
      final handoffToken =
          InsightFlowSupabaseAuthService.currentSession?.refreshToken;
      AuthDiagnostics.event(
        'excel_rotated_refresh_token_available',
        correlationId: _correlationId,
        success: handoffToken?.isNotEmpty == true,
      );
      if (handoffToken == null || handoffToken.isEmpty) {
        throw StateError('InsightFlow did not return a refresh token.');
      }
      ExcelAuthBridge.completeDialog(handoffToken);
      AuthDiagnostics.event(
        'excel_dialog_complete',
        correlationId: _correlationId,
        success: true,
      );
      if (mounted) setState(() => _completed = true);
    } catch (error) {
      AuthDiagnostics.event(
        'excel_dialog_complete',
        correlationId: _correlationId,
        success: false,
        exceptionClass: error.runtimeType.toString(),
        category: 'handoff_failure',
      );
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
        messageIsError: false,
      );
    }
    if (_needsVerification || _error != null) {
      return _ExcelAuthStatus(
        title: _needsVerification ? 'Verify your email first' : 'Sign-in could not finish',
        detail: _error ??
            'Confirm your InsightFlow email address, then return here and sign in again.',
        messageIsError: _error != null,
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
    this.messageIsError = true,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String detail;
  final bool busy;
  final bool messageIsError;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: title,
      subtitle: 'Sign in to continue to InsightFlow.',
      children: [
        AuthGlassMessage(text: detail, error: messageIsError),
        if (busy) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator()),
        ],
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: onAction,
              child: Text(actionLabel!),
            ),
          ),
        ],
      ],
    );
  }
}
