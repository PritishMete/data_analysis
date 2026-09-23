import 'dart:js_interop';

@JS('insightflowSetMutationAuthorization')
external void _setMutationAuthorization(
  JSString idToken,
  JSString workspaceId,
  JSString resourceId,
  JSString action,
  JSString backendBaseUrl,
);

@JS('insightflowClearMutationAuthorization')
external void _clearMutationAuthorization();

Future<void> setExcelMutationAuthorization({
  required String idToken,
  required String workspaceId,
  required String resourceId,
  required String action,
  required String backendBaseUrl,
}) async {
  _setMutationAuthorization(
    idToken.toJS,
    workspaceId.toJS,
    resourceId.toJS,
    action.toJS,
    backendBaseUrl.toJS,
  );
}

void clearExcelMutationAuthorization() {
  _clearMutationAuthorization();
}


@JS('getInsightFlowWorkbookDatasetId')
external JSPromise<JSString> _getWorkbookDatasetId(JSString sourceSheetName);

@JS('createInsightFlowWorkingCopy')
external JSPromise<JSAny?> _createWorkingCopy(
  JSString sourceSheetName,
  JSString workingCopyId,
);

Future<String?> getWorkbookDatasetId(String sourceSheetName) async {
  try {
    return (await _getWorkbookDatasetId(sourceSheetName).toDart).toDart;
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> createWorkbookWorkingCopy({
  required String sourceSheetName,
  required String workingCopyId,
}) async {
  try {
    final result = await _createWorkingCopy(
      sourceSheetName.toJS,
      workingCopyId.toJS,
    ).toDart;
    return result?.dartify() is Map
        ? Map<String, dynamic>.from(result!.dartify() as Map)
        : null;
  } catch (_) {
    return null;
  }
}
