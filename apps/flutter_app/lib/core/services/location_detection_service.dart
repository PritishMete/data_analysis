import 'dart:convert';
import 'package:http/http.dart' as http;
import '../security/privacy_mode.dart';

const String _locationBackendUrl = "https://data-analysis-oajs.onrender.com";

Future<Map<String, dynamic>> detectMissingLocations({
  required List<String> columns,
  required List<Map<String, dynamic>> rows,
}) async {
  if (secureLocalOnly) {
    return {"success": false, "error": "Remote location detection is disabled in secure local mode."};
  }
  try {
    final response = await http.post(
      Uri.parse("$_locationBackendUrl/location/enrich"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "columns": columns,
        "rows": rows,
        "preview_only": true,
      }),
    ).timeout(const Duration(seconds: 120));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      try {
        final body = jsonDecode(response.body);
        return {"success": false, "error": body["detail"] ?? "Location service failed (${response.statusCode})."};
      } catch (_) {
        return {"success": false, "error": "Location service failed (${response.statusCode})."};
      }
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  } catch (e) {
    return {"success": false, "error": "Could not reach the location agent: $e"};
  }
}
