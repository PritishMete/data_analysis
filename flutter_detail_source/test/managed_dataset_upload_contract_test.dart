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
    final loadEnd = source.indexOf('Future<void> _loadManagerUploadGrants()', loadStart);
    expect(loadStart, greaterThanOrEqualTo(0));
    expect(loadEnd, greaterThan(loadStart));
    final coreLoad = source.substring(loadStart, loadEnd);

    expect(coreLoad, contains("_get('/v1/managed-datasets')"));
    expect(coreLoad, contains("_get('/v1/authz/management')"));
    expect(coreLoad, isNot(contains("data-access/catalog")));
    expect(coreLoad, isNot(contains("data-access/requests")));
    expect(coreLoad, contains('_loadCatalog()'));
    expect(coreLoad, contains('_loadCopyRequests()'));

    expect(source, contains('Future<void> _loadCatalog() async'));
    expect(source, contains('Future<void> _loadCopyRequests() async'));
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
    expect(source, contains("d['display_name']?.toString() ?? d['dataset_name']"));
    final uploadStart = source.indexOf('Future<void> _upload({String? datasetId})');
    final uploadEnd = source.indexOf('Future<void> _deleteDataset()', uploadStart);
    expect(uploadStart, greaterThanOrEqualTo(0));
    expect(uploadEnd, greaterThan(uploadStart));
    final upload = source.substring(uploadStart, uploadEnd);
    expect(upload, contains('if (datasetId == null)'));
    expect(upload, contains('datasetName = await _promptDatasetName(suggestedName)'));
    // Dataset naming must not regress the existing authorized dataset actions.
    expect(source, contains('/profile?preview_limit=5'));
    expect(source, contains('Future<void> _select(Map<String,dynamic> d)'));
    expect(source, contains('Future<void> _requestCopy(String datasetId)'));
    expect(source, contains('Future<void> _decideRequest(String requestId, bool approve)'));
    expect(source, contains("'/decision'"));
  });

}
