import 'package:flutter_test/flutter_test.dart';

import '../lib/core/services/synthetic_data_result_decoder.dart';

void main() {
  test('synthetic JS object is converted without JSON decoding an object', () {
    final value = <String, dynamic>{
      'success': true,
      'route': 'operation',
      'sheetName': 'Hypothetical_Revenue',
      'generated_column': 'Revenue (Hypothetical)',
      'hypothetical': true,
      'generation': {'min': 0, 'max': 1000, 'seed': 42},
    };
    final decoded = decodeSyntheticInteropValue(value);
    expect(decoded['success'], true);
    expect(decoded['sheetName'], 'Hypothetical_Revenue');
    expect(decoded['generation'], isA<Map>());
  });

  test('legacy JSON text is decoded exactly once for compatibility', () {
    const jsonText = '{"success":true,"sheetName":"Hypothetical_Revenue","hypothetical":true}';
    final decoded = decodeSyntheticInteropValue(jsonText);
    expect(decoded['success'], true);
    expect(decoded['sheetName'], 'Hypothetical_Revenue');
  });

  test('unsupported interop value fails with a contract error', () {
    expect(() => decodeSyntheticInteropValue(42), throwsA(isA<FormatException>()));
  });
}
