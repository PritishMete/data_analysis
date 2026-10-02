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

  test('phone calling code and national number are separate responsive controls', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    for (final screen in [company, employee]) {
      expect(screen, contains('Widget _phoneInputRow(double width)'));
      expect(screen, contains("label: 'COUNTRY CODE *'"));
      expect(screen, contains('ProfileFloatingLabelField('));
      expect(screen, contains("label: 'Phone number'"));
      expect(screen, contains("placeholder: 'Enter phone number'"));
      expect(screen, contains('national/local number only'));
      expect(screen, contains('if (width < 440)'));
      expect(screen, contains('Expanded(\n            flex: 1'));
      expect(screen, contains('Expanded(\n            flex: 3'));
      expect(screen, contains('FilteringTextInputFormatter.digitsOnly'));
      expect(screen, isNot(contains('Expanded(flex: 2, child: countryCode)')));
      expect(screen, isNot(contains('Expanded(flex: 3, child: nationalNumber)')));
    }
    expect(company, isNot(contains("_field('Employee Number'")));
    expect(company, contains('AUTO-GENERATED'));
    expect(company, isNot(contains("'employee_id': _employeeId")));
  });

  test('shared profile phone field owns the floating-label interaction', () {
    final widgets = source('lib/core/profile/profile_form_widgets.dart');
    expect(widgets, contains('class ProfileFloatingLabelField'));
    expect(widgets, contains('AnimatedPositioned'));
    expect(widgets, contains('AnimatedDefaultTextStyle'));
    expect(widgets, contains('_focused || widget.controller.text.isNotEmpty'));
    expect(widgets, contains('InputBorder.none'));
    expect(widgets, contains('color: floated'));
  });

  test('phone payload and E.164 normalization remain unchanged', () {
    final company = source('lib/features/auth/company_registration_screen.dart');
    final employee = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    for (final screen in [company, employee]) {
      expect(screen, contains('_phoneCountry!.subtitle'));
      expect(screen, contains('_phone.text.replaceAll(RegExp(r'\\D'), '')'));
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
