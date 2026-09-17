import 'package:flutter_test/flutter_test.dart';

import '../lib/core/services/secure_excel_local_service.dart';

void main() {
  test('routes missing plus duplicate quality questions to local secure Excel', () {
    expect(
      SecureExcelLocalService.supportsQuery(
        'Check for missing values and duplicate restaurant IDs',
      ),
      isTrue,
    );
    expect(
      SecureExcelLocalService.supportsQuery(
        'Find blank values and duplicated outlet IDs',
      ),
      isTrue,
    );
  });

  test('routes grouped count questions to local secure Excel', () {
    for (final query in [
      'Show the number of restaurants in each city',
      'Count restaurants per city',
      'How many restaurants are there by city?',
      'Group restaurants by city and count them',
    ]) {
      expect(SecureExcelLocalService.supportsQuery(query), isTrue, reason: query);
    }
  });

  test('does not route unrelated analytical questions to local secure Excel', () {
    expect(
      SecureExcelLocalService.supportsQuery('Compare average rating by city'),
      isFalse,
    );
    expect(
      SecureExcelLocalService.supportsQuery('Show restaurants with online delivery'),
      isFalse,
    );
  });
}
