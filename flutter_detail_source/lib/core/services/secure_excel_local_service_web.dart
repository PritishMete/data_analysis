import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/foundation.dart';

@JS('executeSecureExcelQuery')
external JSPromise<JSString> _executeSecureExcelQuery(JSString optionsJson);

/// Secure Excel operations that execute entirely in the Office taskpane.
/// No worksheet rows are sent to the Python backend or any remote service.
class SecureExcelLocalService {
  static const String baseUrl = 'office-local';

  static bool supportsQuery(String text) {
    final lower = text.trim().toLowerCase();
    final hasCheckVerb = RegExp(r'\b(?:check|inspect|find|show|report|identify)\b').hasMatch(lower);
    final hasMissing = RegExp(r'\b(?:missing|null|blank|empty)\b').hasMatch(lower);
    final hasDuplicate = RegExp(r'\b(?:duplicate|duplicates|duplicated)\b').hasMatch(lower);
    final hasIdentifierReference = RegExp(r'\b(?:restaurant\s*ids?|restaurant[_ ]?identifier|duplicates?\s+[a-z0-9_]+\s+(?:values?|ids?))\b').hasMatch(lower);
    if (hasCheckVerb && (hasMissing || hasDuplicate) && (hasMissing || hasIdentifierReference)) return true;
    final hasCount = RegExp(r'\b(?:count|how many|number of)\b').hasMatch(lower);
    final hasGrouping = RegExp(r'\b(?:each|per|by|group(?:ed)?\s+by)\b').hasMatch(lower);
    return hasCount && hasGrouping;
  }

  static Future<Map<String, dynamic>> execute({
    required List<List<dynamic>> sourceRows,
    required String query,
  }) async {
    if (!kIsWeb) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Secure Excel worksheet operations require the Office web host.',
      };
    }
    if (sourceRows.length < 2 || sourceRows.first.isEmpty) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Dataset is empty or has no header row.',
      };
    }

    try {
      final encoded = jsonEncode({
        'rows': sourceRows,
        'query': query,
      });
      final response = await _executeSecureExcelQuery(encoded.toJS).toDart;
      final decoded = jsonDecode(response.toDart);
      if (decoded is Map<String, dynamic>) return decoded;
      return {
        'success': false,
        'route': 'operation',
        'error': 'Local Excel engine returned an unexpected response.',
      };
    } catch (error) {
      return {
        'success': false,
        'route': 'operation',
        'error': 'Local Excel operation failed: $error',
      };
    }
  }
}
