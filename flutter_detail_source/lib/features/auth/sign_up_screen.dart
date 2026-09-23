import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
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
    final passwordQuality =
        GlassThemeData.of(context).qualityFor(context) ?? GlassQuality.standard;

    return AuthGlassScaffold(
      title: 'Create account',
      subtitle: 'Set up your InsightFlow workspace access.',
      children: [
        const AuthGlassFieldLabel('Full name'),
        GlassTextField(
          controller: _nameController,
          placeholder: 'Full name',
          textInputAction: TextInputAction.next,
          enabled: !_loading,
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Email'),
        GlassTextField(
          controller: _emailController,
          placeholder: 'Email',
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          enabled: !_loading,
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Password'),
        GlassPasswordField(
          controller: _passwordController,
          placeholder: 'Password',
          textInputAction: TextInputAction.next,
          enabled: !_loading,
          quality: passwordQuality,
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Confirm password'),
        GlassPasswordField(
          controller: _confirmController,
          placeholder: 'Confirm password',
          textInputAction: TextInputAction.done,
          enabled: !_loading,
          quality: passwordQuality,
          onSubmitted: (_) => _signUp(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _error!),
        ],
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: _loading ? () {} : _signUp,
          enabled: !_loading,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: _loading ? 'Please wait…' : 'Create Account',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_loading)
                const CupertinoActivityIndicator()
              else
                const Icon(CupertinoIcons.arrow_right, size: 17),
              const SizedBox(width: 8),
              Text(
                _loading ? 'Please wait…' : 'Create Account',
                style: TextStyle(
                  color: CupertinoColors.label.resolveFrom(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'Already have an account? ',
              style: TextStyle(color: TechColors.textMuted, fontSize: 10),
            ),
            TextButton(
              onPressed: _loading ? null : () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: TechColors.borderActive,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Sign in',
                style: TextStyle(
                  color: TechColors.borderActive,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
