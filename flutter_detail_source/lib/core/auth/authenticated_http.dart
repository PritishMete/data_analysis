import 'dart:convert';

import 'package:http/http.dart' as http;

import 'insightflow_auth_service.dart';
import '../interop/excel_mutation_authorization.dart';

const String insightFlowWorkspaceId =
    String.fromEnvironment('INSIGHTFLOW_WORKSPACE_ID');
const String insightFlowBackendBaseUrl = String.fromEnvironment(
  'INSIGHTFLOW_BACKEND_URL',
  defaultValue: 'https://data-analysis-oajs.onrender.com',
);

String _safeResourceId(String raw) {
  final normalized =
      raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '_');
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
  final token =
      await InsightFlowAuthService.getIdToken(forceRefresh: forceRefresh);
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
  final token =
      await InsightFlowAuthService.getIdToken(forceRefresh: forceRefresh);
  final headers = <String, String>{
    'Authorization': 'Bearer $token',
  };
  if (insightFlowWorkspaceId.isNotEmpty) {
    headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
  }
  if (resourceId != null && resourceId.trim().isNotEmpty) {
    headers['X-InsightFlow-Resource-ID'] = _safeResourceId(resourceId);
  }
  return headers;
}

String _excelMutationCapability(String action) {
  const readOnly = {'data.view', 'history.view', 'organization.view'};
  return readOnly.contains(action)
      ? action
      : 'excel.mutate.original';
}

Future<Map<String, dynamic>?> requestWorkingCopy({
  required String backendBaseUrl,
  required String datasetId,
  String? sourceVersion,
}) async {
  if (insightFlowWorkspaceId.isEmpty || datasetId.trim().isEmpty) return null;
  final headers = await firebaseAuthHeaders(resourceId: datasetId);
  final response = await http.post(
    Uri.parse('$backendUrl/v1/authz/working-copies'),
    headers: {...headers, 'Content-Type': 'application/json'},
    body: jsonEncode({
      'workspace_id': insightFlowWorkspaceId,
      'dataset_id': _safeResourceId(datasetId),
      if (sourceVersion != null) 'source_version': _safeResourceId(sourceVersion),
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
  if (insightFlowWorkspaceId.isEmpty) {
    return false;
  }
  final safeResourceId = _safeResourceId(resourceId);
  final headers = await firebaseAuthHeaders(resourceId: safeResourceId);
  final response = await http.post(
    Uri.parse('$backendBaseUrl/v1/authz/check'),
    headers: {
      ...headers,
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'workspace_id': insightFlowWorkspaceId,
      'action': action,
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
    action: _excelMutationCapability(action),
    backendBaseUrl: backendBaseUrl,
  );
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
    headers: {
      ...headers,
      'Content-Type': 'application/json',
    },
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
