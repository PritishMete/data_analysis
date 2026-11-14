Future<void> setExcelMutationAuthorization({
  required String idToken,
  required String workspaceId,
  required String resourceId,
  required String action,
  required String backendBaseUrl,
}) async {}

void clearExcelMutationAuthorization() {}


Future<String?> getWorkbookDatasetId(String sourceSheetName) async => null;

Future<Map<String, dynamic>?> createWorkbookWorkingCopy({
  required String sourceSheetName,
  required String workingCopyId,
}) async => null;
