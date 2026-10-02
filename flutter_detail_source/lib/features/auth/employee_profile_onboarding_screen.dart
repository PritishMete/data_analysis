import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

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
    for (final controller in [
      _fullName,
      _phone,
      _address1,
      _address2,
      _postal,
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

  Future<void> _pickCountry() async {
    final choice = await showProfileOptionPicker(
      context,
      title: 'Country',
      options: _countries,
      selectedValue: _country?.value,
      showOptionSubtitle: false,
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
      options: _countries.where((item) => item.subtitle.isNotEmpty).toList(),
      selectedValue: _phoneCountry?.value,
    );
    if (choice != null) setState(() => _phoneCountry = choice);
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
       _phoneE164() != null &&
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
    if (phone == null) {
      _fail('Enter a valid phone number before completing your profile.');
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

  Widget _phoneInputRow() {
    final countryCode = ProfileSelectField(
      label: 'COUNTRY CODE *',
      value: _phoneCountry == null
          ? null
          : _phoneCountry!.label + '  ' + _phoneCountry!.subtitle,
      placeholder: 'Select calling code',
      onTap: _busy ? null : _pickPhoneCountry,
    );
    final nationalNumber = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AuthGlassFieldLabel('PHONE NUMBER *'),
        SizedBox(
          height: kProfileFieldHeight,
          child: GlassTextField(
            controller: _phone,
            placeholder: 'Phone number',
            enabled: !_busy,
            keyboardType: TextInputType.phone,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
          ),
        ),
      ],
    );
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 1, child: countryCode),
        const SizedBox(width: 10),
        Expanded(flex: 2, child: nationalNumber),
      ],
    );
  }

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
              final rows = <List<Widget>>[
                [_field('Full Name', _fullName), _readonly('Employee ID', _employeeId)],
                [_readonly('Email', _email + '  •  CONFIRMED'), _phoneInputRow()],
                [
                  _field('Address Line 1', _address1),
                  ProfileSelectField(
                    label: 'Country *',
                    value: _country?.label,
                    placeholder: 'Select country',
                    onTap: _busy ? null : _pickCountry,
                  ),
                ],
                [
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
                ],
                [
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
                ],
              ];

              if (constraints.maxWidth < 760) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final row in rows) ...[
                      row[0],
                      const SizedBox(height: 10),
                      if (row[1] is! SizedBox) ...[
                        row[1],
                        const SizedBox(height: 10),
                      ],
                    ],
                  ],
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final row in rows) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: row[0]),
                        const SizedBox(width: 12),
                        Expanded(child: row[1]),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              );
            },
          ),
          const AuthGlassMessage(
            text:
                'ID PROOF • PROVIDED. InsightFlow does not perform ID-proof verification.',
            error: false,
          ),
        ] else ...[
          const AuthGlassMessage(
            text:
                'Review the profile before saving it. Email is confirmed; phone is stored in E.164 format and is not phone-verified during onboarding.',
            error: false,
          ),
          const SizedBox(height: 12),
          _review('FULL NAME', _fullName.text),
          _review('EMPLOYEE ID', _employeeId),
          _review('EMAIL', _email + ' ✓'),
          _review('PHONE', _phoneE164() ?? '—'),
          _review('ADDRESS LINE 1', _address1.text),
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
            height: kProfileFieldHeight,
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
        if (_step < 1)
          GlassButton.custom(
            onTap: _busy ? () {} : _next,
            enabled: !_busy,
            width: double.infinity,
            height: kProfileFieldHeight,
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
        SizedBox(
          height: kProfileFieldHeight,
          child: GlassTextField(
            controller: controller,
            placeholder: placeholder ?? label,
            enabled: !_busy,
            keyboardType: type,
            inputFormatters: inputFormatters,
          ),
        ),
      ],
    );
  }

  Widget _readonly(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AuthGlassFieldLabel(label),
        SizedBox(
          height: kProfileFieldHeight,
          child: GlassContainer(
            useOwnLayer: true,
            quality: GlassQuality.minimal,
            settings: const LiquidGlassSettings(
              thickness: 10,
              blur: 4,
              glassColor: Color(0x14FFFFFF),
              refractiveIndex: 1.05,
            ),
            shape: const LiquidRoundedSuperellipse(borderRadius: 10),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                value.isEmpty ? '—' : value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 11,
                ),
              ),
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
