import 'dart:js_interop';

import 'package:js/js.dart' as legacy_js;

@legacy_js.JS('insightflowSetMutationAuthorization')
external void _setMutationAuthorization(
  String idToken,
  String workspaceId,
  String resourceId,
  String action,
  String backendBaseUrl,
);

@legacy_js.JS('insightflowClearMutationAuthorization')
external void _clearMutationAuthorization();

Future<void> setExcelMutationAuthorization({
  required String idToken,
  required String workspaceId,
  required String resourceId,
  required String action,
  required String backendBaseUrl,
}) async {
  _setMutationAuthorization(
    idToken,
    workspaceId,
    resourceId,
    action,
    backendBaseUrl,
  );
}

void clearExcelMutationAuthorization() {
  _clearMutationAuthorization();
}
