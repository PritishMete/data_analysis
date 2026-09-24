import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/insightflow_auth_service.dart';
import 'auth_glass_widgets.dart';
import 'company_registration_screen.dart';
import 'google_web_sign_in_button.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
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

  Future<void> _signInWithGoogle() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await InsightFlowAuthService.signInWithGoogle();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = InsightFlowAuthService.userFacingAuthError(error);
      });
    }
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
      setState(
        () => _error = InsightFlowAuthService.userFacingAuthError(error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final passwordQuality =
        GlassThemeData.of(context).qualityFor(context) ?? GlassQuality.standard;

    return AuthGlassScaffold(
      title: 'Sign in',
      subtitle: 'Access your InsightFlow workspace securely.',
      children: [
        const AuthGlassFieldLabel('Email'),
        GlassTextField(
          controller: _emailController,
          placeholder: 'Email',
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          enabled: !_loading,
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Password'),
        GlassPasswordField(
          controller: _passwordController,
          placeholder: 'Password',
          textInputAction: TextInputAction.done,
          enabled: !_loading,
          quality: passwordQuality,
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _loading ? null : _resetPassword,
            style: TextButton.styleFrom(
              foregroundColor: TechColors.borderActive,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text(
              'Forgot password?',
              style: TextStyle(
                color: TechColors.borderActive,
                fontSize: 10,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          AuthGlassMessage(
            text: _error!,
            error: !_error!.startsWith('Password reset email sent'),
          ),
        ],
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: _loading ? () {} : _signIn,
          enabled: !_loading,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: _loading ? 'Please wait…' : 'Sign In',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_loading)
                const CupertinoActivityIndicator()
              else
                const Icon(CupertinoIcons.arrow_right, size: 17),
              const SizedBox(width: 8),
              Text(
                _loading ? 'Please wait…' : 'Sign In',
                style: TextStyle(
                  color: CupertinoColors.label.resolveFrom(context),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        GlassButton.custom(
          onTap: _loading
              ? () {}
              : () async {
                  setState(() {
                    _loading = true;
                    _error = null;
                  });
                  try {
                    await InsightFlowAuthService.signInWithMicrosoft();
                  } catch (error) {
                    if (!mounted) return;
                    setState(() {
                      _loading = false;
                      _error =
                          InsightFlowAuthService.userFacingAuthError(error);
                    });
                  }
                },
          enabled: !_loading,
          width: double.infinity,
          height: 42,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Continue with Microsoft',
          child: const Text(
            'Continue with Microsoft',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 8),
        if (kIsWeb)
          GoogleWebSignInButton(
            enabled: !_loading,
            onStarted: () {
              if (mounted) setState(() { _loading = true; _error = null; });
            },
            onAuthenticated: (account) async {
              try {
                await InsightFlowAuthService.signInWithGoogleAccount(account);
              } catch (error) {
                if (!mounted) return;
                setState(() { _loading = false; _error = InsightFlowAuthService.userFacingAuthError(error); });
              }
            },
            onError: (error) {
              if (!mounted) return;
              setState(() { _loading = false; _error = InsightFlowAuthService.userFacingAuthError(error); });
            },
          )
        else
          GlassButton.custom(
            onTap: _loading ? () {} : _signInWithGoogle,
            enabled: !_loading,
            width: double.infinity,
            height: 42,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'Continue with Google',
            child: const Text(
              'Continue with Google',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
          ),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 10),
        const Text(
          'Use email and password for existing accounts.',
          textAlign: TextAlign.center,
          style: TextStyle(color: TechColors.textMuted, fontSize: 9),
        ),
        const SizedBox(height: 8),
        Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Text(
              'New organization? ',
              style: TextStyle(color: TechColors.textMuted, fontSize: 10),
            ),
            TextButton(
              onPressed: _loading
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const CompanyRegistrationScreen(),
                      ),
                    ),
              style: TextButton.styleFrom(
                foregroundColor: TechColors.borderActive,
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Register Company',
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
