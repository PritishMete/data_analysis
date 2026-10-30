import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Import CSV opens the file picker before resolving remote upload scope', () {
    final source = File(
      'lib/features/auth/managed_dataset_access_workspace.dart',
    ).readAsStringSync();
    final uploadStart = source.indexOf('Future<void> _upload({String? datasetId})');
    final uploadEnd = source.indexOf('\n  Future<void> ', uploadStart + 10);

    expect(uploadStart, greaterThanOrEqualTo(0));
    expect(uploadEnd, greaterThan(uploadStart));

    final upload = source.substring(uploadStart, uploadEnd);
    final pickerIndex = upload.indexOf('FilePicker.platform.pickFiles');
    final scopeIndex = upload.indexOf("_get('/v1/managed-datasets/upload-scope')");
    final managerGrantIndex = upload.indexOf('_managerHasUploadGrantFor(selected)');

    expect(pickerIndex, greaterThanOrEqualTo(0));
    expect(scopeIndex, greaterThan(pickerIndex));
    // Keep the existing exact-branch Manager grant check after selection.
    expect(managerGrantIndex, greaterThan(pickerIndex));
    expect(upload, contains("allowedExtensions: const ['csv']"));
    expect(upload, contains('if (picked == null || picked.files.isEmpty'));
  });
}
