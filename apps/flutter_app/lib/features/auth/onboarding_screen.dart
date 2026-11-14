import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';

/// Frontend-only onboarding presentation for the two InsightFlow entry paths.
/// The invited member's role is informational and is never user-selectable.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.onBack,
  });

  final VoidCallback onBack;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  static const _panel = LiquidGlassSettings(
    thickness: 24,
    blur: 14,
    chromaticAberration: 0.12,
    lightIntensity: 0.45,
    refractiveIndex: 1.2,
    saturation: 1.1,
    glassColor: Color(0x1A123A8C),
  );
  static const _field = LiquidGlassSettings(
    thickness: 10,
    blur: 4,
    glassColor: Color(0x14FFFFFF),
    refractiveIndex: 1.04,
  );

  String? _flow;
  int _step = 0;
  bool _showPassword = false;
  bool _complete = false;

  final _name = TextEditingController();
  final _organization = TextEditingController();
  final _branch = TextEditingController();
  final _email = TextEditingController();
  final _inviteCode = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _organization.dispose();
    _branch.dispose();
    _email.dispose();
    _inviteCode.dispose();
    _password.dispose();
    super.dispose();
  }

  void _continue() {
    FocusScope.of(context).unfocus();
    if (_complete) {
      widget.onBack();
      return;
    }
    if (_flow == null) return;
    if (_flow == 'branch-head' && _step == 0) {
      if (_name.text.trim().isEmpty ||
          _organization.text.trim().isEmpty ||
          _branch.text.trim().isEmpty ||
          _email.text.trim().isEmpty) {
        _message('Complete each required field to continue.');
        return;
      }
      setState(() => _step = 1);
      return;
    }
    if (_flow == 'invitee' &&
        (_name.text.trim().isEmpty ||
            _email.text.trim().isEmpty ||
            _inviteCode.text.trim().isEmpty ||
            _password.text.isEmpty)) {
      _message('Complete each required field to continue.');
      return;
    }
    setState(() => _complete = true);
  }

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF101012),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          const Positioned.fill(child: _OnboardingBackdrop()),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: GlassContainer(
                    useOwnLayer: true,
                    settings: _panel,
                    quality: GlassQuality.minimal,
                    shape: const LiquidRoundedSuperellipse(borderRadius: 28),
                    padding: const EdgeInsets.all(28),
                    child: _buildContent(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_complete) return _success();
    if (_flow == null) return _chooseFlow();
    if (_flow == 'branch-head') return _branchHeadFlow();
    return _inviteeFlow();
  }

  Widget _brandHeader({required String eyebrow, required String title, required String subtitle}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: TechColors.brandBlue.withValues(alpha: .65)),
                color: TechColors.brandDarkBlue.withValues(alpha: .25),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: TechColors.brandBlue),
            ),
            const SizedBox(width: 12),
            const Text(
              'InsightFlow',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 23, letterSpacing: .4),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _flow == null ? widget.onBack : () => setState(() { _flow = null; _step = 0; }),
              icon: const Icon(Icons.arrow_back_rounded, size: 16),
              label: const Text('Back'),
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
            ),
          ],
        ),
        const SizedBox(height: 28),
        Text(eyebrow.toUpperCase(), style: const TextStyle(color: TechColors.brandBlue, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.7)),
        const SizedBox(height: 8),
        Text(title, style: const TextStyle(color: Colors.white, fontSize: 28, height: 1.15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 13, height: 1.5)),
        const SizedBox(height: 22),
      ],
    );
  }

  Widget _chooseFlow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _brandHeader(
          eyebrow: 'Workspace onboarding',
          title: 'Let’s set up your access.',
          subtitle: 'Choose the path that matches how you received access to InsightFlow.',
        ),
        _flowCard(
          icon: Icons.domain_rounded,
          title: 'Create a branch workspace',
          subtitle: 'For the Branch Head setting up an organization and branch for the first time.',
          tag: 'BRANCH HEAD',
          onTap: () => setState(() { _flow = 'branch-head'; _step = 0; }),
        ),
        const SizedBox(height: 12),
        _flowCard(
          icon: Icons.mark_email_read_outlined,
          title: 'Accept an invitation',
          subtitle: 'For a team member invited by a Branch Head. Your designation is assigned in the invitation.',
          tag: 'INVITED MEMBER',
          onTap: () => setState(() { _flow = 'invitee'; _step = 0; }),
        ),
        const SizedBox(height: 22),
        const _SecurityNote(text: 'Access and role assignment are managed by your organization. You cannot assign yourself a team role.'),
      ],
    );
  }

  Widget _flowCard({required IconData icon, required String title, required String subtitle, required String tag, required VoidCallback onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: .035),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: TechColors.brandBlue.withValues(alpha: .35)),
          ),
          child: Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(color: TechColors.brandBlue.withValues(alpha: .14), borderRadius: BorderRadius.circular(14)),
                child: Icon(icon, color: TechColors.brandBlue, size: 25),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(tag, style: const TextStyle(color: TechColors.brandBlue, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
                const SizedBox(height: 5),
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 5),
                Text(subtitle, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.45)),
              ])),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white54, size: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _branchHeadFlow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _brandHeader(
          eyebrow: 'Branch Head • Step ${_step + 1} of 2',
          title: _step == 0 ? 'Build your workspace.' : 'Review your setup.',
          subtitle: _step == 0
              ? 'Start with your details, then define the organization and branch you manage.'
              : 'Confirm the workspace information before continuing.',
        ),
        _progress(),
        if (_step == 0) ...[
          _sectionLabel('YOUR PROFILE'),
          const SizedBox(height: 10),
          _input(_name, 'Full name', Icons.person_outline_rounded),
          const SizedBox(height: 12),
          _input(_email, 'Work email address', Icons.mail_outline_rounded, keyboard: TextInputType.emailAddress),
          const SizedBox(height: 22),
          _sectionLabel('YOUR WORKSPACE'),
          const SizedBox(height: 10),
          _input(_organization, 'Organization name', Icons.apartment_rounded),
          const SizedBox(height: 12),
          _input(_branch, 'Branch / office name', Icons.location_city_rounded),
          const SizedBox(height: 20),
          const _SecurityNote(text: 'Branch Heads administer their branch and invite team members. Other roles are assigned by the Branch Head.'),
        ] else ...[
          _summaryRow(Icons.person_outline_rounded, 'Branch Head', _name.text.trim()),
          _summaryRow(Icons.mail_outline_rounded, 'Email', _email.text.trim()),
          _summaryRow(Icons.apartment_rounded, 'Organization', _organization.text.trim()),
          _summaryRow(Icons.location_city_rounded, 'Branch', _branch.text.trim()),
          const SizedBox(height: 14),
          const _SecurityNote(text: 'This is a UI preview. Account creation and workspace provisioning are not connected by this frontend-only change.'),
        ],
        const SizedBox(height: 24),
        _primaryAction(_step == 0 ? 'Continue to review' : 'Finish setup'),
      ],
    );
  }

  Widget _inviteeFlow() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _brandHeader(
          eyebrow: 'Invitation • Team member setup',
          title: 'Your team is waiting.',
          subtitle: 'Use the details from your invitation to complete your profile. Your role is assigned by your Branch Head.',
        ),
        _progress(),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: TechColors.brandDarkBlue.withValues(alpha: .22),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: TechColors.brandBlue.withValues(alpha: .45)),
          ),
          child: Row(children: [
            const Icon(Icons.verified_user_outlined, color: TechColors.brandBlue, size: 26),
            const SizedBox(width: 12),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('ASSIGNED DESIGNATION', style: TextStyle(color: TechColors.brandBlue, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w800)),
              SizedBox(height: 5),
              Text('Assigned by your Branch Head', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 15)),
              SizedBox(height: 4),
              Text('This field is locked and cannot be changed here.', style: TextStyle(color: Colors.white60, fontSize: 12)),
            ])),
            const Icon(Icons.lock_outline_rounded, color: Colors.white54, size: 18),
          ]),
        ),
        const SizedBox(height: 20),
        _sectionLabel('INVITATION DETAILS'),
        const SizedBox(height: 10),
        _input(_email, 'Invited email address', Icons.mail_outline_rounded, keyboard: TextInputType.emailAddress),
        const SizedBox(height: 12),
        _input(_inviteCode, 'Invitation code', Icons.key_rounded),
        const SizedBox(height: 22),
        _sectionLabel('COMPLETE YOUR PROFILE'),
        const SizedBox(height: 10),
        _input(_name, 'Full name', Icons.person_outline_rounded),
        const SizedBox(height: 12),
        _input(_password, 'Create password', Icons.lock_outline_rounded, obscure: !_showPassword, suffix: IconButton(
          onPressed: () => setState(() => _showPassword = !_showPassword),
          icon: Icon(_showPassword ? Icons.visibility_off_outlined : Icons.visibility_outlined, color: Colors.white54, size: 19),
        )),
        const SizedBox(height: 20),
        const _SecurityNote(text: 'The invitation must provide your role. This screen does not offer a role selector or change your assigned permissions.'),
        const SizedBox(height: 24),
        _primaryAction('Complete profile'),
      ],
    );
  }

  Widget _success() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Center(child: Container(
          width: 72, height: 72,
          decoration: BoxDecoration(shape: BoxShape.circle, color: TechColors.statusGreen.withValues(alpha: .12), border: Border.all(color: TechColors.statusGreen.withValues(alpha: .55))),
          child: const Icon(Icons.check_rounded, color: TechColors.statusGreen, size: 38),
        )),
        const SizedBox(height: 22),
        const Text('You’re ready for the next step.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        const Text('The onboarding UI is complete. Authentication, invitation validation, and workspace creation still need to be handled by the existing auth/backend flow.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white60, fontSize: 13, height: 1.5)),
        const SizedBox(height: 24),
        _primaryAction('Return to sign in'),
      ],
    );
  }

  Widget _progress() {
    final current = _flow == 'branch-head' ? _step + 1 : 1;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Row(children: [
        Expanded(child: Container(height: 4, decoration: BoxDecoration(color: TechColors.brandBlue, borderRadius: BorderRadius.circular(4)))),
        const SizedBox(width: 6),
        Expanded(child: Container(height: 4, decoration: BoxDecoration(color: current > 1 ? TechColors.brandBlue : Colors.white12, borderRadius: BorderRadius.circular(4)))),
      ]),
    );
  }

  Widget _input(TextEditingController controller, String hint, IconData icon, {TextInputType keyboard = TextInputType.text, bool obscure = false, Widget? suffix}) {
    return GlassContainer(
      useOwnLayer: true,
      settings: _field,
      quality: GlassQuality.minimal,
      shape: const LiquidRoundedSuperellipse(borderRadius: 12),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        obscureText: obscure,
        style: const TextStyle(color: Colors.white, fontSize: 14),
        cursorColor: Colors.white70,
        decoration: InputDecoration(
          icon: Icon(icon, color: Colors.white54, size: 19),
          hintText: hint,
          hintStyle: const TextStyle(color: Colors.white54, fontSize: 13),
          suffixIcon: suffix,
          border: InputBorder.none,
        ),
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(text, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 1.3));

  Widget _summaryRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(children: [
        Icon(icon, color: TechColors.brandBlue, size: 19),
        const SizedBox(width: 12),
        SizedBox(width: 105, child: Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12))),
        Expanded(child: Text(value, style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600))),
      ]),
    );
  }

  Widget _primaryAction(String label) {
    return SizedBox(
      height: 50,
      child: GlassButton.custom(
        onTap: _continue,
        enabled: true,
        shape: const LiquidRoundedSuperellipse(borderRadius: 28),
        interactionScale: 1.015,
        stretch: 0,
        anchorStretch: false,
        glowColor: TechColors.brandBlue.withValues(alpha: .35),
        child: Text(label, style: const TextStyle(color: Colors.black, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: .2)),
      ),
    );
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: .035),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: .08)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.shield_outlined, color: TechColors.brandBlue, size: 18),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: const TextStyle(color: Colors.white60, fontSize: 12, height: 1.45))),
    ]),
  );
}

class _OnboardingBackdrop extends StatelessWidget {
  const _OnboardingBackdrop();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      gradient: RadialGradient(
        center: Alignment(-.7, -.8),
        radius: 1.5,
        colors: [Color(0xFF101B36), Color(0xFF08090D), Colors.black],
      ),
    ),
  );
}
