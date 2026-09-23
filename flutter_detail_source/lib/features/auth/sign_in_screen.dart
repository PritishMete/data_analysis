import 'package:flutter/material.dart';

import '../../core/auth/insightflow_auth_service.dart';
import '../../app_colors.dart';
import 'auth_glass_widgets.dart';
import 'sign_up_screen.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your email and password.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await InsightFlowAuthService.signInWithEmailAndPassword(email, password);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = InsightFlowAuthService.userFacingAuthError(error);
      });
      return;
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email first to reset your password.');
      return;
    }

    try {
      await InsightFlowAuthService.sendPasswordResetEmail(email);
      if (!mounted) return;
      setState(() {
        _error = 'Password reset email sent. Check your inbox.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = InsightFlowAuthService.userFacingAuthError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: 'Sign in',
      subtitle: 'Access your InsightFlow workspace securely.',
      children: [
        AuthGlassField(
          controller: _emailController,
          label: 'Email',
          icon: Icons.alternate_email,
          keyboardType: TextInputType.emailAddress,
          enabled: !_loading,
          autofillHints: const [AutofillHints.username],
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 8),
        AuthGlassField(
          controller: _passwordController,
          label: 'Password',
          icon: Icons.lock_outline,
          obscureText: _obscurePassword,
          enabled: !_loading,
          autofillHints: const [AutofillHints.password],
          suffix: IconButton(
            tooltip: _obscurePassword ? 'Show password' : 'Hide password',
            onPressed: _loading
                ? null
                : () => setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: TechColors.textMuted,
              size: 16,
            ),
          ),
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: AuthGlassLink(
            label: 'Forgot password?',
            onPressed: _loading ? null : _resetPassword,
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(
            text: _error!,
            error: !_error!.startsWith('Password reset email sent'),
          ),
        ],
        const SizedBox(height: 14),
        AuthGlassPrimaryButton(
          label: 'Sign In',
          loading: _loading,
          onPressed: _loading ? null : _signIn,
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'New to InsightFlow? ',
              style: TextStyle(
                color: TechColors.textMuted,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            AuthGlassLink(
              label: 'Create account',
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const SignUpScreen(),
                        ),
                      ),
            ),
          ],
        ),
      ],
    );
  }
}
