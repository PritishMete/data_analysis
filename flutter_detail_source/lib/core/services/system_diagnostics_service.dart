import 'dart:convert';

import 'package:http/http.dart' as http;

import 'system_build_id.dart';

class SystemDiagnosticsService {
  SystemDiagnosticsService({http.Client? client, Uri? baseUri})
      : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.parse('http://127.0.0.1:8000');

  final http.Client _client;
  final Uri _baseUri;

  Future<Map<String, dynamic>> check({String? servedBuildId}) async {
    final buildId = servedBuildId ?? detailAnalysisBuildId();
    final uri = _baseUri.resolve('/v1/system/diagnostics').replace(
      queryParameters: buildId.isEmpty ? null : {'detail_analysis_build_id': buildId},
    );
    final response = await _client.get(uri).timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('diagnostics_unavailable');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) throw Exception('diagnostics_invalid');
    return Map<String, dynamic>.from(decoded);
  }

  void dispose() => _client.close();
}
