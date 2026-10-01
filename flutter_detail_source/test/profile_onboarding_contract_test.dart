import 'dart:io';

import 'package:test/test.dart';

String source(String path) => File(path).readAsStringSync();

void main() {
  test('Branch Head registration has no email OTP step', () {
    final text = source('lib/features/auth/company_registration_screen.dart');
    expect(text, contains("['COMPANY', 'BRANCH HEAD', 'PHONE', 'REVIEW']"));
    expect(text, contains('EMAIL CONFIRMED'));
    expect(text, isNot(contains('sendEmailOtp')));
    expect(text, isNot(contains('verifyEmailOtp')));
    expect(text, isNot(contains('OTP SENT TO EMAIL')));
  });

  test('employee onboarding uses confirmation-link state and native phone OTP', () {
    final text = source('lib/features/auth/employee_profile_onboarding_screen.dart');
    expect(text, contains('PHONE VERIFIED'));
    expect(text, contains('SEND OTP'));
    expect(text, contains('VERIFY PHONE'));
    expect(text, contains('resendPhoneChangeOtp'));
    expect(text, contains('verifyPhoneChangeOtp'));
    expect(text, isNot(contains('sendEmailOtp')));
    expect(text, isNot(contains('email OTP')));
  });

  test('profile geography is data-driven and dependent', () {
    final geo = source('lib/core/profile/profile_geo_data.dart');
    final company = source('lib/features/auth/company_registration_screen.dart');
    expect(geo, contains('CountryCodes.allCountries'));
    expect(geo, contains('CountryCodes.subdivisionsForCountry'));
    expect(geo, contains('notApplicableState'));
    expect(company, contains("label: 'Country *'"));
    expect(company, contains('Not applicable for this country'));
    expect(employee, contains('Not applicable for this country'));
    expect(company, contains("label: 'State / Province / Region *'"));
    expect(company, contains('_state = null'));
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
