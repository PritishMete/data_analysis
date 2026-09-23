import 'dart:convert';

// Authorization integration formatting checkpoint.

import 'package:http/http.dart' as http;

import 'insightflow_auth_service.dart';
import '../interop/excel_mutation_authorization.dart';

const String insightFlowWorkspaceId = String.fromEnvironment(
  'INSIGHTFLOW_WORKSPACE_ID',
);
const String insightFlowBackendBaseUrl = String.fromEnvironment(
  'INSIGHTFLOW_BACKEND_URL',
  defaultValue: 'https://data-analysis-oajs.onrender.com',
);

String _safeResourceId(String raw) {
  final normalized = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '_');
  final value = normalized.replaceAll(RegExp(r'_+'), '_');
  return value.isEmpty
      ? 'active-sheet'
      : value.substring(0, value.length > 128 ? 128 : value.length);
}

Future<void> attachFirebaseAuth(
  http.BaseRequest request, {
  String? resourceId,
  bool forceRefresh = false,
}) async {
  final token = await InsightFlowAuthService.getIdToken(
    forceRefresh: forceRefresh,
  );
  request.headers['Authorization'] = 'Bearer $token';
  if (insightFlowWorkspaceId.isNotEmpty) {
    request.headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
  }
  if (resourceId != null && resourceId.trim().isNotEmpty) {
    request.headers['X-InsightFlow-Resource-ID'] = _safeResourceId(resourceId);
  }
}

Future<Map<String, String>> firebaseAuthHeaders({
  String? resourceId,
  bool forceRefresh = false,
}) async {
  final token = await InsightFlowAuthService.getIdToken(
    forceRefresh: forceRefresh,
  );
  final headers = <String, String>{'Authorization': 'Bearer $token'};
  if (insightFlowWorkspaceId.isNotEmpty) {
    headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
  }
  if (resourceId != null && resourceId.trim().isNotEmpty) {
    headers['X-InsightFlow-Resource-ID'] = _safeResourceId(resourceId);
  }
  return headers;
}

Future<String?> _resolveDatasetId(String sourceSheetName) async {
  final id = await getWorkbookDatasetId(sourceSheetName);
  if (id == null || id.isEmpty) return null;
  try {
    final headers = await firebaseAuthHeaders(resourceId: id);
    final uid = InsightFlowAuthService.currentUser?.uid;
    if (uid != null) {
      await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/datasets/register'),
        headers: {...headers, 'Content-Type': 'application/json'},
        body: jsonEncode({
          'workspace_id': insightFlowWorkspaceId,
          'dataset_id': id,
          'owner_uid': uid,
          'protected_original': true,
        }),
      );
    }
  } catch (_) {}
  return id;
}

Future<bool> _checkAuthorization({
  required String backendBaseUrl,
  required String action,
  required String resourceId,
}) async {
  final headers = await firebaseAuthHeaders(resourceId: resourceId);
  final response = await http.post(
    Uri.parse('$backendBaseUrl/v1/authz/check'),
    headers: {...headers, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'workspace_id': insightFlowWorkspaceId,
      'action': action,
      'resource_id': resourceId,
    }),
  );
  return response.statusCode == 200;
}

Future<Map<String, dynamic>?> requestWorkingCopy({
  required String backendBaseUrl,
  required String datasetId,
  String? sourceVersion,
}) async {
  if (insightFlowWorkspaceId.isEmpty || datasetId.trim().isEmpty) return null;
  final headers = await firebaseAuthHeaders(resourceId: datasetId);
  final response = await http.post(
    Uri.parse('$backendBaseUrl/v1/authz/working-copies'),
    headers: {...headers, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'workspace_id': insightFlowWorkspaceId,
      'dataset_id': _safeResourceId(datasetId),
      if (sourceVersion != null)
        'source_version': _safeResourceId(sourceVersion),
    }),
  );
  if (response.statusCode != 200) return null;
  final decoded = jsonDecode(response.body);
  return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
}

