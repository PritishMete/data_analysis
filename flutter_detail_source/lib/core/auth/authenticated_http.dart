import 'package:http/http.dart' as http;

import 'insightflow_auth_service.dart';

const String insightFlowWorkspaceId =
    String.fromEnvironment('INSIGHTFLOW_WORKSPACE_ID');

String _safeResourceId(String raw) {
  final normalized = raw.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.:-]'), '_');
  final value = normalized.replaceAll(RegExp(r'_+'), '_');
  return value.isEmpty ? 'active-sheet' : value.substring(0, value.length > 128 ? 128 : value.length);
}

Future<void> attachFirebaseAuth(
  http.BaseRequest request, {
  String? resourceId,
  bool forceRefresh = false,
}) async {
  final token = await InsightFlowAuthService.getIdToken(forceRefresh: forceRefresh);
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
  final token = await InsightFlowAuthService.getIdToken(forceRefresh: forceRefresh);
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


import 'dart:convert';

import 'package:http/http.dart' as http;

Future<bool> authorizeExcelOperation({
  required String backendBaseUrl,
  required String action,
  required String resourceId,
}) async {
  if (insightFlowWorkspaceId.isEmpty) {
    return false;
  }
  final headers = await firebaseAuthHeaders(resourceId: resourceId);
  final response = await http.post(
    Uri.parse('$backendBaseUrl/v1/authz/check'),
    headers: {
      ...headers,
      'Content-Type': 'application/json',
    },
    body: jsonEncode({
      'workspace_id': insightFlowWorkspaceId,
      'action': action,
      'resource_id': _safeResourceId(resourceId),
    }),
  );
  return response.statusCode == 200;
}
