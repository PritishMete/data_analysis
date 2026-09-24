import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'insightflow_auth_service.dart';
import '../interop/excel_mutation_authorization.dart';

String insightFlowWorkspaceId = String.fromEnvironment(
  'INSIGHTFLOW_WORKSPACE_ID',
);

Future<void> loadInsightFlowWorkspaceId(String uid) async {
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString('insightflow.workspace.$uid');
  if (stored != null && stored.trim().isNotEmpty) {
    insightFlowWorkspaceId = stored.trim();
  }
}

Future<void> setInsightFlowWorkspaceId(String uid, String workspaceId) async {
  final normalized = workspaceId.trim();
  if (normalized.isEmpty) return;
  insightFlowWorkspaceId = normalized;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('insightflow.workspace.$uid', normalized);
}

Future<void> setDevelopmentOrganizationState({
  required String uid,
  required String organizationName,
  required String workspaceId,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('insightflow.dev.organization.$uid', organizationName.trim());
  await setInsightFlowWorkspaceId(uid, workspaceId);
}

Future<String?> loadDevelopmentOrganizationName(String uid) async {
  final prefs = await SharedPreferences.getInstance();
  final value = prefs.getString('insightflow.dev.organization.$uid');
  return value?.trim().isEmpty == true ? null : value?.trim();
}

class OrganizationServiceDiagnostic {
  OrganizationServiceDiagnostic({String? id}) : id = id ?? _newId();

  final String id;
  String stage = 'REQUEST_STARTED';
  String? method;
  String? path;
  String? backendOrigin;
  int? httpStatus;
  String? safeBodySummary;
  String? errorType;
  String? errorDetail;

  void start({required String method, required String path, required String backendOrigin}) {
    this.method = method;
    this.path = path;
    this.backendOrigin = backendOrigin;
    stage = 'REQUEST_STARTED';
    httpStatus = null;
    safeBodySummary = null;
    errorType = null;
    errorDetail = null;
  }

  String get requestLabel => '${method ?? 'REQUEST'} ${path ?? ''}'.trim();

  String get displayText => [
        'Organization Service Diagnostic',
        '',
        'Backend:',
        backendOrigin ?? 'unknown',
        '',
        'Request:',
        requestLabel,
        '',
        'Status:',
        httpStatus?.toString() ?? (stage == 'REQUEST_STARTED' ? 'waiting' : 'no HTTP response'),
        '',
        'Result:',
        stage,
        if (safeBodySummary != null && safeBodySummary!.isNotEmpty) '',
        if (safeBodySummary != null && safeBodySummary!.isNotEmpty) 'Response: $safeBodySummary',
        '',
        'Attempt:',
        id,
      ].join('\n');

  static String _newId() {
    final value = Random.secure().nextInt(0x10000);
    return 'ORGREQ-${value.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  }
}

class OrganizationServiceResponse {
  const OrganizationServiceResponse(this.response, this.diagnostic);
  final http.Response response;
  final OrganizationServiceDiagnostic diagnostic;
}

class OrganizationServiceRequestException implements Exception {
  const OrganizationServiceRequestException(this.diagnostic, this.cause);
  final OrganizationServiceDiagnostic diagnostic;
  final Object cause;
}

String _safeOrganizationResponseSummary(String body) {
  if (body.trim().isEmpty) return 'empty response';
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map) {
      final safe = <String, String>{};
      for (final key in const ['code', 'authorization_state']) {
        final value = decoded[key];
        if (value != null) safe[key] = value.toString();
      }
      final summary = safe.entries.map((e) => '${e.key}=${e.value}').join('; ');
      if (summary.isNotEmpty) return summary.length > 240 ? summary.substring(0, 240) : summary;
      return 'JSON object response (sensitive fields omitted)';
    }
    return 'JSON response';
  } catch (_) {
    return 'non-JSON response';
  }
}

String _classifyOrganizationHttp(int status) {
  if (status >= 200 && status < 300) return 'HTTP_SUCCESS';
  if (status == 401) return 'HTTP_401';
  if (status == 403) return 'HTTP_403';
  if (status == 404) return 'HTTP_404';
  if (status == 409) return 'HTTP_409';
  if (status == 422) return 'HTTP_422';
  if (status >= 500) return 'HTTP_5XX';
  return 'UNKNOWN_ERROR';
}

Future<OrganizationServiceResponse> organizationServiceRequest({
  required String method,
  required String path,
  required Future<http.Response> Function(Map<String, String> headers) send,
  bool forceRefresh = true,
  String? contentType,
}) async {
  final diagnostic = OrganizationServiceDiagnostic();
  diagnostic.start(method: method, path: path, backendOrigin: insightFlowBackendBaseUrl);
  try {
    final headers = await firebaseAuthHeaders(forceRefresh: forceRefresh);
    if (contentType != null) headers['Content-Type'] = contentType;
    final response = await send(headers).timeout(const Duration(seconds: 15));
    diagnostic.httpStatus = response.statusCode;
    diagnostic.safeBodySummary = _safeOrganizationResponseSummary(response.body);
    diagnostic.stage = _classifyOrganizationHttp(response.statusCode);
    return OrganizationServiceResponse(response, diagnostic);
  } on TimeoutException catch (error) {
    diagnostic.stage = 'TIMEOUT';
    diagnostic.errorType = error.runtimeType.toString();
    throw OrganizationServiceRequestException(diagnostic, error);
  } on Exception catch (error) {
    diagnostic.stage = error.toString().contains('Failed to fetch')
        ? 'NETWORK_OR_CORS'
        : 'NETWORK_ERROR';
    diagnostic.errorType = error.runtimeType.toString();
    diagnostic.errorDetail = error.toString().contains('Failed to fetch')
        ? 'Browser reported Failed to fetch; this may be network or CORS.'
        : 'Browser request failed before an HTTP response was received.';
    throw OrganizationServiceRequestException(diagnostic, error);
  }
}

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
