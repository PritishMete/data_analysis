import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/interop/office_host.dart';

/// InsightFlow authentication surface styled from the Lockr liquid-glass
/// authentication flow. Authentication behavior is intentionally unchanged.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.onAuthenticated,
  });

  final VoidCallback onAuthenticated;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool isSignup = false;
  bool obscurePassword = true;
  bool obscureConfirmPassword = true;
  bool isSubmitting = false;

  final emailController = TextEditingController();
  final passwordController = TextEditingController();
  final confirmPasswordController = TextEditingController();

  static const _panelGlass = LiquidGlassSettings(
    thickness: 28,
    blur: 16,
    chromaticAberration: 0.15,
    lightIntensity: 0.55,
    refractiveIndex: 1.35,
    saturation: 1.15,
    glassColor: Color(0x1FFFFFFF),
  );

  static const _fieldGlass = LiquidGlassSettings(
    thickness: 10,
    blur: 4,
    glassColor: Color(0x14FFFFFF),
    refractiveIndex: 1.05,
  );

  static const _panelShape =
      LiquidRoundedSuperellipse(borderRadius: 28);
  static const _fieldShape =
      LiquidRoundedSuperellipse(borderRadius: 10);
  static const _pillShape =
      LiquidRoundedSuperellipse(borderRadius: 28);

  static const _accent = TechColors.brandBlue;
  static const _accentDim = TechColors.brandDarkBlue;
  static const _textSecondary = Color(0x99FFFFFF);
  static const _textTertiary = Color(0x66FFFFFF);

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (emailController.text.trim().isEmpty ||
        passwordController.text.isEmpty) {
      _message('Enter your email and password.');
      return;
    }

    if (isSignup &&
        passwordController.text != confirmPasswordController.text) {
      _message('Passwords do not match.');
      return;
    }

    setState(() => isSubmitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    setState(() => isSubmitting = false);
    widget.onAuthenticated();
  }

  void _message(String value) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF101012),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final quality =
        isRunningInsideOffice ? GlassQuality.minimal : GlassQuality.standard;

    return Scaffold(
      backgroundColor: Colors.black,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            const Positioned.fill(
              child: GlassBackgroundSource(
                child: _AuthLiquidBackground(),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 32,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: GlassContainer(
                        useOwnLayer: true,
                        settings: _panelGlass,
                        quality: quality,
                        shape: _panelShape,
                        padding: const EdgeInsets.all(32),
                        child: _buildPanel(quality),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPanel(GlassQuality quality) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: _accent.withValues(alpha: 0.5),
              width: 1.4,
            ),
          ),
          alignment: Alignment.center,
          child: const Icon(
            Icons.auto_awesome_rounded,
            size: 44,
            color: _accent,
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'InsightFlow',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          isSignup
              ? 'Create your workspace and start analyzing.'
              : 'Your data analysis workspace, secured.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: _textSecondary,
            fontSize: 13,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 36),
        _field(
          controller: emailController,
          hint: 'Enter your email id',
          icon: Icons.mail_outline_rounded,
        ),
        const SizedBox(height: 12),
        _field(
          controller: passwordController,
          hint: 'Enter password',
          icon: Icons.lock_outline_rounded,
          obscureText: obscurePassword,
          suffixIcon: _visibility(
            obscurePassword,
            () => setState(
              () => obscurePassword = !obscurePassword,
            ),
          ),
        ),
        if (isSignup) ...[
          const SizedBox(height: 12),
          _field(
            controller: confirmPasswordController,
            hint: 'Confirm password',
            icon: Icons.verified_user_outlined,
            obscureText: obscureConfirmPassword,
            suffixIcon: _visibility(
              obscureConfirmPassword,
              () => setState(
                () => obscureConfirmPassword = !obscureConfirmPassword,
              ),
            ),
          ),
        ],
        if (!isSignup) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => _message(
                'Password reset will be connected to the auth service.',
              ),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text(
                'Forgot password?',
                style: TextStyle(
                  color: _accent,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 20),
        _primaryButton(),
        const SizedBox(height: 12),
        _secondaryButton(),
        const SizedBox(height: 24),
        Center(
          child: GestureDetector(
            onTap: () {
              setState(() {
                isSignup = !isSignup;
                passwordController.clear();
                confirmPasswordController.clear();
              });
            },
            child: RichText(
              text: TextSpan(
                text: isSignup
                    ? 'Already have an account? '
                    : 'New here? ',
                style: const TextStyle(
                  color: _textTertiary,
                  fontSize: 12,
                ),
                children: [
                  TextSpan(
                    text: isSignup ? 'Sign in' : 'Create account',
                    style: const TextStyle(
                      color: _accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Text(
          isSignup
              ? 'Create an account to access your InsightFlow workspace.'
              : 'Your workspace stays behind your account credentials.',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 11,
            color: _textTertiary,
            height: 1.35,
          ),
        ),
      ],
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    Widget? suffixIcon,
  }) {
    return GlassContainer(
      useOwnLayer: true,
      shape: _fieldShape,
      settings: _fieldGlass,
      quality: GlassQuality.standard,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: hint.contains('email')
            ? TextInputType.emailAddress
            : TextInputType.text,
        textInputAction: TextInputAction.next,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 14,
        ),
        cursorColor: Colors.white70,
        decoration: InputDecoration(
          icon: Icon(icon, color: Colors.white54, size: 18),
          hintText: hint,
          hintStyle: const TextStyle(
            color: Colors.white54,
            fontSize: 13,
          ),
          filled: false,
          suffixIcon: suffixIcon,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 0,
            vertical: 14,
          ),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
        ),
      ),
    );
  }

  Widget _visibility(bool hidden, VoidCallback onPressed) {
    return GlassIconButton(
      icon: Icon(
        hidden
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
        color: Colors.white54,
        size: 16,
      ),
      size: 32,
      onPressed: onPressed,
    );
  }

  Widget _primaryButton() {
    final label = isSignup ? 'Create account' : 'Sign in';
    final active = !isSubmitting;

    return SizedBox(
      width: double.infinity,
      height: 50,
      child: GlassButton.custom(
        onTap: active ? _submit : () {},
        enabled: active,
        shape: _pillShape,
        interactionScale: 1.02,
        stretch: 0.0,
        anchorStretch: false,
        glowColor: _accent.withValues(alpha: 0.35),
        child: isSubmitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation(Colors.black87),
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
      ),
    );
  }

  Widget _secondaryButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: GlassButton.custom(
        onTap: () => setState(() => isSignup = !isSignup),
        enabled: true,
        shape: _pillShape,
        interactionScale: 1.02,
        stretch: 0.0,
        anchorStretch: false,
        glowColor: Colors.white.withValues(alpha: 0.20),
        child: Text(
          isSignup ? 'Back to sign in' : 'Create an account',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

/// The Lockr authentication background recipe: black base + slow drifting
/// dark-blue, blue and graphite radial light blobs, sampled by the glass renderer.
class _AuthLiquidBackground extends StatefulWidget {
  const _AuthLiquidBackground();

  @override
  State<_AuthLiquidBackground> createState() => _AuthLiquidBackgroundState();
}

class _AuthLiquidBackgroundState extends State<_AuthLiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        GlassAccessibilityData.of(context).reduceMotion;

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF060607),
            Color(0xFF0B0B0E),
            Color(0xFF000000),
          ],
        ),
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = reduceMotion
              ? 0.0
              : _controller.value * 2 * math.pi;
          return CustomPaint(
            painter: _AuthBlobPainter(t),
            size: Size.infinite,
          );
        },
      ),
    );
  }
}

