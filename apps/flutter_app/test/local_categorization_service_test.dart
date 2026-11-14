import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/core/services/local_categorization_service.dart';

void main() {
  test('local categorization normalizes country, gender, and bool in place while leaving currency unchanged', () async {
    final rows = <List<dynamic>>[
      ['Country', 'Region', 'City', 'Gender', 'Bool', 'Currency'],
      ['India', 'Asia', 'New Delhi', 'F', 1, r'$1250'],
      ['India', 'Asia', 'Delhi', 'Male', 'Yes', '₹900'],
      ['Idnia', 'Asia', 'moscow', 'm ', 'Yes', r'$20'],
      ['Uae', 'Middle East', 'Dubai', 'Female', 'No', 'Aed 150'],
      ['United Arab Emirates', 'Middle East', 'Dubai', 'Female', 'No', 'د.إ 80'],
      ['Arab', 'Middle East', 'Abu Dhabi', 'Female', 'No', '₹ 50'],
      ['United Kingdom', 'Europe', 'London', 'Female', 'Yes', '£35'],
      ['Uk', 'Europe', 'London', 'Female', 'n ', '£20'],
      ['Singapore', 'Asia', 'Singapore', 'T', 'No', 'Sgd 40'],
      ['Singapor', 'asia', 'Singapore', 'Femalee', 'Yes', r'S$25'],
      ['Bangladesh', 'Asia', 'Dhaka', 'Male', 'NOOO', '৳1200'],
      ['bd', 'Asia', 'Dhaka', 'Female', 'Y ', '৳800'],
      ['Russia', 'Europe', 'Moscow', 'Male', 'No', '₽3000'],
      ['russina', 'eu ', 'mumbai', 'Female', 'Yes', 'Rubel 2500'],
      ['Usa', 'North America', 'New York', 'M', 'Yes', '₹ 100'],
      ['Us', 'North America', 'New York', 'Female', 'No', 'Usd 75'],
      ['Canada', 'North America', 'Toronto', 'Female', '0', 'Cad 60'],
      ['Canad', 'North America', 'nyc', 'Male', 'No', r'C$45'],
      ['India', 'Asia', 'Kolkata', 'F', 'yess', '₹1,500'],
      ['india', 'Asia', 'Kolkata', 'Female', 'No', '₹ 20'],
      ['India', 'Asia', 'Kolkata', 'Female', 'No', '\u00A0₹\u00A0 75\u00A0'],
      ['India', 'Asia', 'Kolkata', 'Female', 'No', '₹\u202F1,250'],
    ];

    final result = await LocalCategorizationService.execute(
      sourceRows: rows,
      sourceColumns: const ['Country', 'Gender', 'Bool'],
      allColumns: false,
      targetCurrency: null,
    );

    expect(result.rows.first, rows.first);
    expect(result.rows.length, rows.length);
    expect(result.diagnostics['ai_used'], isFalse);
    expect(result.diagnostics['privacy_mode'], 'local_only');
    expect(result.diagnostics['categorization_engine'], 'local_deterministic');
    expect(result.diagnostics['raw_data_sent_to_ai'], isFalse);
    expect(result.diagnostics['unique_values_sent_to_ai'], isFalse);

    final headers = result.rows.first;
    final countryIndex = headers.indexOf('Country');
    final genderIndex = headers.indexOf('Gender');
    final boolIndex = headers.indexOf('Bool');
    final currencyIndex = headers.indexOf('Currency');
    final normalizedCountry = result.rows.skip(1).map((row) => row[countryIndex]).toList();
    final normalizedGender = result.rows.skip(1).map((row) => row[genderIndex]).toList();
    final normalizedBool = result.rows.skip(1).map((row) => row[boolIndex]).toList();
    final currencies = result.rows.skip(1).map((row) => row[currencyIndex]).toList();

    expect(normalizedCountry, [
      'India',
      'India',
      'India',
      'United Arab Emirates',
      'United Arab Emirates',
      'United Arab Emirates',
      'United Kingdom',
      'United Kingdom',
      'Singapore',
      'Singapore',
      'Bangladesh',
      'Bangladesh',
      'Russia',
      'Russia',
      'United States',
      'United States',
      'Canada',
      'Canada',
      'India',
      'India',
      'India',
      'India',
    ]);
    expect(normalizedGender, [
      'Female',
      'Male',
      'Male',
      'Female',
      'Female',
      'Female',
      'Female',
      'Female',
      'Transgender',
      'Female',
      'Male',
      'Female',
      'Male',
      'Female',
      'Male',
      'Female',
      'Female',
      'Male',
      'Female',
      'Female',
      'Female',
      'Female',
    ]);
    expect(normalizedBool, [
      'Yes',
      'Yes',
      'Yes',
      'No',
      'No',
      'No',
      'Yes',
      'No',
      'No',
      'Yes',
      'No',
      'Yes',
      'No',
      'Yes',
      'Yes',
      'No',
      'No',
      'No',
      'Yes',
      'No',
      'No',
      'No',
    ]);
    expect(currencies, [
      r'$1250',
      '₹900',
      r'$20',
      'Aed 150',
      'د.إ 80',
      '₹ 50',
      '£35',
      '£20',
      'Sgd 40',
      r'S$25',
      '৳1200',
      '৳800',
      '₽3000',
      'Rubel 2500',
      '₹ 100',
      'Usd 75',
      'Cad 60',
      r'C$45',
      '₹1,500',
      '₹ 20',
      '\u00A0₹\u00A0 75\u00A0',
      '₹\u202F1,250',
    ]);
  });

  test('local categorization standardizes semantic aliases and leaves currency unchanged without USD fallback', () async {
    final rows = <List<dynamic>>[
      ['Country', 'Region', 'City', 'Gender', 'Bool', 'Currency'],
      ['Arab', 'eu', 'nyc', 'T', 'yess', r'C$45'],
      ['Uae', 'asia', 'moscow', 'Femalee', 'NOOO', 'XYZ 500'],
      ['Uk', 'Middle East', 'mumbai', 'M', '1', '₹50'],
    ];

    final result = await LocalCategorizationService.execute(
      sourceRows: rows,
      sourceColumns: const ['Country', 'Region', 'City', 'Gender', 'Bool', 'Currency'],
      allColumns: true,
      targetCurrency: null,
    );

    final headers = result.rows.first;
    final countryIndex = headers.indexOf('Country');
    final regionIndex = headers.indexOf('Region');
    final cityIndex = headers.indexOf('City');
    final genderIndex = headers.indexOf('Gender');
    final boolIndex = headers.indexOf('Bool');
    final currencyIndex = headers.indexOf('Currency');

    expect(result.rows.skip(1).map((row) => row[countryIndex]).toList(), [
      'United Arab Emirates',
      'United Arab Emirates',
      'United Kingdom',
    ]);
    expect(result.rows.skip(1).map((row) => row[regionIndex]).toList(), [
      'Europe',
      'Asia',
      'Middle East',
    ]);
    expect(result.rows.skip(1).map((row) => row[cityIndex]).toList(), [
      'New York',
      'Moscow',
      'Mumbai',
    ]);
    expect(result.rows.skip(1).map((row) => row[genderIndex]).toList(), [
      'Transgender',
      'Female',
      'Male',
    ]);
    expect(result.rows.skip(1).map((row) => row[boolIndex]).toList(), [
      'Yes',
      'No',
      'Yes',
    ]);
    expect(result.rows.skip(1).map((row) => row[currencyIndex]).toList(), [
      r'C$45',
      'XYZ 500',
      '₹50',
    ]);
  });

  test('currency columns remain unchanged without explicit conversion intent', () async {
    final rows = <List<dynamic>>[
      ['Currency'],
      [r'$1250'],
      ['₹900'],
      ['Aed 150'],
      ['د.إ 80'],
      ['₹ 50'],
      ['£35'],
      ['Sgd 40'],
      [r'S$25'],
      ['৳1200'],
      ['Rubel 2500'],
      ['₽3000'],
      ['Usd 75'],
      ['Cad 60'],
      [r'C$45'],
      ['₹ 100'],
      ['₹1,500'],
      ['₹ 20'],
      ['\u00A0₹\u00A0 75\u00A0'],
      ['₹\u202F1,250'],
    ];

    final result = await LocalCategorizationService.execute(
      sourceRows: rows,
      sourceColumns: const ['Currency'],
      allColumns: true,
      targetCurrency: null,
    );

    final currencyIndex = result.rows.first.indexOf('Currency');
    expect(result.rows.skip(1).map((row) => row[currencyIndex]).toList(), [
      r'$1250',
      '₹900',
      'Aed 150',
      'د.إ 80',
      '₹ 50',
      '£35',
      'Sgd 40',
      r'S$25',
      '৳1200',
      'Rubel 2500',
      '₽3000',
      'Usd 75',
      'Cad 60',
      r'C$45',
      '₹ 100',
      '₹1,500',
      '₹ 20',
      '\u00A0₹\u00A0 75\u00A0',
      '₹\u202F1,250',
    ]);
  });

  test('explicit INR conversion returns numeric cells and INR number format metadata', () async {
    final rows = <List<dynamic>>[
      ['Currency'],
      ['₹ 50'],
      ['₹900'],
      ['₹1,500'],
    ];

    final result = await LocalCategorizationService.execute(
      sourceRows: rows,
      sourceColumns: const ['Currency'],
      allColumns: true,
      targetCurrency: 'INR',
    );

    final currencyIndex = result.rows.first.indexOf('Currency');
    expect(result.rows.skip(1).map((row) => row[currencyIndex]).toList(), [50.0, 900.0, 1500.0]);
    expect(result.numberFormats['Currency'], '₹#,##0.00');
    expect(result.convertedColumns, ['Currency']);
    expect(result.convertedCells, 3);
  });
}
