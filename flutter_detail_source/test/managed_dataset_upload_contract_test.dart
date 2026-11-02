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


  test('Branch Data & Access isolates optional catalog and request failures', () {
    final source = File(
      'lib/features/auth/managed_dataset_access_workspace.dart',
    ).readAsStringSync();

    final loadStart = source.indexOf('Future<void> _load() async {');
    final loadEnd = source.indexOf('Future<void> _loadManagerUploadGrants(int generation)', loadStart);
    expect(loadStart, greaterThanOrEqualTo(0));
    expect(loadEnd, greaterThan(loadStart));
    final coreLoad = source.substring(loadStart, loadEnd);

    expect(coreLoad, contains('_loadAllAuthorizedDatasets()'));
    expect(coreLoad, isNot(contains("_get('/v1/managed-datasets')")));
    expect(coreLoad, contains("_get('/v1/authz/management')"));
    expect(coreLoad, isNot(contains("data-access/catalog")));
    expect(coreLoad, isNot(contains("data-access/requests")));
    expect(coreLoad, contains('_loadCatalog(generation)'));
    expect(coreLoad, contains('_loadCopyRequests(generation)'));

    expect(source, contains('Future<void> _loadCatalog(int generation) async'));
    expect(source, contains('Future<void> _loadCopyRequests(int generation) async'));
    expect(source, contains('_hasLoadedCoreSnapshot && _isTransientRefreshFailure(e)'));
    expect(source, contains('retryableStatuses = {429, 500, 502, 503, 504}'));
    expect(source, contains('catalogError != null'));
    expect(source, contains('requestsError != null'));
    expect(source, contains('selectedStillAuthorized'));
    expect(source, contains('if (!selectedStillAuthorized)'));
    expect(source, contains('catalog = [];'));
    expect(source, contains('requests = [];'));
  });

  test('new managed dataset uploads persist the name entered by the user', () {
    final source = File(
      'lib/features/auth/managed_dataset_access_workspace.dart',
    ).readAsStringSync();

    expect(source, contains('Future<String?> _promptDatasetName'));
    expect(source, contains("request.fields['dataset_name'] = datasetName"));
    expect(source, contains('String _name(Map<String,dynamic> d)'));
    expect(source, contains("const ['display_name', 'dataset_name', 'original_filename']"));
    final uploadStart = source.indexOf('Future<void> _upload({String? datasetId})');
    final uploadEnd = source.indexOf('Future<void> _deleteDataset()', uploadStart);
    expect(uploadStart, greaterThanOrEqualTo(0));
    expect(uploadEnd, greaterThan(uploadStart));
    final upload = source.substring(uploadStart, uploadEnd);
    expect(upload, contains('if (datasetId == null)'));
    expect(upload, contains('datasetName = await _promptDatasetName(suggestedName)'));
    expect(source, contains("import 'package:crypto/crypto.dart';"));
    expect(source, contains('String _managedDatasetSha256(Uint8List bytes)'));
    expect(source, contains('compute(_managedDatasetSha256, file.bytes!)'));
    expect(source, contains('progressClock.elapsedMilliseconds >= 100'));
    expect(source, contains('addStream(body.transform('));
    expect(source, contains("Duration(minutes: 5)"));
    expect(source, contains("Duration(seconds: 45)"));
    expect(source, contains('file.size > 100 * 1024 * 1024'));
    expect(source, contains("'/v1/managed-datasets/duplicate-check'"));
    final preflightIndex = source.indexOf("'/v1/managed-datasets/duplicate-check'");
    final uploadIndex = source.indexOf('var response = await sendUpload(', preflightIndex);
    expect(preflightIndex, greaterThanOrEqualTo(0));
    expect(uploadIndex, greaterThan(preflightIndex));
    expect(source, contains('Future<String?> _confirmDatasetReplacement(List conflicts)'));
    expect(source, contains("request.fields['replace_dataset_id'] = replaceId"));
    expect(source, contains("request.fields['confirm_duplicate'] = 'true'"));
    expect(source, contains('if (response.statusCode == 409)'));
    expect(source, contains('sendUpload(confirmDuplicate: true)'));
    expect(source, contains('Identical CSV content found'));
    expect(source, contains('Dataset name already exists'));
    expect(source, contains("response.statusCode == 409"));
    expect(source, contains("child: const Text('CANCEL')"));
    expect(source, contains("child: const Text('REPLACE DATASET')"));
    expect(source, contains('groupValue: selectedId'));
    expect(source, contains("datasetResult['content_unchanged'] == true"));
    expect(source, contains('no duplicate data was uploaded'));
    // Dataset naming must not regress the existing authorized dataset actions.
    expect(source, contains('/profile?preview_limit=5'));
    expect(source, contains('Future<void> _select(Map<String,dynamic> d)'));
    expect(source, contains('Future<void> _requestCopy(String datasetId)'));
    expect(source, contains('Future<void> _decideRequest(String requestId, bool approve)'));
    expect(source, contains('/decision'));
  });

}
