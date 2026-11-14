import 'dart:convert';

class OutboundPrivacyGuard {
  static const Set<String> forbiddenKeys = {
    'rows',
    'row_data',
    'data',
    'dataset',
    'dataset_rows',
    'records',
    'values',
    'value',
    'distinct_values',
    'sample',
    'samples',
    'sample_values',
    'column_samples',
    'cells',
    'cell_values',
    'preview',
    'csv',
    'file',
    'file_name',
    'filename',
    'file_bytes',
    'upload',
    'workbook',
    'dataframe',
    'df',
    'raw_data',
    'raw_rows',
    'sheet_data',
    'sheet_name',
    'sheet_names',
    'original_columns',
    'raw_columns',
  };

  static final RegExp _safeAliasPattern = RegExp(r'^(?:column|field|entity)_[0-9]{3}$', caseSensitive: false);

  static void validateMetadataOnlyPayload(Object? payload, {String path = 'payload'}) {
    void scan(dynamic value, String currentPath) {
      if (value is Map) {
        for (final entry in value.entries) {
          final key = entry.key.toString();
          if (forbiddenKeys.contains(key.toLowerCase())) {
            throw StateError('Forbidden outbound workbook content at $currentPath.$key');
          }
          scan(entry.value, '$currentPath.$key');
        }
        return;
      }
      if (value is List) {
        for (var i = 0; i < value.length; i++) {
          scan(value[i], '$currentPath[$i]');
        }
      }
    }

    scan(payload, path);
  }

  static void validateFilterPlannerPayload({
    required String text,
    required List<String> availableColumns,
  }) {
    validateMetadataOnlyPayload({
      'text': text,
      'available_columns': availableColumns,
    });

    if (text.trim().isEmpty) {
      throw StateError('Filter planner text is empty.');
    }
    if (availableColumns.isEmpty) {
      throw StateError('Filter planner requires at least one column.');
    }
  }

  static bool isSafeAlias(String value) => _safeAliasPattern.hasMatch(value.trim());

  static Map<String, String> buildSequentialAliases(
    List<String> values, {
    String prefix = 'entity',
  }) {
    final out = <String, String>{};
    for (var i = 0; i < values.length; i++) {
      out[values[i]] = '${prefix}_${(i + 1).toString().padLeft(3, '0')}';
    }
    return out;
  }

  static String replaceTokens(String input, Map<String, String> replacements) {
    var output = input;
    if (replacements.isEmpty) return output;
    final sources = replacements.keys.toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final source in sources) {
      final replacement = replacements[source] ?? source;
      if (source.trim().isEmpty) continue;
      final pattern = RegExp(r'(?<!\w)' + RegExp.escape(source) + r'(?!\w)', caseSensitive: false);
      output = output.replaceAll(pattern, replacement);
    }
    return output;
  }

  static dynamic remapValues(dynamic value, Map<String, String> reverseMap) {
    if (reverseMap.isEmpty) return value;
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key: remapValues(entry.value, reverseMap),
      };
    }
    if (value is List) {
      return value.map((item) => remapValues(item, reverseMap)).toList();
    }
    if (value is String) {
      return reverseMap[value] ?? value;
    }
    return value;
  }

  static Map<String, dynamic> remapPlanValues(
    Map<String, dynamic> plan,
    Map<String, String> reverseMap,
  ) {
    final mapped = remapValues(plan, reverseMap);
    if (mapped is Map<String, dynamic>) {
      return mapped;
    }
    return jsonDecode(jsonEncode(mapped)) as Map<String, dynamic>;
  }
}
