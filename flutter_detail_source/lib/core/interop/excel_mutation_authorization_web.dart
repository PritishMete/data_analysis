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
