import 'package:country_codes_plus/country_codes_plus.dart';

import 'profile_form_widgets.dart';

class ProfileGeoData {
  static Future<void>? _initialization;

  static Future<void> ensureInitialized() {
    return _initialization ??= CountryCodes.init().then((_) {});
  }

  static List<ProfileOption> countryOptions() {
    final result = <ProfileOption>[];
    final seen = <String>{};
    for (final entry in CountryCodes.allCountries) {
      final code = entry.alpha2Code?.trim().toUpperCase() ?? '';
      final name = entry.name?.trim() ?? '';
      final dial = entry.dialCode?.trim() ?? '';
      if (code.length != 2 || name.isEmpty || !seen.add(name.toLowerCase())) {
        continue;
      }
      result.add(ProfileOption(value: code, label: name, subtitle: dial));
    }
    result.sort((a, b) {
      final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byName == 0 ? a.value.compareTo(b.value) : byName;
    });
    return result;
  }

  static List<ProfileOption> subdivisionOptions(String countryCode) {
    final result = <ProfileOption>[];
    final seen = <String>{};
    for (final entry in CountryCodes.subdivisionsForCountry(
      countryCode.toUpperCase(),
    )) {
      final code = entry.code?.trim().toUpperCase() ?? '';
      final name = entry.name?.trim() ?? '';
      if (code.isEmpty || name.isEmpty || !seen.add(name.toLowerCase())) {
        continue;
      }
      result.add(ProfileOption(value: code, label: name));
    }
    result.sort((a, b) {
      final byName = a.label.toLowerCase().compareTo(b.label.toLowerCase());
      return byName == 0 ? a.value.compareTo(b.value) : byName;
    });
    return result;
  }

  static List<ProfileOption> phoneCountryOptions(String phone) {
    final result = <ProfileOption>[];
    final seen = <String>{};
    for (final entry in CountryCodes.countriesFromPhoneNumber(phone)) {
      final code = entry.alpha2Code?.trim().toUpperCase() ?? '';
      final name = entry.name?.trim() ?? '';
      final dial = entry.dialCode?.trim() ?? '';
      if (code.length != 2 || name.isEmpty || dial.isEmpty || !seen.add(code)) {
        continue;
      }
      result.add(ProfileOption(value: code, label: name, subtitle: dial));
    }
    return result;
  }

  static ProfileOption notApplicableState() => const ProfileOption(
        value: '',
        label: 'Not applicable (no first-level subdivisions)',
      );

  static List<ProfileOption> idProofOptions(String countryCode) {
    const india = <ProfileOption>[
      ProfileOption(value: 'aadhaar', label: 'Aadhaar'),
      ProfileOption(value: 'pan', label: 'PAN'),
      ProfileOption(value: 'voter_id', label: 'Voter ID'),
      ProfileOption(value: 'passport', label: 'Passport'),
      ProfileOption(value: 'driving_license', label: 'Driving Licence'),
      ProfileOption(
        value: 'national_id',
        label: 'National ID / National Identity Card',
      ),
      ProfileOption(
        value: 'other_government_id',
        label: 'Other Government ID',
      ),
    ];

    const international = <ProfileOption>[
      ProfileOption(
        value: 'national_id',
        label: 'National ID / National Identity Card',
      ),
      ProfileOption(value: 'passport', label: 'Passport'),
      ProfileOption(value: 'driving_license', label: 'Driving Licence'),
      ProfileOption(
        value: 'other_government_id',
        label: 'Other Government ID',
      ),
    ];

    return countryCode.toUpperCase() == 'IN' ? india : international;
  }
}
