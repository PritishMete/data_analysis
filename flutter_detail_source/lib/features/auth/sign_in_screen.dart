import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'auth_glass_widgets.dart';

class SignInScreen extends StatefulWidget {
  const SignInScreen({super.key});

  @override
  State<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends State<SignInScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _loading = false;
  bool _rememberDevice = true;
  bool _emailVerificationRequired = false;
  bool _messageIsError = true;
  bool _showCreateAccount = false;
  bool _transitioning = false;
  int _transitionSequence = 0;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _switchMode(bool createAccount) async {
    if (_loading || _showCreateAccount == createAccount) return;
    FocusManager.instance.primaryFocus?.unfocus();
    final sequence = ++_transitionSequence;
    setState(() {
      _transitioning = true;
      _showCreateAccount = createAccount;
      _emailVerificationRequired = false;
      _error = null;
      _messageIsError = true;
    });

    // Keep the transient blur and translucent wash only for the card morph.
    await Future<void>.delayed(const Duration(milliseconds: 480));
    if (!mounted || sequence != _transitionSequence) return;
    setState(() => _transitioning = false);
  }

  Future<void> _signIn() async {
    if (_loading || _showCreateAccount) return;
    final email = _emailController.text.trim();
    final password = _passwordController.text;

    if (email.isEmpty || password.isEmpty) {
      setState(() {
        _error = 'Enter your email and password.';
        _messageIsError = true;
      });
      return;
    }

    setState(() {
      _loading = true;
      _emailVerificationRequired = false;
      _messageIsError = true;
      _error = null;
    });

    try {
      await InsightFlowSupabaseAuthService.setRememberDevice(email, _rememberDevice);
      await InsightFlowSupabaseAuthService.signInWithPassword(
        email: email,
        password: password,
      );
      if (!_rememberDevice) {
        InsightFlowSupabaseAuthService.markSessionOnlyLogin(email);
      }
    } catch (error) {
      if (!mounted) return;
      final unverified =
          InsightFlowSupabaseAuthService.isEmailVerificationError(error);
      setState(() {
        _loading = false;
        _emailVerificationRequired = unverified;
        _messageIsError = !unverified;
        _error = unverified
            ? 'Email not verified. Please verify your email first. Check your inbox and spam/junk folder for the verification email.'
            : InsightFlowSupabaseAuthService.userFacingAuthError(error);
      });
      return;
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _signUp() async {
    if (_loading || !_showCreateAccount) return;
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (name.isEmpty || email.isEmpty || password.isEmpty || confirm.isEmpty) {
      setState(() {
        _error = 'Complete all fields to create your account.';
        _messageIsError = true;
      });
      return;
    }
    if (password.length < 6) {
      setState(() {
        _error = 'Password must be at least 6 characters.';
        _messageIsError = true;
      });
      return;
    }
    if (password != confirm) {
      setState(() {
        _error = 'Passwords do not match.';
        _messageIsError = true;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _messageIsError = false;
    });
    try {
      await InsightFlowSupabaseAuthService.signUp(
        email: email,
        password: password,
        displayName: name,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _messageIsError = true;
        _error = InsightFlowSupabaseAuthService.userFacingAuthError(error);
      });
      return;
    }

    if (mounted) {
      setState(() {
        _loading = false;
        _messageIsError = false;
        _error =
            'Account created. Check your email for the Supabase confirmation link, then return to InsightFlow and sign in.';
      });
    }
  }

  Future<void> _resetPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty) {
      setState(() {
        _error = 'Enter your email first to reset your password.';
        _messageIsError = true;
      });
      return;
    }

    try {
      await InsightFlowSupabaseAuthService.resetPassword(email);
      if (!mounted) return;
      setState(() {
        _error = 'Password reset email sent. Check your inbox.';
        _messageIsError = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = InsightFlowSupabaseAuthService.userFacingAuthError(error);
        _messageIsError = true;
      });
    }
  }

