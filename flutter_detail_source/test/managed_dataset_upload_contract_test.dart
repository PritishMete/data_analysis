import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('managed dataset upload contract is CSV-only and exposes upload states', () {
    final source = File(
      'lib/features/auth/authorization_management_screen.dart',
    ).readAsStringSync();

    expect(source, contains("FileType.custom"));
    expect(source, contains("allowedExtensions: const ['csv']"));
    expect(source, contains("_datasetUploading"));
    expect(source, contains("Preparing..."));
    expect(source, contains("Uploading & processing..."));
    expect(source, contains("Completed"));
    expect(source, contains("Failed"));
    expect(source, contains("/v1/managed-datasets"));
    expect(source, contains("Upload New Version"));
    expect(source, contains("Start Working"));
    expect(source, contains("row_count"));
    expect(source, contains("column_count"));
  });
}
