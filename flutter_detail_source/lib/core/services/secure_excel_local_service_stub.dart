/// Non-web implementation. Excel secure query execution is provided by the
/// web implementation because it must operate on the live Office worksheet.
class SecureExcelLocalService {
  static const String baseUrl = 'http://127.0.0.1:8000';

  static bool supportsQuery(String text) {
    final lower = text.trim().toLowerCase();
    final hasCheckVerb = RegExp(r'\b(?:check|inspect|find|show|report|identify)\b').hasMatch(lower);
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
    return {
      'success': false,
      'route': 'operation',
      'error': 'Secure Excel worksheet operations are available only in the Office web host.',
    };
  }
}
