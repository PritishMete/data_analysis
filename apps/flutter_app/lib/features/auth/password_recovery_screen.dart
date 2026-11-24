import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/auth/supabase_auth_service.dart';
import '../../widgets/input/glass_password_field.dart';
import 'auth_glass_widgets.dart';

/// Password reset completion is available only while Supabase has delivered
/// its PASSWORD_RECOVERY event. The caller cannot enter this screen by
/// supplying an arbitrary user ID or an application-side recovery flag.
class SupabasePasswordRecoveryScreen extends StatefulWidget {
  const SupabasePasswordRecoveryScreen({super.key});

  @override
  State<SupabasePasswordRecoveryScreen> createState() =>
      _SupabasePasswordRecoveryScreenState();
}

class _SupabasePasswordRecoveryScreenState
    extends State<SupabasePasswordRecoveryScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _busy = false;
  bool _completed = false;
  String? _message;

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _updatePassword() async {
    if (_busy || _completed) return;
    final password = _passwordController.text;
    if (password.length < 8) {
      setState(() => _message = 'Choose a password with at least 8 characters.');
      return;
    }
    if (password != _confirmController.text) {
      setState(() => _message = 'The passwords do not match.');
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      // The recovery session was issued by Supabase Auth after the single-use
      // email recovery link was verified. Never ask for or proxy the old
      // password through InsightFlow.
      await InsightFlowSupabaseAuthService.setPassword(password);
      if (!mounted) return;
      _passwordController.clear();
      _confirmController.clear();
      setState(() {
        _completed = true;
        _message = 'Your password has been updated. Sign in using the new password.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _message = 'The password could not be updated. Request a new recovery email and try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _returnToSignIn() async {
    InsightFlowSupabaseAuthService.clearPasswordRecoveryPending();
    try {
      await InsightFlowSupabaseAuthService.signOutCurrentDevice();
    } catch (_) {
      // Local session cleanup is best effort after the password change. The
      // recovery flag is already cleared and Supabase remains authoritative.
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: _completed ? 'PASSWORD UPDATED' : 'RESET PASSWORD',
      subtitle: _completed
          ? 'Your InsightFlow account is ready for a fresh sign-in.'
          : 'Choose a new password for your InsightFlow account.',
      brandedLayout: true,
      children: [
        if (!_completed) ...[
          const AuthGlassFieldLabel('NEW PASSWORD'),
          const SizedBox(height: 6),
          GlassPasswordField(
            controller: _passwordController,
            placeholder: 'New password',
            enabled: !_busy,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          const AuthGlassFieldLabel('CONFIRM NEW PASSWORD'),
          const SizedBox(height: 6),
          GlassPasswordField(
            controller: _confirmController,
            placeholder: 'Confirm new password',
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _updatePassword(),
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 12),
          AuthGlassMessage(text: _message!, error: !_completed),
        ],
        const SizedBox(height: 16),
        GlassButton.custom(
          onTap: _busy
              ? () {}
              : (_completed ? _returnToSignIn : _updatePassword),
          enabled: !_busy,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: _busy
              ? 'Updating…'
              : (_completed ? 'Return to sign in' : 'Update password'),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (_busy) const CupertinoActivityIndicator(),
              if (_busy) const SizedBox(width: 8),
              Text(
                _busy
                    ? 'Updating…'
                    : (_completed ? 'Return to sign in' : 'Update password'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
