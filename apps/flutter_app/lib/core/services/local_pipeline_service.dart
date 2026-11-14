import 'dart:convert';

/// A browser-safe transformation engine for uploaded datasets.
///
/// This deliberately contains no HTTP, Office.js, or cloud-AI dependency.
/// It is used when secureLocalOnly is enabled and the source is a locally
/// uploaded CSV/JSON/XLSX dataset.
class LocalPipelineResult {
  final bool success;
  final List<List<dynamic>> rows;
  final int processedRows;
  final String targetName;
  final String? error;

  const LocalPipelineResult({
    required this.success,
    required this.rows,
    required this.processedRows,
    required this.targetName,
    this.error,
  });
}

LocalPipelineResult executeLocalPipeline({
  required List<List<dynamic>> sourceRows,
  required Map<String, dynamic> options,
}) {
  if (sourceRows.length < 2 || sourceRows.first.isEmpty) {
    return const LocalPipelineResult(
      success: false,
      rows: [],
      processedRows: 0,
      targetName: 'Pipeline_Result',
      error: 'Dataset is empty or has no header row.',
    );
  }

  final headers = sourceRows.first.map((e) => e?.toString() ?? '').toList();
  var data = sourceRows.skip(1).map((r) => List<dynamic>.from(r)).toList();
  for (final row in data) {
    while (row.length < headers.length) row.add('');
    if (row.length > headers.length) row.removeRange(headers.length, row.length);
  }

  final filter = options['filter'];
  if (filter is Map && filter.isNotEmpty) {
    final column = filter['columnName']?.toString();
    final type = filter['type']?.toString() ?? 'equals';
    final index = column == null ? -1 : headers.indexWhere((h) => h == column);
    if (index < 0) {
      return LocalPipelineResult(
        success: false, rows: sourceRows, processedRows: data.length,
        targetName: _targetName(options), error: 'Filter column "$column" was not found.',
      );
    }
    final value1 = filter['value']?.toString() ?? '';
    final value2 = filter['value2']?.toString() ?? '';
    data = _applyFilter(data, index, type, value1, value2);
  }

  if (options['removeDuplicates'] == true) {
    final rawColumns = options['deduplicateColumns'];
    final indexes = <int>[];
    if (rawColumns is List && rawColumns.isNotEmpty) {
      for (final c in rawColumns) {
        final i = headers.indexWhere((h) => h == c.toString());
        if (i >= 0) indexes.add(i);
      }
    }
    final keys = indexes.isEmpty ? List<int>.generate(headers.length, (i) => i) : indexes;
    final seen = <String>{};
    data = data.where((row) {
      final key = jsonEncode(keys.map((i) => _normal(row[i])).toList());
      return seen.add(key);
    }).toList();
  }

  return LocalPipelineResult(
    success: true,
    rows: [headers, ...data],
    processedRows: data.length,
    targetName: _targetName(options),
  );
}

List<List<dynamic>> _applyFilter(
    List<List<dynamic>> rows, int index, String type, String value1, String value2) {
  final numericValue1 = double.tryParse(value1.replaceAll(',', '.'));
  final numericValue2 = double.tryParse(value2.replaceAll(',', '.'));

  double? average;
  if (type == 'above_average' || type == 'below_average') {
    final nums = rows.map((r) => _number(r[index])).whereType<double>().toList();
    if (nums.isNotEmpty) average = nums.reduce((a, b) => a + b) / nums.length;
  }

  int? topN;
  if (type == 'top_n' || type == 'bottom_n') {
    topN = int.tryParse(value1.trim()) ?? 10;
    if (topN < 1) topN = 1;
  }

  if (topN != null) {
    final ranked = rows.asMap().entries.toList();
    ranked.sort((a, b) {
      final av = _number(a.value[index]);
      final bv = _number(b.value[index]);
      if (av == null && bv == null) return 0;
      if (av == null) return 1;
      if (bv == null) return -1;
      final cmp = av.compareTo(bv);
      return type == 'top_n' ? -cmp : cmp;
    });
    final keep = ranked.take(topN).map((e) => e.key).toSet();
    return [for (var i = 0; i < rows.length; i++) if (keep.contains(i)) rows[i]];
  }

  return rows.where((row) {
    final raw = row[index];
    final text = _normal(raw);
    final num = _number(raw);
    switch (type) {
      case 'equals':
        return _equal(raw, value1);
      case 'not_equals':
        return !_equal(raw, value1);
      case 'contains':
        return text.toLowerCase().contains(value1.toLowerCase());
      case 'greater_than':
        return _compare(num, numericValue1, (a, b) => a > b);
      case 'less_than':
        return _compare(num, numericValue1, (a, b) => a < b);
      case 'greater_than_equal':
        return _compare(num, numericValue1, (a, b) => a >= b);
      case 'less_than_equal':
        return _compare(num, numericValue1, (a, b) => a <= b);
      case 'between':
        return num != null && numericValue1 != null && numericValue2 != null && num >= numericValue1 && num <= numericValue2;
      case 'above_average':
        return num != null && average != null && num > average;
      case 'below_average':
        return num != null && average != null && num < average;
      default:
        return true;
    }
  }).toList();
}

bool _compare(double? a, double? b, bool Function(double, double) op) =>
    a != null && b != null && op(a, b);

bool _equal(dynamic raw, String target) {
  // Boolean-style filters are common in restaurant datasets. A user saying
  // "having online delivery" means the capability is present, even when
  // the source stores it as Yes/True/Available/1 instead of a Dart boolean.
  final wanted = target.trim().toLowerCase();
  final text = _normal(raw).toLowerCase();
  if (wanted == 'true' || wanted == 'false') {
    final isTrue = const {
      'true', 'yes', 'y', '1', 'available', 'enabled', 'active',
      'present', 'provided', 'supported', 'online', 'available yes'
    }.contains(text);
    final isFalse = const {
      'false', 'no', 'n', '0', 'unavailable', 'disabled', 'inactive',
      'absent', 'not available', 'not provided', 'not supported', 'offline'
    }.contains(text);
    if (isTrue || isFalse) return wanted == 'true' ? isTrue : isFalse;
    if (raw is bool) return wanted == 'true' ? raw : !raw;
  }
  final n = _number(raw);
  final t = double.tryParse(target.replaceAll(',', '.'));
  if (n != null && t != null) return n == t;
  return text == wanted;
}

double? _number(dynamic value) {
  if (value is num) return value.toDouble();
  final s = _normal(value).replaceAll(',', '');
  return double.tryParse(s);
}

String _normal(dynamic value) => (value ?? '').toString().trim();

String _targetName(Map<String, dynamic> options) {
  final value = options['targetSheetName']?.toString().trim();
  if (value != null && value.isNotEmpty) return _safeName(value);
  return 'Pipeline_Result';
}

String _safeName(String value) {
  final cleaned = value.replaceAll(RegExp(r'[\\/?*\[\]:]+'), '_').replaceAll(RegExp(r'\s+'), '_');
  return cleaned.isEmpty ? 'Pipeline_Result' : cleaned.substring(0, cleaned.length > 31 ? 31 : cleaned.length);
}
