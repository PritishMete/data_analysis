import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'auth_glass_widgets.dart';
import 'management_shell.dart';

class CompanyRegistrationScreen extends StatefulWidget {
  const CompanyRegistrationScreen({super.key});

  @override
  State<CompanyRegistrationScreen> createState() =>
      _CompanyRegistrationScreenState();
}

class _CompanyRegistrationScreenState
    extends State<CompanyRegistrationScreen> {
  final _organizationController = TextEditingController();
  final _branchController = TextEditingController();
  final _branchIdentifierController = TextEditingController();
  final _fullNameController = TextEditingController();
  final _employeeIdController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressLine1Controller = TextEditingController();
  final _addressLine2Controller = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _postalCodeController = TextEditingController();
  final _countryController = TextEditingController();
  final _idProofTypeController = TextEditingController();
  final _idProofNumberController = TextEditingController();
  final _emailOtpController = TextEditingController();
  final _phoneOtpController = TextEditingController();

  int _step = 0;
  bool _busy = false;
  bool _emailOtpSent = false;
  bool _emailOtpVerified = false;
  bool _phoneOtpSent = false;
  bool _phoneVerified = false;
  String? _emailOtpIdentity;
  String? _phoneOtpIdentity;
  String? _message;
  bool _error = false;
  OrganizationServiceDiagnostic? _organizationDiagnostic;

  @override
  void initState() {
    super.initState();
    _prefillAuthenticatedIdentity();
  }

  void _prefillAuthenticatedIdentity() {
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final suggestedName = (metadata['full_name'] ??
            metadata['name'] ??
            metadata['display_name'] ??
            '')
        .toString()
        .trim();
    if (_fullNameController.text.isEmpty && suggestedName.isNotEmpty) {
      _fullNameController.text = suggestedName;
    }
  }

  @override
  void dispose() {
    for (final controller in [
      _organizationController,
      _branchController,
      _branchIdentifierController,
      _fullNameController,
      _employeeIdController,
      _phoneController,
      _addressLine1Controller,
      _addressLine2Controller,
      _cityController,
      _stateController,
      _postalCodeController,
      _countryController,
      _idProofTypeController,
      _idProofNumberController,
      _emailOtpController,
      _phoneOtpController,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  String _normalizePhone(String value) {
    final normalized = value.trim().replaceAll(RegExp(r'[\s\-().]'), '');
    if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(normalized)) {
      throw StateError(
        'Enter a valid phone number in E.164 format, for example +919876543210.',
      );
    }
    return normalized;
  }

  String _maskIdProof(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.length <= 4) return compact;
    return ('X' * (compact.length - 4)) +
        compact.substring(compact.length - 4);
  }

  String get _authenticatedEmail =>
      InsightFlowSupabaseAuthService.currentSupabaseUser?.email?.trim() ?? '';

  bool get _authoritativeEmailVerified =>
      InsightFlowSupabaseAuthService.currentSupabaseUser?.emailConfirmedAt !=
      null;

  bool get _emailStepComplete =>
      _authoritativeEmailVerified || _emailOtpVerified;

  bool get _phoneStepComplete => _phoneVerified;

  void _setError(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = true;
      _message = message;
    });
  }

  Future<void> _sendEmailOtp() async {
    if (_authenticatedEmail.isEmpty) {
      _setError('The authenticated Supabase account has no email address.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
      if (user == null) {
        throw StateError('Your authenticated session could not be restored.');
      }
      _emailOtpIdentity = user.id;
      await InsightFlowSupabaseAuthService.sendEmailOtp(_authenticatedEmail);
      if (!mounted) return;
      setState(() {
        _emailOtpSent = true;
        _busy = false;
        _message = 'Email OTP sent to ' +
            _authenticatedEmail +
            '. Enter the code to verify this authenticated identity.';
      });
    } on AuthException catch (error) {
      _setError(
        error.message.toLowerCase().contains('disabled')
            ? 'Email OTP is not enabled for this Supabase project.'
            : 'Email OTP could not be sent. Please try again.',
      );
    } catch (_) {
      _setError('Email OTP could not be sent. Please try again.');
    }
  }

  Future<void> _verifyEmailOtp() async {
    final token = _emailOtpController.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      _setError('Enter the 6-digit email OTP.');
      return;
    }
    final identity = _emailOtpIdentity;
    if (identity == null) {
      _setError('Send a fresh email OTP before verifying it.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final response = await InsightFlowSupabaseAuthService.verifyEmailOtp(
        email: _authenticatedEmail,
        token: token,
      );
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 8),
      );
      if (session == null) {
        throw StateError(
          'The authenticated session could not be restored after email OTP verification.',
        );
      }
      final current =
          await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
      if (current == null || current.id != identity) {
        throw StateError('Email OTP verification returned a different account.');
      }
      if (response.user != null && response.user!.id != identity) {
        throw StateError('Email OTP verification returned a different account.');
      }
      if (current.emailConfirmedAt == null) {
        throw StateError(
          'Supabase did not confirm the authenticated email after the OTP.',
        );
      }
      if (!mounted) return;
      setState(() {
        _emailOtpVerified = true;
        _emailOtpSent = false;
        _busy = false;
        _message = 'EMAIL OTP VERIFIED';
        _error = false;
      });
    } on AuthException catch (_) {
      _setError('The email OTP is invalid or expired. Request a new code.');
    } catch (error) {
      _setError(
        error is StateError
            ? error.message
            : 'Email OTP verification failed.',
      );
    }
  }

  Future<void> _startPhoneOtp() async {
    late final String normalized;
    try {
      normalized = _normalizePhone(_phoneController.text);
    } catch (error) {
      _setError(error.toString().replaceFirst('Bad state: ', ''));
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final current =
          await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
      if (current == null) {
        throw StateError('Your authenticated session could not be restored.');
      }
      if (current.phone == normalized && current.phoneConfirmedAt != null) {
        if (!mounted) return;
        setState(() {
          _phoneVerified = true;
          _phoneOtpSent = false;
          _phoneOtpIdentity = normalized;
          _busy = false;
          _message = 'PHONE VERIFIED • SUPABASE AUTH';
          _error = false;
        });
        return;
      }

      await InsightFlowSupabaseAuthService.beginPhoneVerification(normalized);
      _phoneOtpIdentity = normalized;
      if (!mounted) return;
      setState(() {
        _phoneOtpSent = true;
        _phoneVerified = false;
        _busy = false;
        _message = 'Phone verification OTP sent to ' +
            normalized +
            '. Enter the 6-digit SMS code.';
        _error = false;
      });
    } on AuthException catch (error) {
      final lower = error.message.toLowerCase();
      _setError(
        lower.contains('provider') ||
                lower.contains('sms') ||
                lower.contains('phone')
            ? 'Phone OTP could not be started. Make sure Supabase Phone Auth and its SMS provider are configured.'
            : 'Phone verification could not be started.',
      );
    } catch (error) {
      _setError(
        error is StateError
            ? error.message
            : 'Phone verification could not be started. Configure the Supabase SMS provider before continuing.',
      );
    }
  }

  Future<void> _resendPhoneOtp() async {
    final phone = _phoneOtpIdentity;
    if (phone == null || phone.isEmpty) {
      _setError('Start phone verification before requesting another OTP.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      await InsightFlowSupabaseAuthService.resendPhoneChangeOtp(phone);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _message = 'A new phone OTP was sent.';
      });
    } on AuthException catch (_) {
      _setError(
        'Phone OTP could not be resent. Check the Supabase SMS provider configuration and rate limits.',
      );
    } catch (_) {
      _setError('Phone OTP could not be resent. Please try again.');
    }
  }

  Future<void> _verifyPhoneOtp() async {
    final phone = _phoneOtpIdentity;
    final token = _phoneOtpController.text.trim();
    if (phone == null || phone.isEmpty) {
      _setError('Start phone verification before verifying the OTP.');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      _setError('Enter the 6-digit phone OTP.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });
    try {
      final before = InsightFlowSupabaseAuthService.currentSupabaseUser;
      if (before == null) {
        throw StateError('Your authenticated session could not be restored.');
      }
      final response =
          await InsightFlowSupabaseAuthService.verifyPhoneChangeOtp(
        phone: phone,
        token: token,
      );
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 8),
      );
      if (session == null) {
        throw StateError(
          'The authenticated session could not be restored after phone OTP verification.',
        );
      }
      final current =
          await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
      if (current == null || current.id != before.id) {
        throw StateError('Phone OTP verification returned a different account.');
      }
      if (response.user != null && response.user!.id != before.id) {
        throw StateError('Phone OTP verification returned a different account.');
      }
      if (current.phone != phone || current.phoneConfirmedAt == null) {
        throw StateError(
          'Supabase did not confirm this phone number for the authenticated account.',
        );
      }
      if (!mounted) return;
      setState(() {
        _phoneVerified = true;
        _phoneOtpSent = false;
        _busy = false;
        _message = 'PHONE OTP VERIFIED';
        _error = false;
      });
    } on AuthException catch (_) {
      _setError('The phone OTP is invalid or expired. Request a new code.');
    } catch (error) {
      _setError(
        error is StateError ? error.message : 'Phone OTP verification failed.',
      );
    }
  }

  bool _validateStep(int step) {
    if (step == 0) {
      if (_organizationController.text.trim().isEmpty ||
          _branchController.text.trim().isEmpty ||
          _branchIdentifierController.text.trim().isEmpty) {
        _setError(
          'Enter the company name, branch name, and unique branch identifier.',
        );
        return false;
      }
      return true;
    }
    if (step == 1) {
      final required = <String>[
        _fullNameController.text,
        _employeeIdController.text,
        _phoneController.text,
        _addressLine1Controller.text,
        _cityController.text,
        _stateController.text,
        _postalCodeController.text,
        _countryController.text,
        _idProofTypeController.text,
        _idProofNumberController.text,
      ];
      if (required.any((value) => value.trim().isEmpty)) {
        _setError('Complete every required Branch Head profile field.');
        return false;
      }
      try {
        _normalizePhone(_phoneController.text);
      } catch (error) {
        _setError(error.toString().replaceFirst('Bad state: ', ''));
        return false;
      }
      return true;
    }
    if (step == 2 && !_emailStepComplete) {
      _setError('Complete the email verification step before continuing.');
      return false;
    }
    if (step == 3 && !_phoneStepComplete) {
      _setError('Complete phone OTP verification before continuing.');
      return false;
    }
    return true;
  }

  void _nextStep() {
    if (!_validateStep(_step)) return;
    setState(() {
      _message = null;
      _error = false;
      _step = (_step + 1).clamp(0, 4);
    });
  }

  void _previousStep() {
    if (_step == 0) return;
    setState(() {
      _step -= 1;
      _message = null;
      _error = false;
    });
  }

  Future<void> _register() async {
    for (var step = 0; step <= 3; step++) {
      if (!_validateStep(step)) return;
    }

    final session = await InsightFlowSupabaseAuthService.ensureSession(
      timeout: const Duration(seconds: 8),
    );
    final user = session == null
        ? null
        : InsightFlowSupabaseAuthService.currentSupabaseUser;
    if (session == null || user == null) {
      _setError(
        'Your Supabase sign-in session could not be restored. Please sign in again.',
      );
      return;
    }

    final authoritative =
        await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
    if (authoritative == null || authoritative.id != user.id) {
      _setError(
        'The authenticated Supabase identity could not be confirmed. Please sign in again.',
      );
      return;
    }
    if (authoritative.emailConfirmedAt == null) {
      _setError('EMAIL NOT VERIFIED. Verify the authenticated email first.');
      return;
    }

    final phone = _normalizePhone(_phoneController.text);
    if (authoritative.phone != phone ||
        authoritative.phoneConfirmedAt == null) {
      _setError(
        'PHONE NOT VERIFIED. Verify this exact phone number through Supabase OTP first.',
      );
      return;
    }

    setState(() {
      _busy = true;
      _message = null;
      _error = false;
    });

    try {
      final result = await organizationServiceRequest(
        method: 'POST',
        path: '/v1/authz/organizations/register',
        contentType: 'application/json',
        send: (headers) => http.post(
          Uri.parse(
            '$insightFlowBackendBaseUrl/v1/authz/organizations/register',
          ),
          headers: headers,
          body: jsonEncode({
            'organization_name': _organizationController.text.trim(),
            'branch_name': _branchController.text.trim(),
            'branch_identifier': _branchIdentifierController.text,
            'employee_id': _employeeIdController.text.trim(),
            'full_name': _fullNameController.text.trim(),
            'phone': phone,
            'address_line1': _addressLine1Controller.text.trim(),
            'address_line2': _addressLine2Controller.text.trim(),
            'city': _cityController.text.trim(),
            'state': _stateController.text.trim(),
            'postal_code': _postalCodeController.text.trim(),
            'country': _countryController.text.trim(),
            'id_proof_type': _idProofTypeController.text.trim(),
            'id_proof_number': _idProofNumberController.text.trim(),
          }),
        ),
      );
      _organizationDiagnostic = result.diagnostic;
      final response = result.response;
      final businessError =
          organizationServiceBusinessErrorMessage(response);
      if (businessError != null) _organizationDiagnostic = null;

      dynamic decoded;
      try {
        decoded = response.body.trim().isEmpty
            ? <String, dynamic>{}
            : jsonDecode(response.body);
      } catch (_) {
        decoded = null;
      }
      final detail =
          decoded is Map ? decoded['detail']?.toString().trim() : null;
      if (businessError != null) throw StateError(businessError);
      if (response.statusCode == 401) {
        throw StateError('InsightFlow authentication could not be verified.');
      }
      if (response.statusCode == 403) {
        throw StateError(
          detail?.isNotEmpty == true
              ? detail!
              : 'Your authenticated identity is not authorized to register an organization.',
        );
      }
      if (response.statusCode == 409) {
        throw StateError(
          detail?.isNotEmpty == true
              ? detail!
              : 'This organization registration conflicts with existing identity data.',
        );
      }
      if (response.statusCode == 422) {
        throw StateError(
          'Organization registration request was rejected by the server.',
        );
      }
      if (response.statusCode >= 500) {
        throw StateError(
          "InsightFlow's organization service returned a server error.",
        );
      }
      if (response.statusCode != 200) {
        throw StateError(
          detail?.isNotEmpty == true
              ? detail!
              : 'InsightFlow could not create the organization.',
        );
      }

      final workspaceId =
          decoded is Map ? decoded['workspace_id']?.toString() : null;
      final organizationId =
          decoded is Map ? decoded['organization_id']?.toString() : null;
      if (workspaceId == null ||
          workspaceId.isEmpty ||
          organizationId == null ||
          organizationId.isEmpty) {
        throw StateError(
          'InsightFlow could not create the organization. The server returned an incomplete response.',
        );
      }

      await setInsightFlowWorkspaceId(user.id, workspaceId);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ManagementShell()),
      );
    } on OrganizationServiceRequestException catch (error) {
      _organizationDiagnostic = error.diagnostic;
      _setError('InsightFlow couldn’t reach the organization service.');
    } catch (error) {
      _setError(
        error is StateError
            ? error.message
            : 'Company registration could not be completed.',
      );
    }
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? placeholder,
    TextInputType keyboardType = TextInputType.text,
    TextInputAction action = TextInputAction.next,
    int maxLines = 1,
    bool readOnly = false,
    String? helper,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthGlassFieldLabel(label),
        GlassTextField(
          controller: controller,
          placeholder: placeholder ?? label,
          enabled: !_busy,
          readOnly: readOnly,
          keyboardType: keyboardType,
          textInputAction: action,
          maxLines: maxLines,
        ),
        if (helper != null) ...[
          const SizedBox(height: 5),
          Text(
            helper,
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 9,
              height: 1.3,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ],
    );
  }

  Widget _stepIndicator() {
    const labels = [
      'COMPANY',
      'BRANCH HEAD',
      'EMAIL',
      'PHONE',
      'REVIEW',
    ];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(labels.length, (index) {
        final active = index == _step;
        final complete = index < _step;
        final text = (index + 1).toString() +
            '  ' +
            labels[index] +
            (complete ? '  ✓' : '');
        return GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: LiquidGlassSettings(
            thickness: 10,
            blur: 4,
            glassColor: active
                ? const Color(0x433DDC97)
                : const Color(0x17FFFFFF),
            refractiveIndex: 1.05,
          ),
          shape: const LiquidRoundedSuperellipse(borderRadius: 10),
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          child: Text(
            text,
            style: TextStyle(
              color: active || complete
                  ? TechColors.textPrimary
                  : TechColors.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
            ),
          ),
        );
      }),
    );
  }

  Widget _companyStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthGlassMessage(
            text:
                'You will become the initial Branch Head. The branch and its active Branch Head assignment are created together in one server transaction.',
            error: false,
          ),
          const SizedBox(height: 14),
          _field('Company / Organization Name', _organizationController),
          const SizedBox(height: 12),
          _field('Branch Name', _branchController),
          const SizedBox(height: 12),
          _field(
            'Unique Branch Identifier',
            _branchIdentifierController,
            placeholder: 'e.g. TCS@Singur_1',
            helper:
                'Opaque business identifier. Special characters are allowed.',
            action: TextInputAction.done,
          ),
        ],
      );

  Widget _profileStep() => LayoutBuilder(
        builder: (context, constraints) {
          final twoColumns = constraints.maxWidth >= 760;
          final fields = <Widget>[
            _field('Full Name', _fullNameController),
            _field(
              'Employee Number',
              _employeeIdController,
              placeholder: 'EMP001',
              helper:
                  'Stored in the existing organization_members.employee_id field.',
            ),
            _field(
              'Phone Number',
              _phoneController,
              placeholder: '+919876543210',
              keyboardType: TextInputType.phone,
            ),
            _field('Address Line 1', _addressLine1Controller),
            _field('Address Line 2', _addressLine2Controller),
            _field('City', _cityController),
            _field('State', _stateController),
            _field('Postal Code', _postalCodeController),
            _field('Country', _countryController),
            _field('ID Proof Type', _idProofTypeController),
            _field('ID Proof Number', _idProofNumberController),
          ];
          if (!twoColumns) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final field in fields) ...[
                  field,
                  const SizedBox(height: 10),
                ],
                const AuthGlassMessage(
                  text:
                      'ID proof is collected as submitted information. InsightFlow does not perform ID-proof verification.',
                  error: false,
                ),
              ],
            );
          }
          final left = <Widget>[];
          final right = <Widget>[];
          for (var i = 0; i < fields.length; i++) {
            (i.isEven ? left : right).add(fields[i]);
            (i.isEven ? left : right).add(const SizedBox(height: 10));
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: left)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(children: right)),
                ],
              ),
              const AuthGlassMessage(
                text:
                    'ID proof is collected as submitted information. InsightFlow does not perform ID-proof verification.',
                error: false,
              ),
            ],
          );
        },
      );

  Widget _emailStep() {
    if (_authoritativeEmailVerified) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthGlassMessage(
            text:
                'EMAIL VERIFIED • SUPABASE AUTH\nThis authenticated email is already confirmed by the identity provider. Registration uses the authoritative Supabase state.',
            error: false,
          ),
          const SizedBox(height: 10),
          _field(
            'Authenticated Email',
            TextEditingController(text: _authenticatedEmail),
            readOnly: true,
          ),
          const SizedBox(height: 10),
          const Text(
            'Provider verification is kept distinct from EMAIL OTP VERIFIED. An optional OTP can still be sent through Supabase Auth.',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 9,
              height: 1.35,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          if (!_emailOtpVerified)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _sendEmailOtp,
                child: const Text('Verify email with OTP'),
              ),
            )
          else
            const Text(
              'EMAIL OTP VERIFIED',
              style: TextStyle(
                color: TechColors.statusGreen,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AuthGlassMessage(
          text:
              'Verify the authenticated email through Supabase Auth before registration.',
          error: false,
        ),
        const SizedBox(height: 10),
        _field(
          'Authenticated Email',
          TextEditingController(text: _authenticatedEmail),
          readOnly: true,
        ),
        const SizedBox(height: 10),
        if (!_emailOtpSent)
          GlassButton.custom(
            onTap: _busy ? () {} : _sendEmailOtp,
            enabled: !_busy,
            width: double.infinity,
            height: 44,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'Send email OTP',
            child: const Text('Send email OTP'),
          )
        else ...[
          _field(
            'Email OTP',
            _emailOtpController,
            placeholder: '6-digit code',
            keyboardType: TextInputType.number,
            action: TextInputAction.done,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : _verifyEmailOtp,
                child: const Text('Verify email OTP'),
              ),
              TextButton(
                onPressed: _busy ? null : _sendEmailOtp,
                child: const Text('Resend OTP'),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _phoneStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _field(
            'Phone Number',
            _phoneController,
            placeholder: '+919876543210',
            keyboardType: TextInputType.phone,
            readOnly: _phoneVerified,
          ),
          const SizedBox(height: 10),
          if (_phoneVerified)
            const AuthGlassMessage(
              text:
                  'PHONE VERIFIED • SUPABASE AUTH\nThe submitted phone is confirmed by the current authenticated Supabase identity.',
              error: false,
            )
          else if (!_phoneOtpSent)
            GlassButton.custom(
              onTap: _busy ? () {} : _startPhoneOtp,
              enabled: !_busy,
              width: double.infinity,
              height: 44,
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              label: 'Verify phone',
              child: const Text('Verify phone'),
            )
          else ...[
            _field(
              'Phone OTP',
              _phoneOtpController,
              placeholder: '6-digit SMS code',
              keyboardType: TextInputType.number,
              action: TextInputAction.done,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _verifyPhoneOtp,
                  child: const Text('Verify phone OTP'),
                ),
                TextButton(
                  onPressed: _busy ? null : _resendPhoneOtp,
                  child: const Text('Resend OTP'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'SMS delivery and phone verification are enforced by Supabase Auth. InsightFlow never accepts a client-side phone_verified flag.',
              style: TextStyle(
                color: TechColors.textMuted,
                fontSize: 9,
                fontFamily: 'monospace',
              ),
            ),
          ],
        ],
      );

  Widget _reviewStep() {
    final idType = _idProofTypeController.text.trim();
    final idNumber = _idProofNumberController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AuthGlassMessage(
          text:
              'Review the Branch Head profile. Registration creates the company, branch, membership, branch_head assignment, profile, and audit events atomically on the server.',
          error: false,
        ),
        const SizedBox(height: 12),
        _reviewRow('COMPANY', _organizationController.text.trim()),
        _reviewRow('BRANCH', _branchController.text.trim()),
        _reviewRow('BRANCH ID', _branchIdentifierController.text.trim()),
        _reviewRow('BRANCH HEAD', _fullNameController.text.trim()),
        _reviewRow('EMPLOYEE NUMBER', _employeeIdController.text.trim()),
        _reviewRow('EMAIL', _authenticatedEmail + ' ✓'),
        _reviewRow('PHONE', _phoneController.text.trim() + ' ✓'),
        _reviewRow(
          'ADDRESS',
          [
            _addressLine1Controller.text.trim(),
            _addressLine2Controller.text.trim(),
            _cityController.text.trim(),
            _stateController.text.trim(),
            _postalCodeController.text.trim(),
            _countryController.text.trim(),
          ].where((value) => value.isNotEmpty).join(', '),
        ),
        _reviewRow('ID PROOF', idType + '  ' + _maskIdProof(idNumber)),
        const SizedBox(height: 12),
        const Text(
          'ROLE  branch_head\nASSIGNMENT  active\nREPORTS TO  —\nSECTION  —',
          style: TextStyle(
            color: TechColors.textMuted,
            fontSize: 10,
            height: 1.4,
            fontFamily: 'monospace',
          ),
        ),
      ],
    );
  }

  Widget _reviewRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: const LiquidGlassSettings(
            thickness: 10,
            blur: 4,
            glassColor: Color(0x15FFFFFF),
            refractiveIndex: 1.05,
          ),
          shape: const LiquidRoundedSuperellipse(borderRadius: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 110,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value.isEmpty ? '—' : value,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
        ),
      );

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _companyStep();
      case 1:
        return _profileStep();
      case 2:
        return _emailStep();
      case 3:
        return _phoneStep();
      case 4:
        return _reviewStep();
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _navigation() => Row(
        children: [
          if (_step > 0)
            Expanded(
              child: TextButton(
                onPressed: _busy ? null : _previousStep,
                child: const Text('Back'),
              ),
            ),
          if (_step > 0) const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: GlassButton.custom(
              onTap: _busy
                  ? () {}
                  : _step == 4
                      ? _register
                      : _nextStep,
              enabled: !_busy,
              width: double.infinity,
              height: 46,
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              label: _step == 4
                  ? (_busy ? 'Registering…' : 'Register Company')
                  : 'Continue',
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_busy) const CupertinoActivityIndicator(),
                  if (_busy) const SizedBox(width: 8),
                  Text(
                    _step == 4
                        ? (_busy ? 'Registering…' : 'Register Company')
                        : 'Continue',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );

  @override
  Widget build(BuildContext context) {
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    final authenticated = user != null;

    return AuthGlassScaffold(
      wideContent: true,
      title: 'REGISTER / COMPANY',
      subtitle: authenticated
          ? 'Create a company, initial branch, and authenticated Branch Head profile.'
          : 'Authenticate the founder identity first.',
      children: [
        if (!authenticated)
          GlassButton.custom(
            onTap: _busy
                ? () {}
                : () => InsightFlowSupabaseAuthService.signInWithOAuth(
                      OAuthProvider.google,
                    ),
            enabled: !_busy,
            width: double.infinity,
            height: 44,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'Continue with Google',
            child: const Text('Continue with Google'),
          )
        else ...[
          _stepIndicator(),
          const SizedBox(height: 14),
          _stepBody(),
          if (_message != null) ...[
            const SizedBox(height: 10),
            AuthGlassMessage(text: _message!, error: _error),
          ],
          if (_organizationDiagnostic != null) ...[
            const SizedBox(height: 10),
            AuthGlassMessage(
              text: _organizationDiagnostic!.displayText,
              error: _organizationDiagnostic!.stage != 'HTTP_SUCCESS',
            ),
          ],
          const SizedBox(height: 14),
          _navigation(),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy
                ? null
                : () => InsightFlowSupabaseAuthService.signOut(),
            child: const Text('Cancel onboarding'),
          ),
        ],
      ],
    );
  }
}
