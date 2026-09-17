import 'dart:convert';

import 'package:http/http.dart' as http;

/// Client for the secure Excel analysis endpoints served by the local
/// InsightFlow backend. The endpoint performs parsing/semantic resolution and
/// executes the existing read-only/group operations; it does not call remote
/// AI. Keeping this URL loopback-only is important: secure-local mode must
/// never send workbook rows to the hosted Render analytics endpoint.
class SecureExcelLocalService {
  static const String baseUrl = 'http://127.0.0.1:8000';
  static const Duration timeout = Duration(seconds: 30);

  static bool supportsQuery(String text) {
    final lower = text.trim().toLowerCase();
    final hasCheckVerb = RegExp(
      r'\b(?:check|inspect|find|show|report|identify)\b',
    ).hasMatch(lower);
    final hasMissing = RegExp(r'\b(?:missing|null|blank|empty)\b').hasMatch(lower);
    final hasDuplicate = RegExp(r'\b(?:duplicate|duplicates|duplicated)\b').hasMatch(lower);
    if (hasCheckVerb && hasMissing && hasDuplicate) return true;

    final hasCount = RegExp(r'\b(?:count|how many|number of)\b').hasMatch(lower);
    final hasGrouping = RegExp(r'\b(?:each|per|by|group(?:ed)?\s+by)\b').hasMatch(lower);
    return hasCount && hasGrouping;
  }

  static Future<Map<String, dynamic>> execute({
    required List<List<dynamic>> sourceRows,
    required String query,
  }) async {
    if (sourceRows.length < 2 || sourceRows.first.isEmpty) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Dataset is empty or has no header row.',
      };
    }

    final csv = sourceRows
        .map((row) => row.map(_escapeCsvValue).join(','))
        .join('\n');

    final sessionRequest = http.MultipartRequest(
      'POST',
      Uri.parse('$baseUrl/excel/session'),
    )
      ..fields['sheet_name'] = 'Data'
      ..files.add(
        http.MultipartFile.fromString(
          'file',
          csv,
          filename: 'data_source.csv',
        ),
      );

    final sessionResponse = await sessionRequest.send().timeout(timeout);
    final sessionBody = await sessionResponse.stream.bytesToString();
    final session = _decode(sessionBody, sessionResponse.statusCode);
    if (session['success'] == false) return session;

    final sessionId = session['session_id']?.toString();
    if (sessionId == null || sessionId.isEmpty) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Local secure Excel backend did not return a session id.',
      };
    }

    final queryResponse = await http.post(
      Uri.parse('$baseUrl/excel/query'),
      body: {
        'session_id': sessionId,
        'text': query,
      },
    ).timeout(timeout);
    final result = _decode(queryResponse.body, queryResponse.statusCode);
    if (result['success'] == false || result['error'] != null) {
      return {
        ...result,
        'route': 'operation',
      };
    }

    final operation = result['operation']?.toString() ??
        (result['query'] is Map
            ? (result['query'] as Map)['operation']?.toString()
            : null) ??
        'unknown';
    final payload = result['result'] is Map
        ? Map<String, dynamic>.from(result['result'] as Map)
        : <String, dynamic>{};

    return {
      'success': true,
      'route': 'operation',
      'operation': {
        'action': operation,
        ...payload,
      },
      'message': result['message'] ?? _defaultMessage(operation, payload),
      'local_secure': true,
      'source_mutated': operation == 'quality_check'
          ? payload['source_mutated'] == true
              ? true
              : false
          : null,
    };
  }

  static Map<String, dynamic> _decode(String body, int statusCode) {
    if (body.trim().isEmpty) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Local secure Excel backend returned an empty response (HTTP $statusCode).',
      };
    }
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {
        'success': false,
        'route': 'operation',
        'error': 'Local secure Excel backend returned an unexpected response.',
      };
    } catch (_) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Local secure Excel backend returned invalid JSON (HTTP $statusCode).',
      };
    }
  }

  static String _escapeCsvValue(dynamic value) {
    final text = value?.toString() ?? '';
    if (!RegExp(r'''[",\n\r]''').hasMatch(text)) return text;
    return '"${text.replaceAll('"', '""')}"';
  }

  static String _defaultMessage(String operation, Map<String, dynamic> payload) {
    if (operation == 'quality_check') {
      return 'Completed the read-only data quality check locally.';
    }
    if (operation == 'group') {
      final rows = payload['rows'] is List ? (payload['rows'] as List).length : 0;
      return 'Counted records by the requested group locally ($rows groups).';
    }
    return 'Completed the requested analysis locally.';
  }
}
