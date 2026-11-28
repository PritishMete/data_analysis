import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/core/config/backend_origin.dart';

void main() {
  test('uses a supplied origin and removes trailing slash', () {
    expect(
      normalizeInsightFlowBackendOrigin('https://api.example.test///'),
      'https://api.example.test',
    );
  });

  test('empty configuration uses the Render rollback fallback', () {
    expect(
      normalizeInsightFlowBackendOrigin(''),
      insightFlowDefaultBackendOrigin,
    );
  });

  test('rejects endpoint paths, query strings, fragments, and credentials', () {
    for (final value in <String>[
      'https://api.example.test/v1',
      'https://api.example.test?x=1',
      'https://api.example.test/#fragment',
      'https://user:password@api.example.test',
    ]) {
      expect(
        normalizeInsightFlowBackendOrigin(value),
        insightFlowDefaultBackendOrigin,
      );
    }
  });

  test('supports endpoint composition from the normalized origin', () {
    final origin = normalizeInsightFlowBackendOrigin(
      'https://api.example.test/',
    );
    expect('$origin/v1/build-info', 'https://api.example.test/v1/build-info');
  });
}
