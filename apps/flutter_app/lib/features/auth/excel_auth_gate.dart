import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/supabase_auth_service.dart';
import '../../core/auth/excel_auth_diagnostics.dart';
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

  @override
  void initState() {
    super.initState();
    ExcelAuthBridge.setDiagnosticsEnabled(ExcelAuthDiagnostics.buildSupported);
    ExcelAuthDiagnostics.activateSession(ExcelAuthBridge.diagnosticsActive);
    ExcelAuthDiagnostics.record('dialog_started');
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkSession());
  }

  Future<void> _checkSession() async {
    final hadPersistedSession =
        InsightFlowSupabaseAuthService.currentSession != null;
    var shouldClearPersistedSession = false;
    try {
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 5),
      );
      if (session != null) {
        final user =
            await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
              timeout: const Duration(seconds: 6),
            );
        if (user != null && user.emailConfirmedAt != null) {
          if (mounted) setState(() => _checking = false);
          return;
        }
      }
      shouldClearPersistedSession = hadPersistedSession;
    } catch (_) {
      // A stale local session must not prevent the user from signing in again.
      shouldClearPersistedSession = hadPersistedSession;
    }

    // Clear a rejected task-pane session before opening the Office dialog so
    // its refresh token cannot race the one-time handoff claim.
    if (shouldClearPersistedSession) {
      try {
        await InsightFlowSupabaseAuthService.signOut();
      } catch (_) {
        // The dialog can still attempt a fresh sign-in.
      }
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
      final correlationId =
          'excel-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      ExcelAuthDiagnostics.start(correlationId);
      ExcelAuthDiagnostics.record('task_pane_dialog_open_started');
      final refreshToken = await ExcelAuthBridge.openSignInDialog(
        correlationId,
      );
      ExcelAuthDiagnostics.record(
        'task_pane_dialog_message_received',
        result: 'validated',
      );
      if (refreshToken.isEmpty) {
        throw StateError('InsightFlow did not return a session to Excel.');
      }

      // Supabase refresh tokens are rotated. The host consumes the one-time
      // handoff token and stores its own independently refreshed session.
      ExcelAuthDiagnostics.record('task_pane_set_session', result: 'started');
      await InsightFlowSupabaseAuthService.client.auth.setSession(refreshToken);
      ExcelAuthDiagnostics.record('task_pane_set_session', result: 'succeeded');
      final user = await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
        timeout: const Duration(seconds: 8),
      );
      if (user == null || user.emailConfirmedAt == null) {
        throw StateError('The InsightFlow account could not be verified.');
      }
      ExcelAuthDiagnostics.record(
        'task_pane_session_verified',
        result: 'succeeded',
        sessionAvailable: true,
      );
      // AuthGate observes the new Supabase session and opens the workspace.
    } catch (error) {
      ExcelAuthDiagnostics.record(
        'task_pane_authentication',
        result: 'failed',
        errorCode: _safeErrorCode(error),
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
      detail:
          _error ??
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
  static int _nextCorrelationId = 0;

  String _correlationId() =>
      'excel-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}-${++_nextCorrelationId}';

  void _logHandoff(
    String correlationId,
    String operation,
    String result, [
    Object? error,
  ]) {
    final code = error is AuthException ? error.code : null;
    debugPrint(
      '[excel-auth-handoff] correlation=$correlationId operation=$operation '
      'result=$result error_code=${code ?? error?.runtimeType ?? 'none'}',
    );
    ExcelAuthDiagnostics.record(
      'dialog_$operation',
      result: result,
      errorCode: code ?? (error == null ? null : error.runtimeType.toString()),
      sessionAvailable: InsightFlowSupabaseAuthService.currentSession != null,
      completed: _completed,
      handoffStarted: _handoffStarted,
    );
  }

  @override
  void initState() {
    super.initState();
    ExcelAuthBridge.setDiagnosticsEnabled(ExcelAuthDiagnostics.buildSupported);
    ExcelAuthDiagnostics.activateSession(ExcelAuthBridge.diagnosticsActive);
    _subscription = InsightFlowSupabaseAuthService.authStateChanges.listen(
      (state) {
        if (state.event == AuthChangeEvent.signedIn ||
            state.event == AuthChangeEvent.initialSession) {
          ExcelAuthDiagnostics.record(
            'oauth_callback_detected',
            authEvent: state.event.name,
            sessionAvailable: state.session != null,
          );
        }
        ExcelAuthDiagnostics.record(
          'auth_state_event',
          authEvent: state.event.name,
          sessionAvailable: state.session != null,
        );
        _handoffAuthenticatedSession();
      },
      onError: (error, _) {
        ExcelAuthDiagnostics.record(
          'auth_state_stream_error',
          result: 'received',
          errorCode: _safeErrorCode(error),
          completed: _completed,
          handoffStarted: _handoffStarted,
        );
        if (mounted)
          setState(() => _error = 'Sign-in could not be verified. Try again.');
      },
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handoffAuthenticatedSession();
    });
  }

  Future<void> _handoffAuthenticatedSession() async {
    if (_handoffStarted || _completed || !mounted) {
      ExcelAuthDiagnostics.record(
        'duplicate_auth_callback',
        result: 'ignored',
        completed: _completed,
        handoffStarted: _handoffStarted,
      );
      return;
    }
    final session = InsightFlowSupabaseAuthService.currentSession;
    if (session == null) {
      ExcelAuthDiagnostics.record('session_missing', result: 'missing');
      return;
    }
    final refreshToken = session.refreshToken;
    if (refreshToken == null || refreshToken.isEmpty) return;

    _handoffStarted = true;
    final correlationId = ExcelAuthBridge.correlationId ?? _correlationId();
    ExcelAuthDiagnostics.start(correlationId);
    ExcelAuthDiagnostics.record(
      'session_available',
      sessionAvailable: true,
      handoffStarted: true,
    );
    try {
      ExcelAuthDiagnostics.record(
        'user_verification_started',
        sessionAvailable: true,
      );
      _logHandoff(correlationId, 'verify_session', 'started');
      final user =
          await InsightFlowSupabaseAuthService.refreshAuthenticatedUser(
            timeout: const Duration(seconds: 8),
          );
      _logHandoff(
        correlationId,
        'verify_session',
        user == null ? 'missing' : 'succeeded',
      );
      ExcelAuthDiagnostics.record(
        user == null ? 'user_verification_failed' : 'user_verification_succeeded',
        result: user == null ? 'failed' : 'succeeded',
        sessionAvailable: user != null,
      );
      if (!mounted) return;
      if (user == null || user.emailConfirmedAt == null) {
        setState(() {
          _needsVerification = true;
          _handoffStarted = false;
        });
        ExcelAuthDiagnostics.record('email_verification_failed', result: 'failed');
        return;
      }

      // Refresh before handoff so a token left behind by a previously closed
      // dialog cannot be replayed into the task pane.
      final handoffToken =
          InsightFlowSupabaseAuthService.currentSession?.refreshToken;
      if (handoffToken == null || handoffToken.isEmpty) {
        throw StateError('InsightFlow did not return a refresh token.');
      }
      _logHandoff(correlationId, 'complete_dialog', 'started');
      ExcelAuthDiagnostics.record('handoff_started', result: 'started');
      ExcelAuthBridge.completeDialog(handoffToken);
      _logHandoff(correlationId, 'complete_dialog', 'succeeded');
      ExcelAuthDiagnostics.record('handoff_succeeded', result: 'succeeded');
      if (mounted) setState(() => _completed = true);
      ExcelAuthDiagnostics.record(
        'dialog_completed',
        result: 'state_set',
        completed: true,
        handoffStarted: _handoffStarted,
      );
    } catch (error) {
      _logHandoff(correlationId, 'handoff', 'failed', error);
      if (!mounted) return;
      setState(() {
        _error = 'InsightFlow could not verify this sign-in. Please try again.';
        _handoffStarted = false;
      });
      ExcelAuthDiagnostics.record(
        'dialog_handoff_error',
        result: 'displayed',
        errorCode: _safeErrorCode(error),
        completed: _completed,
        handoffStarted: _handoffStarted,
      );
      ExcelAuthDiagnostics.record('handoff_failed', result: 'failed');
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
        detail:
            'Return to Excel. Your InsightFlow workspace will open automatically.',
        busy: true,
        messageIsError: false,
      );
    }
    if (_needsVerification || _error != null) {
      return _ExcelAuthStatus(
        title: _needsVerification
            ? 'Verify your email first'
            : 'Sign-in could not finish',
        detail:
            _error ??
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

String _safeErrorCode(Object error) {
  if (error is AuthException) return error.code ?? error.runtimeType.toString();
  if (error is StateError) return 'state_error';
  if (error is TimeoutException) return 'timeout';
  return error.runtimeType.toString();
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
            child: FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ),
        ],
        if (ExcelAuthDiagnostics.isEnabled) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => ExcelAuthDiagnostics.copyDiagnosticsToClipboard(),
            child: const Text('Copy diagnostic report'),
          ),
        ],
      ],
    );
  }
}
