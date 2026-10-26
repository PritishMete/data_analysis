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
    expect(source, contains("_datasetUploadFileName"));
    expect(source, contains("_datasetUploadFileSize"));
    expect(source, contains("Preparing"));
    expect(source, contains("Uploading"));
    expect(source, contains("Validating"));
    expect(source, contains("Importing"));
    expect(source, contains("Profiling"));
    expect(source, contains("Failed"));
    expect(source, contains("/v1/managed-datasets"));
    expect(source, contains("Upload New Version"));
    expect(source, contains("Start Working"));
    expect(source, contains("_managedDatasetRows(isOwner)"));
    expect(source, isNot(contains("_managedDatasetRows(isOwner || isManager)")));
    expect(source, contains("row_count"));
    expect(source, contains("column_count"));
  });

  test('manager proposal and Branch Head review UI use authenticated proposal routes', () {
    final source = File(
      'lib/features/auth/managed_dataset_access_workspace.dart',
    ).readAsStringSync();

    expect(source, contains("SUBMIT PROPOSAL"));
    expect(source, contains("/v1/managed-datasets/proposals"));
    expect(source, contains("/decision"));
    expect(source, contains("APPROVE"));
    expect(source, contains("REJECT"));
    expect(source, contains("decision_note"));
  });

  test('Team Lead delegation sends only the supported copy capability', () {
    final source = File(
      'lib/features/auth/authorization_management_screen.dart',
    ).readAsStringSync();
    final start = source.indexOf("await _post('delegations'");
    expect(start, greaterThanOrEqualTo(0));
    final end = source.indexOf('});', start);
    expect(end, greaterThan(start));
    final payload = source.substring(start, end);

    expect(payload, contains("'dataset.create_working_copy'"));
    expect(payload, isNot(contains("'dataset.view_original'")));
    expect(payload, isNot(contains("'dataset.share'")));
  });

}
