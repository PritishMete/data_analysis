import 'dart:io';

import 'package:test/test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  test('Branch Head registration has no email OTP step', () {
    final text = source('lib/features/auth/company_registration_screen.dart');
    expect(text, contains("['COMPANY', 'BRANCH HEAD PROFILE', 'REVIEW']"));
    expect(text, contains('EMAIL CONFIRMED'));
    expect(text, isNot(contains('sendEmailOtp')));
    expect(text, isNot(contains('verifyEmailOtp')));
    expect(text, isNot(contains('OTP SENT TO EMAIL')));
  });

  test('employee onboarding uses confirmation-link state and without phone OTP', () {
    final text = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    expect(text, isNot(contains('PHONE VERIFIED')));
    expect(text, isNot(contains('SEND OTP')));
    expect(text, isNot(contains('VERIFY PHONE')));
    expect(text, isNot(contains('resendPhoneChangeOtp')));
    expect(text, isNot(contains('verifyPhoneChangeOtp')));
    expect(text, isNot(contains('sendEmailOtp')));
    expect(text, isNot(contains('email OTP')));
  });

  test('profile geography is data-driven and dependent', () {
    final geo = source('lib/core/profile/profile_geo_data.dart');
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee =
        source('lib/features/auth/employee_profile_onboarding_screen.dart');
    expect(geo, contains('CountryCodes.allCountries'));
    expect(geo, contains('CountryCodes.subdivisionsForCountry'));
    expect(geo, contains('notApplicableState'));
    expect(company, contains("label: 'Country *'"));
    expect(company, contains('Not applicable for this country'));
    expect(employee, contains('Not applicable for this country'));
    expect(company, contains("label: 'State / Province / Region *'"));
    expect(company, contains('_state = _states.isEmpty'));
  });

  test('profile form keeps the requested two-column grid and phone ratio', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee =
        source('lib/features/auth/employee_profile_onboarding_screen.dart');

    for (final screen in [company, employee]) {
      expect(screen, contains('Widget _phoneInputRow()'));
      expect(screen, contains("label: 'COUNTRY CODE *'"));
      expect(screen, contains("const AuthGlassFieldLabel('PHONE NUMBER *')"));
      expect(screen, contains("placeholder: 'Phone number'"));
      expect(screen, contains('Expanded(flex: 1, child: countryCode)'));
      expect(screen, contains('Expanded(flex: 2, child: nationalNumber)'));
      expect(screen, contains("_field('Full Name'"));
      expect(screen, contains("_field('Address Line 1'"));
      expect(screen, contains("_field('Address Line 2'"));
      expect(screen, contains("label: 'Country *'"));
      expect(screen, contains("_field('PIN / Postal Code'"));
      expect(screen, contains("label: 'ID Proof Type *'"));
      expect(screen, contains("_field(\n                'ID Proof Number'"));
      expect(screen, contains('Row('));
      expect(screen, contains('if (constraints.maxWidth < 760)'));
      expect(screen, isNot(contains('ProfileFloatingLabelField(')));

      final nameIndex = screen.indexOf("_field('Full Name'");
      final employeeIndex = screen.indexOf('_employeeIdInfo()') >= 0
          ? screen.indexOf('_employeeIdInfo()')
          : screen.indexOf("_readonly('Employee ID'");
      final emailIndex = screen.indexOf('_emailField()') >= 0
          ? screen.indexOf('_emailField()')
          : screen.indexOf("_readonly('Email'");
      final phoneIndex = screen.indexOf('_phoneInputRow()');
      final address1Index = screen.indexOf("_field('Address Line 1'");
      final address2Index = screen.indexOf("_field('Address Line 2'");
      final countryIndex = screen.indexOf("label: 'Country *'");
      final postalIndex = screen.indexOf("_field('PIN / Postal Code'");
      final idTypeIndex = screen.indexOf("label: 'ID Proof Type *'");
      final idNumberIndex = screen.indexOf("'ID Proof Number'");

      expect(nameIndex, lessThan(employeeIndex));
      expect(employeeIndex, lessThan(emailIndex));
      expect(emailIndex, lessThan(phoneIndex));
      expect(phoneIndex, lessThan(address1Index));
      expect(address1Index, lessThan(address2Index));
      expect(address2Index, lessThan(countryIndex));
      expect(countryIndex, lessThan(postalIndex));
      expect(postalIndex, lessThan(idTypeIndex));
      expect(idTypeIndex, lessThan(idNumberIndex));
    }

    expect(company, isNot(contains("_field('Employee Number'")));
    expect(company, contains('AUTO-GENERATED'));
    expect(company, isNot(contains("'employee_id': _employeeId")));
  });

  test('address country is names-only while phone country code is separate', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee =
        source('lib/features/auth/employee_profile_onboarding_screen.dart');
    for (final screen in [company, employee]) {
      expect(screen, contains("label: 'Country *'"));
      expect(screen, contains("showOptionSubtitle: false"));
      expect(screen, contains('Future<void> _pickPhoneCountry()'));
      expect(screen, contains(
        'options: _countries.where((item) => item.subtitle.isNotEmpty).toList()',
      ));
      expect(screen, contains('_country'));
      expect(screen, contains('_phoneCountry'));
      expect(screen, isNot(contains('_country = _phoneCountry')));
      expect(screen, isNot(contains('_phoneCountry = _country')));
    }
  });

  test('phone field stays static and shared field heights remain uniform', () {
    final widgets = source('lib/core/profile/profile_form_widgets.dart');
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee =
        source('lib/features/auth/employee_profile_onboarding_screen.dart');

    expect(widgets, isNot(contains('ProfileFloatingLabelField')));
    expect(widgets, contains('kProfileFieldHeight'));
    for (final screen in [company, employee]) {
      expect(screen, contains('height: kProfileFieldHeight'));
      expect(screen, contains("placeholder: 'Phone number'"));
      expect(screen, isNot(contains('AnimatedPositioned')));
      expect(screen, isNot(contains('AnimatedDefaultTextStyle')));
      expect(screen, contains('Expanded(flex: 1, child: countryCode)'));
      expect(screen, contains('Expanded(flex: 2, child: nationalNumber)'));
    }
  });


  test('phone payload and E.164 normalization remain unchanged', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    for (final screen in [company, employee]) {
      expect(screen, contains('_phoneCountry!.subtitle'));
      expect(screen, contains("_phone.text.replaceAll(RegExp(r'\\D'), '')"));
      expect(screen, contains("'phone_country_calling_code'"));
      expect(screen, contains("'phone_national_number'"));
      expect(screen, contains("'phone': phone"));
      expect(screen, contains('return dial + national;'));
    }
  });

  test('address country and phone calling code remain independent selectors', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    for (final screen in [company, employee]) {
      expect(screen, contains("label: 'Country *'"));
      expect(screen, contains('Future<void> _pickPhoneCountry()'));
      expect(screen, contains('options: _countries.where((item) => item.subtitle.isNotEmpty).toList()'));
      expect(screen, contains('_country'));
      expect(screen, contains('_phoneCountry'));
      expect(screen, isNot(contains('_country = _phoneCountry')));
      expect(screen, isNot(contains('_phoneCountry = _country')));
    }
  });

  test('profile fields enforce optional address line 2 and ID-provided semantics', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    expect(company, contains("'Address Line 2'"));
    expect(company, contains('required: false'));
    expect(employee, contains('ID PROOF • PROVIDED'));
    expect(company, isNot(contains('ID PROOF VERIFIED')));
    expect(employee, isNot(contains('ID PROOF VERIFIED')));
  });

  test('confirmation redirect failures get a user-facing route', () {
    final gate = source('lib/features/auth/auth_gate.dart');
    expect(gate, contains('otp_expired'));
    expect(gate, contains('This confirmation link has expired.'));
    expect(gate, contains('CONTINUE TO SIGN IN'));
  });

  test('management detail keeps the requested profile fields', () {
    final shell = source('lib/features/auth/management_shell.dart');
    expect(shell, contains("ADDRESS LINE 1"));
    expect(shell, contains("ADDRESS LINE 2"));
    expect(shell, contains("PIN / POSTAL CODE"));
    expect(shell, contains("BRANCH HEAD"));
    expect(shell, contains("MANAGER"));
  });
}
