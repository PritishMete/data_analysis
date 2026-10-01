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
import 'management_shell.dart';

class CompanyRegistrationScreen extends StatefulWidget {
  const CompanyRegistrationScreen({super.key});

  @override
  State<CompanyRegistrationScreen> createState() =>
      _CompanyRegistrationScreenState();
}

class _CompanyRegistrationScreenState
    extends State<CompanyRegistrationScreen> {
  final _organization = TextEditingController();
  final _branch = TextEditingController();
  final _branchIdentifier = TextEditingController();
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
  String? _message;
  bool _error = false;
  OrganizationServiceDiagnostic? _organizationDiagnostic;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _organization,
      _branch,
      _branchIdentifier,
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
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    final metadata = user?.userMetadata ?? const <String, dynamic>{};
    final suggested = (metadata['full_name'] ??
            metadata['name'] ??
            metadata['display_name'] ??
            '')
        .toString()
        .trim();
    if (suggested.isNotEmpty) _fullName.text = suggested;

    try {
      await ProfileGeoData.ensureInitialized();
      _countries = ProfileGeoData.countryOptions();
    } catch (_) {
      _error = true;
      _message = 'Country and state data could not be initialized.';
    }

    if (mounted) setState(() => _loading = false);
  }

  String? get _email =>
      InsightFlowSupabaseAuthService.currentSupabaseUser?.email?.trim();

  bool get _emailConfirmed =>
      InsightFlowSupabaseAuthService.currentSupabaseUser?.emailConfirmedAt !=
      null;

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = true;
      _message = message;
    });
  }

  String? _phoneE164() {
    final dial =
        _phoneCountry?.subtitle.replaceAll(RegExp(r'\s+'), '') ?? '';
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
    );
    if (choice == null) return;
    setState(() {
      _country = choice;
      _proofType = null;
      _states = ProfileGeoData.subdivisionOptions(choice.value);
      _state = _states.isEmpty
          ? ProfileGeoData.notApplicableState()
          : null;
      _proofs = ProfileGeoData.idProofOptions(choice.value);
    });
  }

  Future<void> _pickState() async {
    if (_country == null) {
      _fail('Select a country before selecting the state.');
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
      _email?.isNotEmpty == true &&
      _emailConfirmed &&
      _phoneE164() != null &&
      _address1.text.trim().isNotEmpty &&
      _postal.text.trim().isNotEmpty &&
      _country != null &&
      _state != null &&
      _proofType != null &&
      _proofNumber.text.trim().isNotEmpty;

  void _next() {
    if (_step == 0 &&
        (_organization.text.trim().isEmpty ||
            _branch.text.trim().isEmpty ||
            _branchIdentifier.text.trim().isEmpty)) {
      _fail('Enter company name, branch name, and branch identifier.');
      return;
    }

    if (_step == 1 && !_profileValid()) {
      _fail('Complete every required Branch Head profile field, including a valid phone number.');
      return;
    }

    setState(() {
      _message = null;
      _error = false;
      _step += 1;
    });
  }

  Future<void> _register() async {
    final phone = _phoneE164();
    if (!_profileValid() || phone == null) {
      _fail('Complete the Branch Head profile, including a valid phone number, before registering.');
      return;
    }

    final session = await InsightFlowSupabaseAuthService.ensureSession(
      timeout: const Duration(seconds: 8),
    );
    final user = session == null
        ? null
        : InsightFlowSupabaseAuthService.currentSupabaseUser;
    if (session == null || user == null) {
      _fail('Your authenticated Supabase session could not be restored.');
      return;
    }

    final authoritative =
        await InsightFlowSupabaseAuthService.fetchAuthoritativeUser();
    if (authoritative == null ||
        authoritative.id != user.id ||
        authoritative.emailConfirmedAt == null) {
      _fail('Your authenticated email is not confirmed. Sign in again.');
      return;
    }

    setState(() {
      _busy = true;
      _error = false;
      _message = null;
    });

    try {
      final request = await organizationServiceRequest(
        method: 'POST',
        path: '/v1/authz/organizations/register',
        contentType: 'application/json',
        send: (headers) => http.post(
          Uri.parse(
            '$insightFlowBackendBaseUrl/v1/authz/organizations/register',
          ),
          headers: headers,
          body: jsonEncode({
            'organization_name': _organization.text.trim(),
            'branch_name': _branch.text.trim(),
            'branch_identifier': _branchIdentifier.text,
            'full_name': _fullName.text.trim(),
            'phone': phone,
            'phone_country_calling_code': _phoneCountry!.subtitle,
            'phone_national_number':
                _phone.text.replaceAll(RegExp(r'\D'), ''),
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
        ),
      );

      _organizationDiagnostic = request.diagnostic;
      final response = request.response;
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
      final businessError =
          organizationServiceBusinessErrorMessage(response);
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
              : 'This company registration conflicts with existing identity data.',
        );
      }
      if (response.statusCode == 422) {
        throw StateError('Organization registration request was rejected by the server.');
      }
      if (response.statusCode >= 500) {
        throw StateError("InsightFlow's organization service returned a server error.");
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
      final assignedEmployeeId =
          decoded is Map ? decoded['employee_id']?.toString().trim() : null;
      if (workspaceId == null || workspaceId.isEmpty ||
          assignedEmployeeId == null || assignedEmployeeId.isEmpty) {
        throw StateError(
          'InsightFlow could not create the organization. The server returned an incomplete response.',
        );
      }

      await setInsightFlowWorkspaceId(user.id, workspaceId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Your Employee ID is $assignedEmployeeId')),
      );
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ManagementShell()),
      );
    } on OrganizationServiceRequestException catch (error) {
      _organizationDiagnostic = error.diagnostic;
      _fail('InsightFlow couldn’t reach the organization service.');
    } catch (error) {
      _fail(
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
    bool required = true,
    TextInputType type = TextInputType.text,
    List<TextInputFormatter>? inputFormatters,
    String? helper,
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
        if (helper != null) ...[
          const SizedBox(height: 4),
          Text(
            helper,
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 9,
              height: 1.3,
            ),
          ),
        ],
      ],
    );
  }

  Widget _emailField() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthGlassFieldLabel('EMAIL *'),
          GlassContainer(
            useOwnLayer: true,
            quality: GlassQuality.minimal,
            settings: const LiquidGlassSettings(
              thickness: 10,
              blur: 4,
              glassColor: Color(0x15FFFFFF),
              refractiveIndex: 1.05,
            ),
            shape: const LiquidRoundedSuperellipse(borderRadius: 10),
            padding: const EdgeInsets.all(12),
            child: Text(
              (_email ?? 'Missing authenticated email') +
                  (_emailConfirmed
                      ? '  •  EMAIL CONFIRMED'
                      : '  •  EMAIL NOT CONFIRMED'),
              style: TextStyle(
                color: _emailConfirmed
                    ? TechColors.statusGreen
                    : TechColors.statusRed,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      );

  Widget _employeeIdInfo() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthGlassFieldLabel('EMPLOYEE ID'),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'AUTO-GENERATED',
                  style: TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Assigned automatically after registration',
                  style: TextStyle(color: TechColors.textMuted, fontSize: 9),
                ),
              ],
            ),
          ),
        ],
      );

  Widget _profileStep() => LayoutBuilder(
        builder: (context, constraints) {
          final fields = <Widget>[
            _field('Full Name', _fullName),
            _employeeIdInfo(),
            _emailField(),
             LayoutBuilder(
               builder: (context, constraints) =>
                   _phoneInputRow(constraints.maxWidth),
             ),
             const SizedBox(height: 6),
             const Text(
               'Enter the national/local number only. The country calling code is added automatically.',
               style: TextStyle(color: TechColors.textMuted, fontSize: 9),
             ),
             const SizedBox(height: 10),
            _field('Address Line 1', _address1),
            _field(
              'Address Line 2',
              _address2,
              required: false,
              helper: 'Optional',
            ),
            ProfileSelectField(
              label: 'Country *',
              value: _country?.label,
              placeholder: _countries.isEmpty
                  ? 'Loading countries…'
                  : 'Select country',
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
      );

  Widget _phoneInputRow(double width) {
    final countryCode = ProfileSelectField(
      label: 'COUNTRY CODE *',
      value: _phoneCountry == null
          ? null
          : _phoneCountry!.label + '  ' + _phoneCountry!.subtitle,
      placeholder: 'Select calling code',
      onTap: _busy ? null : _pickPhoneCountry,
    );
    final nationalNumber = _field(
      'PHONE NUMBER',
      _phone,
      required: true,
      placeholder: 'Enter phone number',
      type: TextInputType.phone,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
    );
    if (width < 520) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          countryCode,
          const SizedBox(height: 10),
          nationalNumber,
        ],
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(flex: 2, child: countryCode),
        const SizedBox(width: 12),
        Expanded(flex: 3, child: nationalNumber),
      ],
    );
  }

  Widget _reviewStep() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthGlassMessage(
            text:
                'Review the Branch Head profile. The registering account becomes the initial Branch Head; Manager is assigned separately. Email is already confirmed; phone is stored in E.164 format and is not phone-verified during onboarding.',
            error: false,
          ),
          const SizedBox(height: 12),
          _review('COMPANY', _organization.text.trim()),
          _review('BRANCH', _branch.text.trim()),
          _review('BRANCH ID', _branchIdentifier.text.trim()),
          _review('BRANCH HEAD', _fullName.text.trim()),
          _review('EMPLOYEE ID', 'AUTO-GENERATED'),
          _review('EMAIL', (_email ?? '—') + '  ✓'),
          _review('PHONE', _phoneE164() ?? '—'),
          _review('ADDRESS LINE 1', _address1.text.trim()),
          if (_address2.text.trim().isNotEmpty)
            _review('ADDRESS LINE 2', _address2.text.trim()),
          _review('STATE', _state?.label ?? ''),
          _review('COUNTRY', _country?.label ?? ''),
          _review('PIN / POSTAL CODE', _postal.text.trim()),
          _review(
            'ID PROOF',
            (_proofType?.label ?? '') + '  ' + _mask(_proofNumber.text),
          ),
          const SizedBox(height: 6),
          const Text(
            'ID PROOF • PROVIDED. InsightFlow does not perform ID-proof verification.',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
        ],
      );

  Widget _review(String label, String value) => Padding(
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
                width: 116,
                child: Text(
                  label,
                  maxLines: 1,
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
    return ('X' * (compact.length - 4)) +
        compact.substring(compact.length - 4);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AuthGlassScaffold(
        title: 'REGISTER / COMPANY',
        subtitle: 'Loading profile data…',
        children: [Center(child: CupertinoActivityIndicator())],
      );
    }

    final authenticated =
        InsightFlowSupabaseAuthService.currentSupabaseUser != null;

    return AuthGlassScaffold(
      wideContent: true,
      title: 'REGISTER / COMPANY',
      subtitle: authenticated
          ? 'Create the company, initial branch, and Branch Head profile.'
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
          if (_step == 0)
            _companyBody()
          else if (_step == 1)
            _profileStep()
          else if (_step == 2)
            _phoneStep()
          else
            _reviewStep(),
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
            onPressed: _busy ? null : InsightFlowSupabaseAuthService.signOut,
            child: const Text('Cancel onboarding'),
          ),
        ],
      ],
    );
  }

  Widget _companyBody() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AuthGlassMessage(
            text:
                'Your authenticated email is already confirmed before this screen. There is no email OTP step here.',
            error: false,
          ),
          const SizedBox(height: 12),
          _field('Company / Organization Name', _organization),
          const SizedBox(height: 10),
          _field('Branch Name', _branch),
          const SizedBox(height: 10),
          _field(
            'Unique Branch Identifier',
            _branchIdentifier,
            placeholder: 'e.g. TCS@Singur_1',
            helper: 'Opaque business identifier. Special characters are allowed.',
          ),
        ],
      );

  Widget _stepIndicator() {
    const labels = ['COMPANY', 'BRANCH HEAD PROFILE', 'REVIEW'];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: List.generate(labels.length, (index) {
        final active = index == _step;
        final complete = index < _step;
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
            (index + 1).toString() +
                '  ' +
                labels[index] +
                (complete ? '  ✓' : ''),
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

  Widget _navigation() => Row(
        children: [
          if (_step > 0)
            Expanded(
              child: TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                          _step -= 1;
                          _message = null;
                          _error = false;
                        }),
                child: const Text('Back'),
              ),
            ),
          if (_step > 0) const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: GlassButton.custom(
              onTap: _busy
                  ? () {}
                  : (_step == 2 ? _register : _next),
              enabled: !_busy,
              width: double.infinity,
              height: 46,
              shape: const LiquidRoundedSuperellipse(borderRadius: 14),
              label: _step == 2
                   ? (_busy ? 'Registering…' : 'Register Company')
                  : 'Continue',
              child: Text(
                _step == 2
                   ? (_busy ? 'Registering…' : 'Register Company')
                    : 'Continue',
              ),
            ),
          ),
        ],
      );
}
