import 'package:flutter/material.dart';

import '../../core/auth/insightflow_auth_service.dart';
import 'auth_glass_widgets.dart';

class SignUpScreen extends StatefulWidget {
  const SignUpScreen({super.key});

  @override
  State<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends State<SignUpScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _signUp() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (name.isEmpty || email.isEmpty || password.isEmpty || confirm.isEmpty) {
      setState(() => _error = 'Complete all fields to create your account.');
      return;
    }
    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final credential =
          await InsightFlowAuthService.createUserWithEmailAndPassword(
        email,
        password,
      );

      await credential.user?.updateDisplayName(name);
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

  @override
  Widget build(BuildContext context) {
    return AuthGlassScaffold(
      title: 'AUTH / CREATE ACCOUNT',
      subtitle: 'REGISTER CREDENTIALS // FIREBASE AUTH',
      children: [
        AuthGlassField(
          controller: _nameController,
          label: 'FULL NAME',
          icon: Icons.person_outline,
          enabled: !_loading,
          autofillHints: const [AutofillHints.name],
        ),
        const SizedBox(height: 8),
        AuthGlassField(
          controller: _emailController,
          label: 'EMAIL',
          icon: Icons.alternate_email,
          keyboardType: TextInputType.emailAddress,
          enabled: !_loading,
          autofillHints: const [AutofillHints.email],
        ),
        const SizedBox(height: 8),
        AuthGlassField(
          controller: _passwordController,
          label: 'PASSWORD',
          icon: Icons.lock_outline,
          obscureText: _obscurePassword,
          enabled: !_loading,
          autofillHints: const [AutofillHints.newPassword],
          suffix: IconButton(
            onPressed: _loading
                ? null
                : () => setState(() => _obscurePassword = !_obscurePassword),
            icon: Icon(
              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: TechColors.textMuted,
              size: 16,
            ),
          ),
        ),
        const SizedBox(height: 8),
        AuthGlassField(
          controller: _confirmController,
          label: 'CONFIRM PASSWORD',
          icon: Icons.lock_outline,
          obscureText: _obscureConfirm,
          enabled: !_loading,
          autofillHints: const [AutofillHints.newPassword],
          suffix: IconButton(
            onPressed: _loading
                ? null
                : () => setState(() => _obscureConfirm = !_obscureConfirm),
            icon: Icon(
              _obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: TechColors.textMuted,
              size: 16,
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _error!),
        ],
        const SizedBox(height: 14),
        AuthGlassPrimaryButton(
          label: 'CREATE ACCOUNT',
          loading: _loading,
          onPressed: _loading ? null : _signUp,
        ),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'ALREADY REGISTERED? ',
              style: TextStyle(
                color: TechColors.textMuted,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            AuthGlassLink(
              label: 'SIGN IN',
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ],
    );
  }
}
