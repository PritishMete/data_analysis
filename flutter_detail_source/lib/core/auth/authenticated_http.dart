import 'package:http/http.dart' as http;

import 'insightflow_auth_service.dart';

Future<void> attachFirebaseAuth(http.BaseRequest request, {bool forceRefresh = false}) async {
  final token = await InsightFlowAuthService.getIdToken(forceRefresh: forceRefresh);
  request.headers['Authorization'] = 'Bearer $token';
}

Future<Map<String, String>> firebaseAuthHeaders({bool forceRefresh = false}) async {
  final token = await InsightFlowAuthService.getIdToken(forceRefresh: forceRefresh);
  return {'Authorization': 'Bearer $token'};
}