Future<bool> authorizeExcelOperation({
  required String backendBaseUrl,
  required String action,
  required String resourceId,
}) async {
  if (insightFlowWorkspaceId.isEmpty) return false;
  final safeResourceId = _safeResourceId(resourceId);

  if (action == 'data.view' ||
      action == 'history.view' ||
      action == 'organization.view') {
    return _checkAuthorization(
      backendBaseUrl: backendBaseUrl,
      action: action,
      resourceId: safeResourceId,
    );
  }

  final datasetId = safeResourceId.startsWith('wc_')
      ? safeResourceId
      : await _resolveDatasetId(resourceId);
  if (datasetId == null) return false;

  if (datasetId.startsWith('wc_')) {
    final allowed = await _checkAuthorization(
      backendBaseUrl: backendBaseUrl,
      action: 'excel.mutate.working_copy',
      resourceId: datasetId,
    );
    if (!allowed) return false;
    final token = await InsightFlowAuthService.getIdToken(forceRefresh: true);
    await setExcelMutationAuthorization(
      idToken: token,
      workspaceId: insightFlowWorkspaceId,
      resourceId: datasetId,
      action: 'excel.mutate.working_copy',
      backendBaseUrl: backendBaseUrl,
    );
    return true;
  }

  final originalAllowed = await _checkAuthorization(
    backendBaseUrl: backendBaseUrl,
    action: 'excel.mutate.original',
    resourceId: datasetId,
  );
  if (originalAllowed) {
    final token = await InsightFlowAuthService.getIdToken(forceRefresh: true);
    await setExcelMutationAuthorization(
      idToken: token,
      workspaceId: insightFlowWorkspaceId,
      resourceId: datasetId,
      action: 'excel.mutate.original',
      backendBaseUrl: backendBaseUrl,
    );
    return true;
  }

  final copy = await requestWorkingCopy(
    backendBaseUrl: backendBaseUrl,
    datasetId: datasetId,
  );
  final workingCopyId = copy?['working_copy_id']?.toString();
  if (workingCopyId == null || workingCopyId.isEmpty) return false;

  final token = await InsightFlowAuthService.getIdToken(forceRefresh: true);
  await setExcelMutationAuthorization(
    idToken: token,
    workspaceId: insightFlowWorkspaceId,
    resourceId: workingCopyId,
    action: 'excel.mutate.working_copy',
    backendBaseUrl: backendBaseUrl,
  );

  final sourceSheet = resourceId;
  final copied = await createWorkbookWorkingCopy(
    sourceSheetName: sourceSheet,
    workingCopyId: workingCopyId,
  );
  final copiedSheet = copied?['sheetName']?.toString();
  if (copiedSheet == null || copiedSheet.isEmpty) return false;

  // createWorkbookWorkingCopy persists the copied worksheet as the analytical source.
  final workingAllowed = await _checkAuthorization(
    backendBaseUrl: backendBaseUrl,
    action: 'excel.mutate.working_copy',
    resourceId: workingCopyId,
  );
  if (!workingAllowed) return false;

  return true;
}

Future<bool> authorizeWorkingCopyExcelMutation({
  required String backendBaseUrl,
  required String workingCopyId,
}) async {
  if (insightFlowWorkspaceId.isEmpty || workingCopyId.trim().isEmpty) {
    return false;
  }
  final safeResourceId = _safeResourceId(workingCopyId);
  final headers = await firebaseAuthHeaders(resourceId: safeResourceId);
  final response = await http.post(
    Uri.parse('$backendBaseUrl/v1/authz/check'),
    headers: {...headers, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'workspace_id': insightFlowWorkspaceId,
      'action': 'excel.mutate.working_copy',
      'resource_id': safeResourceId,
    }),
  );
  if (response.statusCode != 200) {
    return false;
  }
  final token = await InsightFlowAuthService.getIdToken(forceRefresh: true);
  await setExcelMutationAuthorization(
    idToken: token,
    workspaceId: insightFlowWorkspaceId,
    resourceId: safeResourceId,
    action: 'excel.mutate.working_copy',
    backendBaseUrl: backendBaseUrl,
  );
  return true;
}
