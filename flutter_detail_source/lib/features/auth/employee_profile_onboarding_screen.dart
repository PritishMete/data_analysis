import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../core/profile/profile_form_widgets.dart';
import '../../core/profile/profile_geo_data.dart';
import 'auth_glass_widgets.dart';

class EmployeeProfileOnboardingScreen extends StatefulWidget {
  const EmployeeProfileOnboardingScreen({
    super.key,
    required this.workspaceId,
    required this.onCompleted,
  });

  final String workspaceId;
  final Future<void> Function() onCompleted;

  @override
  State<EmployeeProfileOnboardingScreen> createState() =>
      _EmployeeProfileOnboardingScreenState();
}

class _EmployeeProfileOnboardingScreenState
    extends State<EmployeeProfileOnboardingScreen> {
  final _fullName = TextEditingController();
  final _phone = TextEditingController();
  final _address1 = TextEditingController();
  final _address2 = TextEditingController();
  final _postal = TextEditingController();
  final _proofNumber = TextEditingController();
  final _otp = TextEditingController();

  List<ProfileOption> _countries = const [];
  List<ProfileOption> _states = const [];
  List<ProfileOption> _proofs = const [];
  ProfileOption? _country;
  ProfileOption? _state;
  ProfileOption? _phoneCountry;
  ProfileOption? _proofType;
  int _step = 0;
  bool _loading = true;
  bool _busy = false;
  bool _phoneVerified = false;
  bool _otpSent = false;
  int _cooldown = 0;
  Timer? _timer;
  String _employeeId = '';
  String _email = '';
  String? _message;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final controller in [
      _fullName,
      _phone,
      _address1,
      _address2,
      _postal,
      _proofNumber,
      _otp,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await ProfileGeoData.ensureInitialized();
      final response = await http
          .get(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/profile/me'),
            headers: {
              ...await supabaseAuthHeaders(),
              'X-InsightFlow-Workspace-ID': widget.workspaceId,
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        throw StateError('Your employee profile could not be loaded.');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      _employeeId = data['employee_id']?.toString() ?? '';
      _email = data['email']?.toString() ?? '';
      _fullName.text = data['full_name']?.toString() ?? '';
      _address1.text = data['address_line1']?.toString() ?? '';
      _address2.text = data['address_line2']?.toString() ?? '';
      _postal.text = data['postal_code']?.toString() ?? '';

      _countries = ProfileGeoData.countryOptions();

      final countryCode = data['country_code']?.toString() ?? '';
      if (countryCode.isNotEmpty) {
        _country = _find(_countries, countryCode);
      }
      _rebuildStates();

      final stateCode = data['state_code']?.toString() ?? '';
      if (stateCode.isNotEmpty) {
        _state = _find(_states, stateCode);
      } else if (_country != null && _states.isEmpty) {
        _state = ProfileGeoData.notApplicableState();
      }

      _proofs = _country == null
          ? const []
          : ProfileGeoData.idProofOptions(_country!.value);
      final proofType = data['id_proof_type']?.toString() ?? '';
      if (proofType.isNotEmpty) {
        _proofType = _find(_proofs, proofType);
      }

      final verifiedPhone = data['phone_e164']?.toString() ?? '';
      if (verifiedPhone.isNotEmpty) {
        final matches = ProfileGeoData.phoneCountryOptions(verifiedPhone);
        if (matches.isNotEmpty) {
          _phoneCountry = matches.first;
          final dial = _phoneCountry!.subtitle.replaceAll(
            RegExp(r'\s+'),
            '',
          );
          if (verifiedPhone.startsWith(dial)) {
            _phone.text = verifiedPhone.substring(dial.length);
          }
        }
      }
      _phoneVerified = data['phone_verified'] == true;

      if (_email.isEmpty) {
        _email = InsightFlowSupabaseAuthService.currentSupabaseUser?.email ?? '';
      }

      if (mounted) setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
          _message = error is StateError
              ? error.message
              : 'Profile could not be loaded.';
        });
      }
    }
  }

  ProfileOption? _find(List<ProfileOption> values, String value) {
    for (final option in values) {
      if (option.value.toLowerCase() == value.toLowerCase()) return option;
    }
    return null;
  }

  void _rebuildStates() {
    _states = _country == null
        ? const []
        : ProfileGeoData.subdivisionOptions(_country!.value);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = true;
      _message = message;
    });
  }

  String? _phoneE164() {
    final dial = _phoneCountry?.subtitle.replaceAll(RegExp(r'\s+'), '') ?? '';
    final national = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (dial.isEmpty || national.length < 4 || national.length > 15) {
      return null;
    }
    return dial + national;
  }

  void _startCooldown() {
    _timer?.cancel();
    setState(() => _cooldown = 60);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_cooldown <= 1) {
        timer.cancel();
        setState(() => _cooldown = 0);
      } else {
        setState(() => _cooldown -= 1);
      }
    });
  }

  Future<void> _sendOtp() async {
    final phone = _phoneE164();
    if (phone == null) {
      _fail('Select a country calling code and enter a valid national number.');
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      final user =
          await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
      if (user == null) {
        throw StateError('Your authenticated session could not be restored.');
      }

      if (user.phone == phone && user.phoneConfirmedAt != null) {
        if (mounted) {
          setState(() {
            _busy = false;
            _phoneVerified = true;
            _message = 'PHONE VERIFIED ✓';
          });
        }
        return;
      }

      await InsightFlowSupabaseAuthService.beginPhoneVerification(phone);
      _otp.clear();
      _otpSent = true;
      _phoneVerified = false;
      _startCooldown();

      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'OTP SENT. Enter the SMS code supplied by Supabase.';
        });
      }
    } on AuthException catch (error) {
      final lower = error.message.toLowerCase();
      if (lower.contains('rate') || lower.contains('too many')) {
        _fail('SMS rate limit reached. Please wait and try again.');
      } else if (lower.contains('provider') ||
          lower.contains('sms') ||
          lower.contains('disabled')) {
        _fail(
          'Phone verification is unavailable. Configure Supabase Phone Auth and an SMS provider.',
        );
      } else if (lower.contains('already') || lower.contains('exist')) {
        _fail('That phone number is already associated with another account.');
      } else {
        _fail(
          'The phone number could not be verified. Check the number and try again.',
        );
      }
    } catch (error) {
      _fail(
        error is StateError
            ? error.message
            : 'Phone verification could not be started.',
      );
    }
  }

  Future<void> _resendOtp() async {
    final phone = _phoneE164();
    if (phone == null || _busy || _cooldown > 0) return;

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      await InsightFlowSupabaseAuthService.resendPhoneChangeOtp(phone);
      _startCooldown();
      if (mounted) {
        setState(() {
          _busy = false;
          _message = 'A new SMS OTP was requested. Supabase rate limits still apply.';
        });
      }
    } on AuthException catch (_) {
      _fail('The SMS provider rejected the resend or rate-limited the request.');
    } catch (_) {
      _fail('The SMS OTP could not be resent.');
    }
  }

  Future<void> _verifyOtp() async {
    final phone = _phoneE164();
    final token = _otp.text.trim();
    if (phone == null) {
      _fail('Enter a valid phone number first.');
      return;
    }
    if (!RegExp(r'^\d{6}$').hasMatch(token)) {
      _fail('Enter the 6-digit SMS code.');
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      final before = InsightFlowSupabaseAuthService.currentSupabaseUser;
      if (before == null) {
        throw StateError('Your authenticated session could not be restored.');
      }

      final result =
          await InsightFlowSupabaseAuthService.verifyPhoneChangeOtp(
        phone: phone,
        token: token,
      );
      final current =
          await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();

      if (current == null ||
          current.id != before.id ||
          (result.user != null && result.user!.id != before.id)) {
        throw StateError('Phone verification returned a different account.');
      }

      if (current.phone != phone || current.phoneConfirmedAt == null) {
        throw StateError('Supabase did not confirm this phone number.');
      }

      _timer?.cancel();
      if (mounted) {
        setState(() {
          _busy = false;
          _phoneVerified = true;
          _otpSent = false;
          _cooldown = 0;
          _message = 'PHONE VERIFIED ✓';
        });
      }
    } on AuthException catch (_) {
      _fail('The SMS code is invalid or expired. Request a new code.');
    } catch (error) {
      _fail(
        error is StateError ? error.message : 'Phone verification failed.',
      );
    }
  }

  Future<void> _pickCountry() async {
    final choice = await showProfileOptionPicker(
      context,
      title: 'Country',
      options: _countries,
      selectedValue: _country?.value,
    );
    if (choice == null) return;
    setState(() {
      _country = choice;
      _state = null;
      _proofType = null;
      _proofs = ProfileGeoData.idProofOptions(choice.value);
      _rebuildStates();
      if (_states.isEmpty) {
        _state = ProfileGeoData.notApplicableState();
      }
    });
  }

  Future<void> _pickState() async {
    if (_country == null) {
      _fail('Select a country first.');
      return;
    }
    final choice = await showProfileOptionPicker(
      context,
      title: 'State / Province / Region',
      options: _states,
      selectedValue: _state?.value,
    );
    if (choice != null) setState(() => _state = choice);
  }

  Future<void> _pickPhoneCountry() async {
    final choice = await showProfileOptionPicker(
      context,
      title: 'Phone country code',
      options: _countries
          .where((item) => item.subtitle.isNotEmpty)
          .toList(),
      selectedValue: _phoneCountry?.value,
    );
    if (choice != null) {
      setState(() {
        _phoneCountry = choice;
        _phoneVerified = false;
        _otpSent = false;
        _message = null;
      });
    }
  }

  Future<void> _pickProof() async {
    final choice = await showProfileOptionPicker(
      context,
      title: 'ID Proof Type',
      options: _proofs,
      selectedValue: _proofType?.value,
    );
    if (choice != null) setState(() => _proofType = choice);
  }

  bool _profileValid() =>
      _fullName.text.trim().isNotEmpty &&
      _employeeId.isNotEmpty &&
      _email.isNotEmpty &&
      _address1.text.trim().isNotEmpty &&
      _postal.text.trim().isNotEmpty &&
      _country != null &&
      _state != null &&
      _proofType != null &&
      _proofNumber.text.trim().isNotEmpty;

  Future<void> _complete() async {
    if (!_profileValid()) {
      _fail('Complete every required profile field. Address Line 2 is optional.');
      return;
    }
    final phone = _phoneE164();
    if (phone == null || !_phoneVerified) {
      _fail('Verify the required phone number with SMS OTP first.');
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      final response = await http.put(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/profile/me'),
        headers: {
          ...await supabaseAuthHeaders(),
          'Content-Type': 'application/json',
          'X-InsightFlow-Workspace-ID': widget.workspaceId,
        },
        body: jsonEncode({
          'full_name': _fullName.text.trim(),
          'phone': phone,
          'phone_country_calling_code': _phoneCountry!.subtitle,
          'phone_national_number': _phone.text.replaceAll(RegExp(r'\D'), ''),
          'address_line1': _address1.text.trim(),
          'address_line2': _address2.text.trim(),
          'country_code': _country!.value,
          'country': _country!.label,
          'state_code': _state!.value,
          'state': _state!.label,
          'postal_code': _postal.text.trim(),
          'id_proof_type': _proofType!.value,
          'id_proof_number': _proofNumber.text.trim(),
        }),
      );

      Map<String, dynamic>? data;
      try {
        data = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (_) {}

      if (response.statusCode != 200) {
        final detail = data?['detail']?.toString();
        throw StateError(
          detail != null && detail.isNotEmpty
              ? detail
              : 'Profile could not be saved.',
        );
      }

      await widget.onCompleted();
    } catch (error) {
      _fail(
        error is StateError ? error.message : 'Profile could not be saved.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AuthGlassScaffold(
        title: 'EMPLOYEE / PROFILE',
        subtitle: 'Loading your organization profile…',
        children: [Center(child: CupertinoActivityIndicator())],
      );
    }

    return AuthGlassScaffold(
      wideContent: true,
      title: 'EMPLOYEE / PROFILE',
      subtitle: 'Complete your profile before workspace access is enabled.',
      children: [
        AuthGlassMessage(
          text: _email.isEmpty
              ? 'Your authenticated email must already be confirmed.'
              : 'EMAIL  ' + _email + '  •  VERIFIED',
          error: false,
        ),
        const SizedBox(height: 12),
        if (_step == 0) ...[
          LayoutBuilder(
            builder: (context, constraints) {
              final fields = <Widget>[
                _field('Full Name', _fullName),
                _readonly('Employee Number', _employeeId),
                _readonly('Email', _email + '  •  CONFIRMED'),
                _field('Address Line 1', _address1),
                _field('Address Line 2', _address2, required: false),
                ProfileSelectField(
                  label: 'Country *',
                  value: _country?.label,
                  placeholder: 'Select country',
                  onTap: _busy ? null : _pickCountry,
                ),
                ProfileSelectField(
                  label: 'State / Province / Region *',
                  value: _state?.label,
                  placeholder: _country == null
                      ? 'Select country first'
                      : _states.isEmpty
                          ? 'Not applicable for this country'
                          : 'Select state / province / region',
                  onTap: _busy || (_country != null && _states.isEmpty)
                      ? null
                      : _pickState,
                ),
                _field('PIN / Postal Code', _postal, placeholder: 'Postal code'),
                ProfileSelectField(
                  label: 'ID Proof Type *',
                  value: _proofType?.label,
                  placeholder: 'Select government document',
                  onTap: _busy ? null : _pickProof,
                ),
                _field(
                  'ID Proof Number',
                  _proofNumber,
                  placeholder: 'Government ID number',
                ),
              ];

              if (constraints.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final field in fields) ...[
                      field,
                      const SizedBox(height: 10),
                    ],
                  ],
                );
              }

              final left = <Widget>[];
              final right = <Widget>[];
              for (var i = 0; i < fields.length; i++) {
                (i.isEven ? left : right).addAll([
                  fields[i],
                  const SizedBox(height: 10),
                ]);
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: Column(children: left)),
                  const SizedBox(width: 12),
                  Expanded(child: Column(children: right)),
                ],
              );
            },
          ),
          const AuthGlassMessage(
            text:
                'ID PROOF • PROVIDED. InsightFlow does not perform ID-proof verification.',
            error: false,
          ),
        ] else if (_step == 1) ...[
          ProfileSelectField(
            label: 'Phone Country Code *',
            value: _phoneCountry == null
                ? null
                : _phoneCountry!.label + '  ' + _phoneCountry!.subtitle,
            placeholder: 'Select country calling code',
            onTap: _busy ? null : _pickPhoneCountry,
          ),
          const SizedBox(height: 10),
          _field(
            'Phone Number',
            _phone,
            placeholder: 'National / local number only',
            type: TextInputType.phone,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'Enter only the national/local number. The selected calling code is combined into the canonical phone value.',
            style: TextStyle(color: TechColors.textMuted, fontSize: 9),
          ),
          const SizedBox(height: 12),
          if (_phoneVerified)
            const AuthGlassMessage(text: 'PHONE VERIFIED ✓', error: false)
          else if (!_otpSent)
            GlassButton.custom(
              onTap: _busy ? () {} : _sendOtp,
              enabled: !_busy,
              width: double.infinity,
              height: 44,
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              label: 'SEND OTP',
              child: const Text('SEND OTP'),
            )
          else ...[
            const AuthGlassFieldLabel('OTP SENT'),
            GlassTextField(
              controller: _otp,
              placeholder: '6-digit SMS code',
              keyboardType: TextInputType.number,
              enabled: !_busy,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.digitsOnly,
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : _verifyOtp,
                  child: const Text('VERIFY PHONE'),
                ),
                TextButton(
                  onPressed: _busy || _cooldown > 0 ? null : _resendOtp,
                  child: Text(
                    _cooldown > 0
                        ? 'RESEND OTP (' + _cooldown.toString() + ')'
                        : 'RESEND OTP',
                  ),
                ),
              ],
            ),
          ],
        ] else ...[
          const AuthGlassMessage(
            text:
                'Review the profile before saving it. Email and phone verification come from Supabase Auth.',
            error: false,
          ),
          const SizedBox(height: 12),
          _review('FULL NAME', _fullName.text),
          _review('EMPLOYEE NUMBER', _employeeId),
          _review('EMAIL', _email + ' ✓'),
          _review('PHONE', (_phoneE164() ?? '—') + ' ✓'),
          _review('ADDRESS LINE 1', _address1.text),
          if (_address2.text.trim().isNotEmpty)
            _review('ADDRESS LINE 2', _address2.text),
          _review('STATE', _state?.label ?? ''),
          _review('COUNTRY', _country?.label ?? ''),
          _review('PIN / POSTAL CODE', _postal.text),
          _review(
            'ID PROOF',
            (_proofType?.label ?? '') + '  ' + _mask(_proofNumber.text),
          ),
          const SizedBox(height: 10),
          GlassButton.custom(
            onTap: _busy ? () {} : _complete,
            enabled: !_busy,
            width: double.infinity,
            height: 46,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'COMPLETE PROFILE',
            child: Text(
              _busy ? 'Saving…' : 'COMPLETE PROFILE',
            ),
          ),
        ],
        if (_message != null) ...[
          const SizedBox(height: 10),
          AuthGlassMessage(text: _message!, error: _error),
        ],
        const SizedBox(height: 10),
        if (_step > 0)
          TextButton(
            onPressed: _busy ? null : () => setState(() => _step -= 1),
            child: const Text('Back'),
          ),
        if (_step < 2)
          GlassButton.custom(
            onTap: _busy ? () {} : _next,
            enabled: !_busy,
            width: double.infinity,
            height: 46,
            shape: const LiquidRoundedSuperellipse(borderRadius: 14),
            label: 'CONTINUE',
            child: const Text('CONTINUE'),
          ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: _busy ? null : InsightFlowSupabaseAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }

  void _next() {
    if (_step == 0 && !_profileValid()) {
      _fail('Complete every required profile field. Address Line 2 is optional.');
      return;
    }
    if (_step == 1 && !_phoneVerified) {
      _fail('Verify your phone before continuing.');
      return;
    }
    setState(() {
      _message = null;
      _error = false;
      _step += 1;
    });
  }

  Widget _field(
    String label,
    TextEditingController controller, {
    String? placeholder,
    bool required = true,
    TextInputType type = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthGlassFieldLabel(label + (required ? ' *' : '')),
        GlassTextField(
          controller: controller,
          placeholder: placeholder ?? label,
          enabled: !_busy,
          keyboardType: type,
          inputFormatters: inputFormatters,
        ),
      ],
    );
  }

  Widget _readonly(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthGlassFieldLabel(label),
        GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: const LiquidGlassSettings(
            thickness: 10,
            blur: 4,
            glassColor: Color(0x14FFFFFF),
            refractiveIndex: 1.05,
          ),
          shape: const LiquidRoundedSuperellipse(borderRadius: 10),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
          child: Text(
            value.isEmpty ? '—' : value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: TechColors.textPrimary,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }

  Widget _review(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
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
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: Text(
                  label,
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
                  maxLines: 3,
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

  String _mask(String value) {
    final compact = value.replaceAll(RegExp(r'\s+'), '');
    if (compact.length <= 4) return compact;
    return ('X' * (compact.length - 4)) + compact.substring(compact.length - 4);
  }
}
