import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('city count query path does not retain unsupported inline regex flag', () {
    final source = File('lib/features/dashboard/data_screen.dart').readAsStringSync();

    expect(source, isNot(contains("RegExp(r'(?i)\\bout\\s+of\\b')")));
    expect(
      source,
      contains("RegExp(r'\\bout\\s+of\\b', caseSensitive: false)"),
    );
  });

  test('rating phrase normalization compiles without FormatException', () {
    const query = 'Show the number of restaurants in each city';

    expect(
      () => query.replaceAll(
        RegExp(r'\bout\s+of\b', caseSensitive: false),
        '/',
      ),
      returnsNormally,
    );
    expect(
      'Rated 4.1 OUT OF 5'.replaceAll(
        RegExp(r'\bout\s+of\b', caseSensitive: false),
        '/',
      ),
      'Rated 4.1 / 5',
    );
  });
}
