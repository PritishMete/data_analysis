import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/interop/office_host.dart';

/// Authentication screen using the same visual shell as the Excel pipeline UI.
/// No HTML/CSS authentication surface is used here.
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
        backgroundColor: TechColors.panelBg,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final quality =
        isRunningInsideOffice ? GlassQuality.minimal : GlassQuality.standard;

    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            const Positioned.fill(
              child: GlassBackgroundSource(
                child: TechAnimatedBackground(),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    _buildGlassAppBar(quality),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(10, 12, 10, 28),
                        child: _buildBody(quality),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGlassAppBar(GlassQuality quality) {
    return GlassContainer(
      useOwnLayer: true,
      quality: quality,
      settings: TechColors.panelGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 0),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Row(
        children: [
          const Icon(
            Icons.terminal_rounded,
            color: TechColors.borderActive,
            size: 18,
          ),
          const SizedBox(width: 10),
          const Text(
            'InsightFlow',
            style: TextStyle(
              color: TechColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: TechColors.statusGreen.withValues(alpha: .25),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, color: TechColors.statusGreen, size: 5),
                SizedBox(width: 5),
                Text(
                  'SECURE',
                  style: TextStyle(
                    color: TechColors.statusGreen,
                    fontSize: 7,
                    fontWeight: FontWeight.bold,
                    letterSpacing: .7,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(GlassQuality quality) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 2),
        const Center(
          child: Text(
            'SYSTEM ACCESS',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 8,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
              fontFamily: 'monospace',
            ),
          ),
        ),
        const SizedBox(height: 10),
        _buildAuthCard(quality),
      ],
    );
  }

  Widget _buildAuthCard(GlassQuality quality) {
    return GlassContainer(
      useOwnLayer: true,
      quality: quality,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 4),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: TechColors.borderActive.withValues(alpha: .08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: TechColors.borderActive.withValues(alpha: .32),
                  ),
                ),
                child: const Icon(
                  Icons.lock_open_rounded,
                  color: TechColors.borderActive,
                  size: 17,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isSignup ? 'CREATE ACCOUNT' : 'SIGN IN',
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    letterSpacing: .2,
                  ),
                ),
              ),
              Text(
                isSignup ? '01 / 02' : '01 / 01',
                style: const TextStyle(
                  color: TechColors.textMuted,
                  fontSize: 8,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 7),
          Text(
            isSignup
                ? 'Initialize your InsightFlow workspace.'
                : 'Access your InsightFlow workspace securely.',
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 10,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          _field(
            controller: emailController,
            label: 'EMAIL',
            hint: 'name@company.com',
            icon: Icons.mail_outline_rounded,
          ),
          const SizedBox(height: 11),
          _field(
            controller: passwordController,
            label: 'PASSWORD',
            hint: 'Enter password',
            icon: Icons.lock_outline_rounded,
            obscureText: obscurePassword,
            suffix: _visibility(
              obscurePassword,
              () => setState(
                () => obscurePassword = !obscurePassword,
              ),
            ),
          ),
          if (isSignup) ...[
            const SizedBox(height: 11),
            _field(
              controller: confirmPasswordController,
              label: 'CONFIRM PASSWORD',
              hint: 'Repeat password',
              icon: Icons.lock_outline_rounded,
              obscureText: obscureConfirmPassword,
              suffix: _visibility(
                obscureConfirmPassword,
                () => setState(
                  () => obscureConfirmPassword = !obscureConfirmPassword,
                ),
              ),
            ),
          ],
          if (!isSignup) ...[
            const SizedBox(height: 4),
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
                  'FORGOT PASSWORD?',
                  style: TextStyle(
                    color: TechColors.borderActive,
                    fontSize: 8,
                    fontWeight: FontWeight.bold,
                    letterSpacing: .5,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          _primaryButton(),
          const SizedBox(height: 16),
          Center(
            child: Wrap(
              alignment: WrapAlignment.center,
              children: [
                Text(
                  isSignup
                      ? 'Already have an account? '
                      : 'New to InsightFlow? ',
                  style: const TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 9,
                  ),
                ),
                GestureDetector(
                  onTap: () => setState(() => isSignup = !isSignup),
                  child: Text(
                    isSignup ? 'SIGN IN' : 'CREATE ACCOUNT',
                    style: const TextStyle(
                      color: TechColors.borderActive,
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 8,
            fontWeight: FontWeight.bold,
            letterSpacing: .9,
          ),
        ),
        const SizedBox(height: 5),
        GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: TechColors.fieldGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 4),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            style: const TextStyle(
              color: TechColors.textPrimary,
              fontSize: 11,
            ),
            cursorColor: TechColors.borderActive,
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 12,
              ),
              prefixIcon: Icon(icon, color: TechColors.textMuted, size: 15),
              suffixIcon: suffix,
              hintText: hint,
              hintStyle: const TextStyle(
                color: TechColors.textMuted,
                fontSize: 10,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _visibility(bool hidden, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
      icon: Icon(
        hidden
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
        color: TechColors.textMuted,
        size: 15,
      ),
    );
  }

  Widget _primaryButton() {
    return SizedBox(
      height: 42,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: TechColors.borderActive.withValues(alpha: .65),
          ),
          gradient: LinearGradient(
            colors: [
              TechColors.borderActive.withValues(alpha: .16),
              TechColors.statusBlue.withValues(alpha: .11),
            ],
          ),
        ),
        child: TextButton(
          onPressed: isSubmitting ? null : _submit,
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          child: isSubmitting
              ? const SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: TechColors.borderActive,
                  ),
                )
              : Text(
                  isSignup ? 'CREATE ACCOUNT' : 'SIGN IN',
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    letterSpacing: .8,
                  ),
                ),
        ),
      ),
    );
  }
}