class _AuthBlobPainter extends CustomPainter {
  const _AuthBlobPainter(this.t);

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    const blobs = [
      (TechColors.brandDarkBlue, 0.50),
      (TechColors.brandBlue, 0.42),
      (TechColors.brandGraphite, 0.38),
    ];

    final positions = [
      Offset(
        size.width * (0.25 + 0.08 * math.sin(t)),
        size.height * (0.25 + 0.06 * math.cos(t)),
      ),
      Offset(
        size.width * (0.80 + 0.06 * math.cos(t * 1.3)),
        size.height * (0.70 + 0.08 * math.sin(t * 1.1)),
      ),
      Offset(
        size.width * (0.50 + 0.10 * math.sin(t * 0.7 + 2.0)),
        size.height * (0.85 + 0.05 * math.cos(t * 0.9)),
      ),
    ];

    for (var i = 0; i < blobs.length; i++) {
      final (color, radiusFactor) = blobs[i];
      final radius = size.shortestSide * radiusFactor;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: 0.20),
            color.withValues(alpha: 0.00),
          ],
        ).createShader(
          Rect.fromCircle(center: positions[i], radius: radius),
        )
        ..blendMode = BlendMode.plus;

      canvas.drawCircle(positions[i], radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _AuthBlobPainter old) => old.t != t;
}
