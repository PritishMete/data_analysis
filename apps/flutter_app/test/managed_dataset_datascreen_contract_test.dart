import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('managed DataScreen uses persisted dataset profile context', () {
    final source = File(
      'lib/features/dashboard/data_screen.dart',
    ).readAsStringSync();

    expect(source, contains('managedDatasetId'));
    expect(source, contains('managedVersionId'));
    expect(source, contains('/v1/managed-datasets/'));
    expect(source, contains('/profile'));
    expect(source, contains('Supabase PostgreSQL'));
  });
}
