import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';

/// Shared InsightFlow authentication shell.
///
/// This is intentionally a presentation/auth-flow layer: the submit callbacks
/// are exposed so the real authentication service can be connected without
/// changing the visual system.
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
      _showMessage('Enter your email and password.');
      return;
    }

    if (isSignup &&
        passwordController.text != confirmPasswordController.text) {
      _showMessage('Passwords do not match.');
      return;
    }

    // Keep the UI flow usable until the production auth endpoint is wired.
    // Replace this block with the real auth service call.
    setState(() => isSubmitting = true);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    setState(() => isSubmitting = false);
    widget.onAuthenticated();
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: TechColors.panelBg,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final officeHost = isRunningInsideOffice;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            Positioned.fill(
              child: GlassBackgroundSource(
                child: const TechAnimatedBackground(),
              ),
            ),
            Positioned.fill(
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 28),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 430),
                      child: _buildAuthPanel(officeHost),
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

  Widget _buildAuthPanel(bool officeHost) {
    return GlassContainer(
      useOwnLayer: true,
      quality: officeHost ? GlassQuality.minimal : GlassQuality.standard,
      settings: TechColors.panelGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          _buildSystemLabel(),
          const SizedBox(height: 8),
          Text(
            isSignup ? 'CREATE ACCOUNT' : 'SIGN IN',
            style: const TextStyle(
              color: TechColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
              letterSpacing: .4,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            isSignup
                ? 'Create your InsightFlow workspace.'
                : 'Access your InsightFlow workspace securely.',
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 11,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 22),
          _buildField(
            controller: emailController,
            label: 'EMAIL',
            hint: 'name@company.com',
            icon: Icons.mail_outline_rounded,
          ),
          const SizedBox(height: 12),
          _buildField(
            controller: passwordController,
            label: 'PASSWORD',
            hint: 'Enter password',
            icon: Icons.lock_outline_rounded,
            obscureText: obscurePassword,
            suffix: _visibilityButton(
              obscurePassword,
              () => setState(() => obscurePassword = !obscurePassword),
            ),
          ),
          if (isSignup) ...[
            const SizedBox(height: 12),
            _buildField(
              controller: confirmPasswordController,
              label: 'CONFIRM PASSWORD',
              hint: 'Repeat password',
              icon: Icons.lock_outline_rounded,
              obscureText: obscureConfirmPassword,
              suffix: _visibilityButton(
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
                onPressed: () => _showMessage(
                  'Password reset will be connected to the auth service.',
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'FORGOT PASSWORD?',
                  style: TextStyle(
                    color: TechColors.borderActive,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .45,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          _buildPrimaryButton(),
          const SizedBox(height: 18),
          _buildModeSwitch(),
          const SizedBox(height: 18),
          const Center(
            child: Text(
              'INSIGHTFLOW // SECURE WORKSPACE',
              style: TextStyle(
                color: TechColors.textMuted,
                fontSize: 8,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.25,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: TechColors.borderActive.withValues(alpha: .07),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: TechColors.borderActive.withValues(alpha: .42),
            ),
          ),
          child: const Icon(
            Icons.terminal_rounded,
            color: TechColors.borderActive,
            size: 17,
          ),
        ),
        const SizedBox(width: 10),
        const Text(
          'InsightFlow',
          style: TextStyle(
            color: TechColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
        ),
        const Spacer(),
        _buildStatusChip(),
      ],
    );
  }

  Widget _buildStatusChip() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: TechColors.statusGreen.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: TechColors.statusGreen.withValues(alpha: .24),
        ),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.circle,
            color: TechColors.statusGreen,
            size: 5,
          ),
          SizedBox(width: 5),
          Text(
            'ONLINE',
            style: TextStyle(
              color: TechColors.statusGreen,
              fontSize: 8,
              fontWeight: FontWeight.w700,
              letterSpacing: .5,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSystemLabel() {
    return const Row(
      children: [
        Expanded(
          child: Divider(
            color: TechColors.borderMuted,
            height: 1,
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 9),
          child: Text(
            'SYSTEM ACCESS',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 8,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Expanded(
          child: Divider(
            color: TechColors.borderMuted,
            height: 1,
          ),
        ),
      ],
    );
  }

  Widget _buildField({
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
            fontWeight: FontWeight.w700,
            letterSpacing: .95,
          ),
        ),
        const SizedBox(height: 5),
        GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: TechColors.fieldGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 11),
          child: TextField(
            controller: controller,
            obscureText: obscureText,
            textInputAction: TextInputAction.next,
            style: const TextStyle(
              color: TechColors.textPrimary,
              fontSize: 12,
            ),
            cursorColor: TechColors.borderActive,
            decoration: InputDecoration(
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 13,
              ),
              prefixIcon: Icon(
                icon,
                color: TechColors.textMuted,
                size: 16,
              ),
              suffixIcon: suffix,
              hintText: hint,
              hintStyle: const TextStyle(
                color: TechColors.textMuted,
                fontSize: 11,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _visibilityButton(bool hidden, VoidCallback onPressed) {
    return IconButton(
      onPressed: onPressed,
      splashRadius: 18,
      icon: Icon(
        hidden
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
        color: TechColors.textMuted,
        size: 17,
      ),
    );
  }

  Widget _buildPrimaryButton() {
    return SizedBox(
      width: double.infinity,
      height: 46,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: TechColors.borderActive.withValues(alpha: .72),
          ),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              TechColors.borderActive.withValues(alpha: .20),
              TechColors.statusBlue.withValues(alpha: .12),
            ],
          ),
        ),
        child: TextButton(
          onPressed: isSubmitting ? null : _submit,
          style: TextButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: isSubmitting
              ? const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: TechColors.borderActive,
                  ),
                )
              : Text(
                  isSignup ? 'CREATE ACCOUNT' : 'SIGN IN',
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildModeSwitch() {
    return Center(
      child: Wrap(
        alignment: WrapAlignment.center,
        children: [
          Text(
            isSignup
                ? 'Already have an account? '
                : 'New to InsightFlow? ',
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 10,
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => isSignup = !isSignup),
            child: Text(
              isSignup ? 'SIGN IN' : 'CREATE ACCOUNT',
              style: const TextStyle(
                color: TechColors.borderActive,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