  Future<void> _resendVerificationEmail() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) return;

    setState(() => _loading = true);
    try {
      await InsightFlowSupabaseAuthService.resendSignupVerification(email);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _emailVerificationRequired = true;
        _messageIsError = false;
        _error =
            'Verification email sent again. Check your inbox and spam/junk folder.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _messageIsError = true;
        _error = InsightFlowSupabaseAuthService.userFacingAuthError(error);
      });
    }
  }

  Widget _submitButton({
    required String label,
    required bool busy,
    required VoidCallback onTap,
    required IconData icon,
  }) {
    return GlassButton.custom(
      onTap: busy ? () {} : onTap,
      enabled: !busy,
      width: double.infinity,
      height: 46,
      shape: const LiquidRoundedSuperellipse(borderRadius: 14),
      label: busy ? 'Please wait' : label,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const CupertinoActivityIndicator()
          else
            Icon(icon, size: 17, color: TechColors.borderActive),
          const SizedBox(width: 9),
          Text(
            busy ? 'Please wait…' : label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _modeSwitch({
    required String prompt,
    required String action,
    required bool createAccount,
  }) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          prompt,
          style: const TextStyle(color: TechColors.textMuted, fontSize: 10),
        ),
        TextButton(
          onPressed: _loading || _transitioning
              ? null
              : () => _switchMode(createAccount),
          style: TextButton.styleFrom(
            foregroundColor: TechColors.borderActive,
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            minimumSize: const Size(0, 32),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(
            action,
            style: const TextStyle(
              color: TechColors.borderActive,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  Widget _signInForm(GlassQuality quality) {
    return Column(
      key: const ValueKey<String>('sign-in-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AuthGlassFieldLabel('Email'),
        GlassTextField(
          controller: _emailController,
          placeholder: 'Email',
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          enabled: !_loading && !_transitioning,
          settings: kAuthFieldGlass,
          useOwnLayer: true,
          shape: kAuthFieldShape,
          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Password'),
        GlassPasswordField(
          controller: _passwordController,
          placeholder: 'Password',
          textInputAction: TextInputAction.done,
          enabled: !_loading && !_transitioning,
          quality: quality,
          settings: kAuthFieldGlass,
          useOwnLayer: true,
          shape: kAuthFieldShape,
          onSubmitted: (_) => _signIn(),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            CupertinoCheckbox(
              value: _rememberDevice,
              onChanged: _loading || _transitioning
                  ? null
                  : (value) => setState(() => _rememberDevice = value ?? true),
              activeColor: TechColors.borderActive,
              checkColor: CupertinoColors.black,
            ),
            const Text(
              'Remember this device',
              style: TextStyle(color: TechColors.textMuted, fontSize: 10),
            ),
          ],
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: _loading || _transitioning ? null : _resetPassword,
            style: TextButton.styleFrom(
              foregroundColor: TechColors.borderActive,
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
              minimumSize: const Size(0, 32),
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
          AuthGlassMessage(text: _error!, error: _messageIsError),
        ],
        if (_emailVerificationRequired) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: _loading ? null : _resendVerificationEmail,
            child: const Text('Send verification email again'),
          ),
        ],
        const SizedBox(height: 14),
        _submitButton(
          label: 'Sign In',
          busy: _loading,
          onTap: _signIn,
          icon: CupertinoIcons.arrow_right,
        ),
        const SizedBox(height: 10),
        const Divider(height: 1),
        const SizedBox(height: 8),
        _modeSwitch(
          prompt: 'New to InsightFlow? ',
          action: 'Create account',
          createAccount: true,
        ),
      ],
    );
  }

  Widget _signUpForm(GlassQuality quality) {
    return Column(
      key: const ValueKey<String>('sign-up-form'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AuthGlassFieldLabel('Full name'),
        GlassTextField(
          controller: _nameController,
          placeholder: 'Full name',
          textInputAction: TextInputAction.next,
          enabled: !_loading && !_transitioning,
          settings: kAuthFieldGlass,
          useOwnLayer: true,
          shape: kAuthFieldShape,
          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Email'),
        GlassTextField(
          controller: _emailController,
          placeholder: 'Email',
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
          enabled: !_loading && !_transitioning,
          settings: kAuthFieldGlass,
          useOwnLayer: true,
          shape: kAuthFieldShape,
          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Password'),
        GlassPasswordField(
          controller: _passwordController,
          placeholder: 'Password',
          textInputAction: TextInputAction.next,
          enabled: !_loading && !_transitioning,
          quality: quality,
          settings: kAuthFieldGlass,
          useOwnLayer: true,
          shape: kAuthFieldShape,
          onSubmitted: (_) => FocusScope.of(context).nextFocus(),
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Confirm password'),
        GlassPasswordField(
          controller: _confirmController,
          placeholder: 'Confirm password',
          textInputAction: TextInputAction.done,
          enabled: !_loading && !_transitioning,
          quality: quality,
          settings: kAuthFieldGlass,
          useOwnLayer: true,
          shape: kAuthFieldShape,
          onSubmitted: (_) => _signUp(),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _error!, error: _messageIsError),
        ],
        const SizedBox(height: 14),
        _submitButton(
          label: 'Create Account',
          busy: _loading,
          onTap: _signUp,
          icon: CupertinoIcons.person_add,
        ),
        const SizedBox(height: 10),
        _modeSwitch(
          prompt: 'Already have an account? ',
          action: 'Sign in',
          createAccount: false,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final quality =
        GlassThemeData.of(context).qualityFor(context) ?? GlassQuality.standard;
    return AuthGlassScaffold(
      title: _showCreateAccount ? 'Create account' : 'Sign in',
      subtitle: _showCreateAccount
          ? 'Set up your InsightFlow workspace access.'
          : 'Access your InsightFlow workspace securely.',
      brandedLayout: true,
      children: [
        AnimatedSize(
          duration: const Duration(milliseconds: 440),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          clipBehavior: Clip.hardEdge,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(
              color: _transitioning
                  ? Colors.white.withValues(alpha: 0.035)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _transitioning
                    ? TechColors.borderActive.withValues(alpha: 0.22)
                    : Colors.transparent,
              ),
            ),
            child: ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.blur(
                  sigmaX: _transitioning ? 5.5 : 0,
                  sigmaY: _transitioning ? 5.5 : 0,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 260),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      final offset = Tween<Offset>(
                        begin: const Offset(0, 0.025),
                        end: Offset.zero,
                      ).animate(animation);
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position: offset,
                          child: child,
                        ),
                      );
                    },
                    child: _showCreateAccount
                        ? _signUpForm(quality)
                        : _signInForm(quality),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
