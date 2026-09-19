// lib/core/services/agentic_command_executor.dart
//
// Calls the /agentic_command backend route (command_agent.py), which uses
// a single ADK LlmAgent to turn a natural-language spreadsheet instruction
// into structured JSON for spreadsheet operations, including categorization.
//
// This is a *parsing* step only — dispatching the parsed action to the
// actual executePipeline()/applyColorScale() JS-interop calls happens in
// data_screen.dart, since that's where the exact options shape those
// functions expect already lives (runTransformationPipeline, etc.).

import 'dart:convert';
import 'package:http/http.dart' as http;
import '../security/outbound_privacy_guard.dart';
import '../security/privacy_mode.dart';
import 'currency_registry.dart';
import 'local_categorization_service.dart';

const String _agenticBackendUrl = "https://data-analysis-oajs.onrender.com";

String _normalize(String value) => value
    .toLowerCase()
    .replaceAll(RegExp(r"['`´‘’‛]"), '')
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

String? _matchColumn(List<String> availableColumns, List<String> candidates) {
  final normalized = <String, String>{
    for (final col in availableColumns) _normalize(col): col,
  };
  for (final candidate in candidates) {
    final wanted = _normalize(candidate);
    final exact = normalized[wanted];
    if (exact != null) return exact;
  }
  // Be tolerant of real-world headers such as "Has Online Delivery?",
  // "Online Delivery Available", or "Provides Table Booking".
  for (final candidate in candidates) {
    final wantedWords = _normalize(candidate).split(' ').where((w) => w.isNotEmpty).toSet();
    if (wantedWords.isEmpty) continue;
    for (final col in availableColumns) {
      final words = _normalize(col).split(' ').where((w) => w.isNotEmpty).toSet();
      if (wantedWords.every(words.contains)) return col;
    }
  }
  return null;
}

bool _looksLikeFilterQuery(String text) {
  final lower = text.toLowerCase();
  return RegExp(r'^(show|find|filter|display|list|give|fetch|view|return)\b').hasMatch(lower) ||
      lower.contains(' having ') ||
      lower.contains(' where ') ||
      lower.contains(' with ');
}

Map<String, dynamic>? _buildLocalFilterPlan(String userText, List<String> availableColumns) {
  if (!_looksLikeFilterQuery(userText) || availableColumns.isEmpty) return null;
  final filters = <Map<String, dynamic>>[];

  final entityMatch = RegExp(
    r'\b(?:show|find|filter|display|list|give|fetch|view|return)\s+(?:me\s+)?(.+?)\s+restaurants?\b',
    caseSensitive: false,
  ).firstMatch(userText);
  final entityColumn = _matchColumn(availableColumns, ['restaurant name', 'restaurant', 'entity name', 'name']);
  if (entityMatch != null && entityColumn != null) {
    final value = entityMatch.group(1)?.trim();
    if (value != null && value.isNotEmpty) {
      filters.add({'column': entityColumn, 'operator': 'contains', 'value': value});
    }
  }

  if (RegExp(r'\b(?:online\s+)?delivery\b', caseSensitive: false).hasMatch(userText)) {
    final column = _matchColumn(availableColumns, ['has online delivery', 'online delivery', 'delivery', 'delivery capability']);
    if (column != null) filters.add({'column': column, 'operator': 'equals', 'value': true});
  }
  if (RegExp(r'\b(?:online\s+)?table\s+(?:booking|reservation)\b', caseSensitive: false).hasMatch(userText)) {
    final column = _matchColumn(availableColumns, ['has table booking', 'online table booking', 'table booking', 'table booking capability']);
    if (column != null) filters.add({'column': column, 'operator': 'equals', 'value': true});
  }

  final ratingMatch = RegExp(
    r'\bratings?\b[^0-9]*(greater\s+than|more\s+than|above|over|less\s+than|below|under|at\s+least|at\s+most|equal\s+to|equals?)\s*(-?\d+(?:[.,]\d+)?)',
    caseSensitive: false,
  ).firstMatch(userText);
  if (ratingMatch != null) {
    final word = ratingMatch.group(1)!.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final operator = switch (word) {
      'less than' || 'below' || 'under' => 'less_than',
      'at least' => 'greater_than_equal',
      'at most' => 'less_than_equal',
      'equal to' || 'equals' => 'equals',
      _ => 'greater_than',
    };
    final column = _matchColumn(availableColumns, ['aggregate rating', 'average rating', 'rating', 'rating score']);
    if (column != null) {
      filters.add({
        'column': column,
        'operator': operator,
        'value': ratingMatch.group(2)!.replaceAll(',', '.'),
      });
    }
  }

  if (filters.isEmpty) return null;
  return {'intent': 'filter', 'logic': 'AND', 'filters': filters};
}

String? _extractTargetCurrency(String userText) => resolveTargetCurrency(userText);

Map<String, List<String>> _buildColumnSamples(
  List<Map<String, dynamic>> rows,
  List<String> columns, {
  int maxSamplesPerColumn = 50,
}) {
  final result = <String, List<String>>{};
  for (final column in columns) {
    final seen = <String>{};
    final values = <String>[];
    for (final row in rows) {
      final raw = row[column];
      final value = raw == null ? '' : raw.toString().trim();
      if (value.isEmpty) continue;
      if (seen.add(value)) {
        values.add(value);
      }
      if (values.length >= maxSamplesPerColumn) break;
    }
    result[column] = values;
  }
  return result;
}

List<List<dynamic>> _applyColumnMappings(
  List<List<dynamic>> matrix,
  Map<String, dynamic> mappings,
) {
  if (matrix.isEmpty || matrix.first.isEmpty || mappings.isEmpty) return matrix;
  final headers = matrix.first.map((e) => e?.toString() ?? '').toList();
  final headerIndex = <String, int>{
    for (var i = 0; i < headers.length; i++) _normalize(headers[i]): i,
  };
  final out = matrix.map((row) => List<dynamic>.from(row)).toList();
  for (final entry in mappings.entries) {
    final idx = headerIndex[_normalize(entry.key)];
    if (idx == null) continue;
    final mapping = entry.value is Map
        ? Map<String, dynamic>.from(entry.value as Map)
        : <String, dynamic>{};
    if (mapping.isEmpty) continue;
    for (var r = 1; r < out.length; r++) {
      if (idx >= out[r].length) continue;
      final raw = out[r][idx];
      final key = raw == null ? '' : raw.toString();
      if (mapping.containsKey(key)) {
        out[r][idx] = mapping[key];
      }
    }
  }
  return out;
}

bool _looksLikeMoneyHeader(String header) {
  return RegExp(
    r'\b(currency|price|amount|cost|fare|salary|revenue|sales|income|budget|fee|charge|value|pay|payment)\b',
    caseSensitive: false,
  ).hasMatch(header);
}

bool _looksLikeCurrencyValue(dynamic value) {
  if (value == null) return false;
  final text = value.toString();
  return RegExp(
    r'(?:[$€£¥₽৳₹]|د\.إ|\b(?:usd|inr|aed|sgd|cad|aud|hkd|rub|bdt|eur|gbp|jpy|cny|rupee|rupees|dollar|dollars|dirham|pound|pounds|taka|rubel|ruble|yuan|yen)\b)',
    caseSensitive: false,
  ).hasMatch(text);
}

List<String> _detectCurrencyColumns(List<List<dynamic>> matrix, List<String> candidateColumns) {
  if (matrix.isEmpty || matrix.first.isEmpty) return const <String>[];
  final headers = matrix.first.map((e) => e?.toString() ?? '').toList();
  final wanted = candidateColumns.isEmpty ? headers : candidateColumns;
  final indices = <int, String>{};
  for (final column in wanted) {
    final idx = headers.indexWhere((h) => _normalize(h) == _normalize(column));
    if (idx >= 0) {
      indices[idx] = headers[idx];
    }
  }
  final out = <String>[];
  for (final entry in indices.entries) {
    final header = entry.value;
    final idx = entry.key;
    final samples = <dynamic>[];
    for (var r = 1; r < matrix.length && samples.length < 25; r++) {
      if (idx < matrix[r].length) {
        final value = matrix[r][idx];
        if (value != null && value.toString().trim().isNotEmpty) {
          samples.add(value);
        }
      }
    }
    final headerLooksMoney = _looksLikeMoneyHeader(header);
    final valueLooksMoney = samples.any(_looksLikeCurrencyValue);
    if (headerLooksMoney || valueLooksMoney) {
      out.add(header);
    }
  }
  return out;
}

Map<String, dynamic>? _buildLocalCategorizationPlan(String userText, List<String> availableColumns) {
  final lower = userText.toLowerCase();
  final categorizeRequested = RegExp(
    r'\b(?:categorize|categorise|classification|classify|categorization|categorisation)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  if (!categorizeRequested) return null;

  final allColumns = RegExp(r'\b(?:all|every)\s+columns?\b|\bcategorize\s+all\b', caseSensitive: false).hasMatch(lower);
  final genericColumnsRequest = RegExp(r'\bcategorize\s+columns?\b|\bclassify\s+columns?\b', caseSensitive: false).hasMatch(lower);
  final targetCurrency = _extractTargetCurrency(userText);

  final normalizedRequest = _normalize(userText);
  final selected = <String>[];
  if (allColumns || genericColumnsRequest) {
    selected.addAll(availableColumns);
  } else {
    for (final column in availableColumns) {
      final normalizedColumn = _normalize(column);
      if (normalizedColumn.isNotEmpty && normalizedRequest.contains(normalizedColumn) && !selected.contains(column)) {
        selected.add(column);
      }
    }
    if (selected.isEmpty && RegExp(r'\b(?:bool|boolean)\s+column\b', caseSensitive: false).hasMatch(lower)) {
      selected.add('__BOOLEAN_COLUMN__');
    }
    if (selected.isEmpty) {
      final moneyHints = RegExp(
        r'(?:currency|amount|price|cost|fare|salary|revenue|sales|income|budget|fee|charge|value)',
        caseSensitive: false,
      );
      for (final column in availableColumns) {
        if (moneyHints.hasMatch(column) && !selected.contains(column)) {
          selected.add(column);
        }
      }
    }
  }

  if (selected.isEmpty && availableColumns.isNotEmpty) {
    selected.addAll(availableColumns);
  }
  final compoundRequest = allColumns || selected.length > 1;
  return {
    'action': 'categorize',
    'confidence': 0.99,
    'message': targetCurrency != null
        ? (allColumns
            ? 'Using the secure local categorization pipeline for all columns and converting monetary values to $targetCurrency.'
            : 'Using the secure local categorization pipeline and converting monetary values to $targetCurrency.')
        : (allColumns
            ? 'Using the secure local categorization pipeline for all columns.'
            : 'Using the secure local categorization pipeline.'),
    'categorize': {
      'sourceColumn': selected.isNotEmpty ? selected.first : null,
      'sourceColumns': selected,
      'allColumns': allColumns || (availableColumns.isNotEmpty && selected.length == availableColumns.length),
      'newColumnName': selected.isNotEmpty ? selected.first : 'Categorized',
      'categories': const <String>[],
      'unmatchedLabel': 'Other',
      if (targetCurrency != null && !compoundRequest) 'targetCurrency': targetCurrency,
    },
  };
}

Map<String, dynamic>? _buildLocalPivotPlan(
  String userText,
  List<String> availableColumns,
) {
  final lower = userText.toLowerCase();
  final explicitPivot = RegExp(r'\bpivot\s*table\b|\bpivottable\b', caseSensitive: false).hasMatch(lower);
  if (!explicitPivot || availableColumns.isEmpty) return null;

  String? findColumn(String hint) {
    final direct = _matchColumn(availableColumns, [hint]);
    if (direct != null) return direct;
    final wanted = _normalize(hint);
    for (final column in availableColumns) {
      final normalized = _normalize(column);
      if (normalized == wanted || normalized == wanted + 's' ||
          (wanted.endsWith('y') && normalized == wanted.substring(0, wanted.length - 1) + 'ies')) {
        return column;
      }
    }
    return null;
  }

  String? rowField;
  final rowMatch = RegExp(
    r'\b(?:top\s+\d+|top|show|display|group(?:ed)?\s+by)\s+([a-z0-9_ ?-]+?)(?:\s+in\s+a\s+pivot|\s+by\s+(?:total|sum|average|avg|mean|max|min|count)|\s*$)',
    caseSensitive: false,
  ).firstMatch(lower);
  if (rowMatch != null) rowField = findColumn(rowMatch.group(1)!.trim());
  rowField ??= availableColumns.firstWhere((column) {
    final firstWord = _normalize(column).split(' ').first;
    return RegExp(r'\b' + RegExp.escape(firstWord) + r's?\b', caseSensitive: false).hasMatch(lower);
  }, orElse: () => '');
  if (rowField.isEmpty) rowField = null;

  String? valueField;
  String operation = 'sum';
  for (final column in availableColumns) {
    if (column == rowField) continue;
    final escaped = RegExp.escape(_normalize(column));
    final measureBefore = RegExp(r'\b(total|sum|average|avg|mean|max|maximum|min|minimum|count|number of)\s+(?:of\s+)?' + escaped + r'\b', caseSensitive: false);
    final measureAfter = RegExp(r'\b' + escaped + r'\s+(?:total|sum|average|avg|mean|max|maximum|min|minimum|count)\b', caseSensitive: false);
    if (measureBefore.hasMatch(lower) || measureAfter.hasMatch(lower)) {
      valueField = column;
      final match = RegExp(r'\b(total|sum|average|avg|mean|max|maximum|min|minimum|count|number of)\s+(?:of\s+)?' + escaped, caseSensitive: false).firstMatch(lower);
      final opWord = match?.group(1)?.toLowerCase();
      operation = switch (opWord) {
        'average' || 'avg' || 'mean' => 'average',
        'max' || 'maximum' => 'max',
        'min' || 'minimum' => 'min',
        'count' || 'number of' => 'count',
        _ => 'sum',
      };
      break;
    }
  }

  if (rowField == null) return null;
  if (valueField == null) {
    return {
      'action': 'pivot', 'confidence': 0.99, 'needsClarification': true,
      'message': 'Which measure should the PivotTable use for the ranking — restaurant count, total cost, or average rating?',
      'pivot': {'rowFields': [rowField], 'valueFields': const <Map<String, String>>[]},
    };
  }
  final topMatch = RegExp(r'\btop\s+(\d+)\b', caseSensitive: false).firstMatch(lower);
  final limit = topMatch == null ? null : int.tryParse(topMatch.group(1)!);
  return {
    'action': 'pivot', 'confidence': 0.99, 'message': 'Using the existing local PivotTable engine.',
    'pivot': {
      'rowFields': [rowField],
      'valueFields': [{'field': valueField, 'op': operation}],
      if (limit != null && limit > 0) 'limit': limit,
      if (lower.contains('top ')) 'sortByValue': 'descending',
    },
  };
}
Future<Map<String, dynamic>> parseAgenticCommand({
  required String userText,
  required List<String> availableColumns,
  required List<String> availableSheets,
}) async {
  final lower = userText.toLowerCase();
  final wantsCategorization = RegExp(
    r'\b(?:categorize|categorise|classification|classify|categorization|categorisation)\b',
    caseSensitive: false,
  ).hasMatch(lower);
  if (secureLocalOnly) {
    if (wantsCategorization) {
      final localCategorization = _buildLocalCategorizationPlan(userText, availableColumns);
      if (localCategorization != null) {
        return localCategorization;
      }
      final wantsAllColumns = RegExp(r'\b(?:all|every)\s+columns?\b', caseSensitive: false).hasMatch(lower);
      final targetCurrency = _extractTargetCurrency(userText);
      return {
        "action": "categorize",
        "confidence": 0.99,
        "message": targetCurrency != null
            ? "Detected a secure-local categorization request and a monetary standardization target."
            : "Detected a secure-local categorization request.",
        "categorize": {
          "sourceColumn": null,
          "sourceColumns": const <String>[],
          "allColumns": wantsAllColumns,
          "newColumnName": "Categorized",
          "categories": const <String>[],
          "unmatchedLabel": "Other",
          if (targetCurrency != null && !wantsAllColumns) "targetCurrency": targetCurrency,
        },
      };
    }
    final localPivot = _buildLocalPivotPlan(userText, availableColumns);
    if (localPivot != null) {
      return localPivot;
    }
    final localCategorization = _buildLocalCategorizationPlan(userText, availableColumns);
    if (localCategorization != null) {
      return localCategorization;
    }
    if (lower.contains('deduplicate') || lower.contains('remove duplicate') || lower.contains('remove duplicates')) {
      return {"action": "deduplicate", "confidence": 0.95, "message": "Detected a local deduplication request."};
    }
    if (lower.contains('create sheet') || lower.contains('new sheet') || lower.contains('blank sheet')) {
      return {"action": "create_sheet", "confidence": 0.95, "message": "Detected a local sheet-creation request."};
    }
    if (lower.contains('copy sheet') || lower.contains('duplicate sheet')) {
      return {"action": "copy_sheet", "confidence": 0.95, "message": "Detected a local sheet-copy request."};
    }
    if (lower.contains('show preview') || lower.contains('preview data')) {
      return {"action": "show_preview", "confidence": 0.95, "message": "Detected a local preview request."};
    }
    if (lower.contains('list sheets')) {
      return {"action": "list_sheets", "confidence": 0.95, "message": "Detected a local sheet listing request."};
    }
    if (lower.contains('generate metrics') || lower.contains('summary sheet')) {
      return {"action": "generate_metrics", "confidence": 0.95, "message": "Detected a local metrics request."};
    }
    if (lower.contains('clean data') || lower.contains('clean the data')) {
      return {"action": "clean_data", "confidence": 0.95, "message": "Detected a local cleaning request."};
    }

    if (_buildLocalFilterPlan(userText, availableColumns) != null) {
      return {"action": "filter", "confidence": 0.92, "message": "Detected a local filter request."};
    }
    // Secure-local mode avoids the backend entirely for requests that can be
    // resolved locally. Remaining requests use the backend as a metadata-only
    // planner, never sending workbook rows or cell values.
  }
  try {
    OutboundPrivacyGuard.validateMetadataOnlyPayload({
      "text": userText,
      "available_columns": availableColumns,
      "available_sheets": availableSheets,
    });
    final res = await http
        .post(
      Uri.parse("$_agenticBackendUrl/agentic_command"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "text": userText,
        "available_columns": availableColumns,
        "available_sheets": availableSheets,
      }),
    )
        .timeout(const Duration(seconds: 30));

    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    // Gemini remains the primary planner. If it is unavailable or cannot
    // classify a categorization request, fall back to a metadata-only local
    // plan rather than routing the request to /smart_query (which would need
    // dataset rows and is forbidden in secure-local mode).
    if (wantsCategorization && (decoded["action"] ?? "unknown").toString() == "unknown") {
      final localCategorization = _buildLocalCategorizationPlan(userText, availableColumns);
      if (localCategorization != null) {
        return localCategorization;
      }
      final wantsAllColumns = RegExp(r'\b(?:all|every)\s+columns?\b', caseSensitive: false).hasMatch(lower);
      final wantsInr = RegExp(r'\b(?:inr|indian\s+rupees?|rupees?)\b|₹', caseSensitive: false).hasMatch(lower);
      return {
        "action": "categorize",
        "confidence": 0.99,
        "message": wantsInr
            ? "Gemini was unavailable; using the secure local categorization fallback and converting monetary values to INR."
            : "Gemini was unavailable; using the secure local categorization fallback.",
        "categorize": {
          "allColumns": wantsAllColumns,
          "sourceColumns": wantsAllColumns ? availableColumns : <String>[],
          if (wantsInr && !wantsAllColumns) "targetCurrency": "INR",
        },
      };
    }
    return decoded;
  } catch (e) {
    if (wantsCategorization) {
      final localCategorization = _buildLocalCategorizationPlan(userText, availableColumns);
      if (localCategorization != null) {
        return localCategorization;
      }
      final wantsAllColumns = RegExp(r'\b(?:all|every)\s+columns?\b', caseSensitive: false).hasMatch(lower);
      final wantsInr = RegExp(r'\b(?:inr|indian\s+rupees?|rupees?)\b|₹', caseSensitive: false).hasMatch(lower);
      return {
        "action": "categorize",
        "confidence": 0.99,
        "message": wantsInr
            ? "Gemini could not be reached; secure local categorization and INR conversion are being used."
            : "Gemini could not be reached; secure local categorization is being used.",
        "categorize": {
          "allColumns": wantsAllColumns,
          "sourceColumns": wantsAllColumns ? availableColumns : <String>[],
          if (wantsInr && !wantsAllColumns) "targetCurrency": "INR",
        },
      };
    }
    return {
      "action": "unknown",
      "confidence": 0.0,
      "message": "⚠️ Could not reach the AI command server: ${e.toString()}",
    };
  }
}

Future<Map<String, dynamic>> parseAgenticFilterPlan({
  required String userText,
  required List<String> availableColumns,
}) async {
  // Gemini is the PRIMARY natural-language filter planner. Even in secure-local
  // mode we deliberately call the metadata-only Gemini endpoint first so phrases
  // such as "delivery and table booking above 3.5 rating" are interpreted
  // semantically instead of being truncated by a partial local regex match.
  // Only the query + column names are sent; workbook rows never leave the device.
  try {
    OutboundPrivacyGuard.validateFilterPlannerPayload(
      text: userText,
      availableColumns: availableColumns,
    );
    final res = await http
        .post(
      Uri.parse("$_agenticBackendUrl/agentic_filter_plan"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "text": userText,
        "available_columns": availableColumns,
      }),
    )
        .timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300 || res.body.trim().isEmpty) {
      final fallback = _buildLocalFilterPlan(userText, availableColumns);
      if (fallback != null) {
        return {"success": true, "plan": fallback, "planner": "local_fallback"};
      }
      return {"success": false, "error": "Filter planner returned HTTP ${res.statusCode}."};
    }
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    if (decoded['success'] == true && decoded['plan'] is Map) {
      return decoded;
    }
    final fallback = _buildLocalFilterPlan(userText, availableColumns);
    if (fallback != null) {
      return {"success": true, "plan": fallback, "planner": "local_fallback"};
    }
    return decoded;
  } catch (e) {
    final fallback = _buildLocalFilterPlan(userText, availableColumns);
    if (fallback != null) {
      return {"success": true, "plan": fallback, "planner": "local_fallback"};
    }
    return {"success": false, "error": "Could not reach the generic filter planner: ${e.toString()}"};
  }
}

Future<Map<String, dynamic>> parseAgenticFilterIntent({required String redactedQuery}) async {
  if (secureLocalOnly) {
    // This endpoint accepts only a redacted query and returns abstract intent;
    // it never receives workbook rows or schema. It is therefore safe to use
    // as a Gemini planning fallback in secure-local mode.
  }
  try {
    OutboundPrivacyGuard.validateMetadataOnlyPayload({"text": redactedQuery});
    final res = await http
        .post(
      Uri.parse("$_agenticBackendUrl/agentic_filter_intent"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"text": redactedQuery}),
    )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      return {"success": false, "error": "Filter intent service returned HTTP ${res.statusCode}."};
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  } catch (_) {
    return {"success": false, "error": "Could not reach the filter intent agent."};
  }
}


Future<Map<String, dynamic>> executeAgenticCategorization({
  required String userText,
  required List<Map<String, dynamic>> rows,
  required Map<String, dynamic> categorize,
}) async {
  if (secureLocalOnly) {
    try {
      final headers = rows.isNotEmpty ? rows.first.keys.toList() : <String>[];
      final matrix = <List<dynamic>>[headers, ...rows.map((r) => headers.map((h) => r[h]).toList())];
      final lowerRequest = userText.toLowerCase();
      final explicitAllColumns = RegExp(r'\b(?:categorize|categorise|classify|classification|categorization|categorisation)\s+(?:all|every)\s+columns?\b|\b(?:all|every)\s+columns?\b', caseSensitive: false).hasMatch(lowerRequest);
      final explicitInr = RegExp(r'\b(?:inr|indian\s+rupees?|rupees?)\b|₹', caseSensitive: false).hasMatch(lowerRequest);
      final effectiveAllColumns = categorize['allColumns'] == true || explicitAllColumns;
      final effectiveTargetCurrency = (categorize['targetCurrency']?.toString().trim().isNotEmpty == true) ? categorize['targetCurrency']?.toString().trim().toUpperCase() : (explicitInr ? 'INR' : null);
      final requestedColumns = (categorize['sourceColumns'] is List)
          ? (categorize['sourceColumns'] as List).map((e) => e.toString()).where((e) => e.trim().isNotEmpty).toList()
          : <String>[(categorize['sourceColumn'] ?? '').toString()].where((e) => e.trim().isNotEmpty).toList();
      final selectedColumns = effectiveAllColumns ? headers : (requestedColumns.isNotEmpty ? requestedColumns : headers);
      final compoundWorkflow = effectiveTargetCurrency != null && (effectiveAllColumns || selectedColumns.length > 1);
      final detectedCurrencyColumns = _detectCurrencyColumns(matrix, headers);
      final categorizationColumns = compoundWorkflow
          ? selectedColumns.where((column) => !detectedCurrencyColumns.any((currencyColumn) => _normalize(currencyColumn) == _normalize(column))).toList()
          : selectedColumns;
      final categorizationUserText = compoundWorkflow
          ? userText
              .replaceFirst(
                RegExp(r'\s+and\s+(?:convert|change|exchange|express)\b.*$', caseSensitive: false),
                '',
              )
              .trim()
          : userText;

      Future<Map<String, dynamic>> runPhase({
        required String phaseUserText,
        required List<List<dynamic>> phaseMatrix,
        required List<String> phaseSourceColumns,
        required bool phaseAllColumns,
        required String? phaseTargetCurrency,
      }) async {
        if (phaseSourceColumns.isEmpty) {
          return {
            'success': true,
            'local': true,
            'localRows': phaseMatrix,
            'diagnostics': <String, dynamic>{
              'ai_used': false,
              'gemini_attempted': false,
              'privacy_mode': 'local_only',
              'raw_data_sent_to_ai': false,
              'values_sent_to_ai': 0,
              'columns_sent_to_ai': 0,
              'metadata_sent_to_ai': false,
              'unique_values_sent_to_ai': false,
              'local_fallback_used': true,
              'categorization_engine': 'local_deterministic',
              'currency_engine': phaseTargetCurrency != null ? 'local_conversion' : 'unused',
              'currency_conversion_requested': phaseTargetCurrency != null,
              'sentiment_requested': false,
              'numeric_binning_requested': false,
              'columns_requested': const <String>[],
            },
            'operation': {
              'action': 'categorize',
              'message': 'No eligible columns were found for this step.',
              'convertedCells': 0,
              'convertedColumns': const <String>[],
              'numberFormats': const <String, String>{},
            },
          };
        }

        if (false && agenticCategorizationEnabled && phaseTargetCurrency == null) {
          final columnSamples = _buildColumnSamples(rows, phaseSourceColumns);
          final response = await http.post(
            Uri.parse("$_agenticBackendUrl/agentic_categorize"),
            headers: {"Content-Type": "application/json"},
            body: jsonEncode({
              "text": phaseUserText,
              "categorize": {
                "sourceColumn": phaseSourceColumns.first,
                "sourceColumns": phaseSourceColumns,
                "allColumns": phaseAllColumns,
                "newColumnName": phaseSourceColumns.first,
                "categories": categorize['categories'] is List ? categorize['categories'] : const <String>[],
                "unmatchedLabel": categorize['unmatchedLabel']?.toString() ?? "Other",
              },
              "columnSamples": columnSamples,
            }),
          ).timeout(const Duration(minutes: 2));
          if (response.body.trim().isNotEmpty) {
            final decoded = jsonDecode(response.body);
            if (decoded is Map && decoded["success"] == true && decoded["operation"] is Map) {
              final operation = Map<String, dynamic>.from(decoded["operation"] as Map);
              final metadata = operation["metadata"] is Map ? Map<String, dynamic>.from(operation["metadata"] as Map) : <String, dynamic>{};
              final diagnostics = <String, dynamic>{
                'ai_used': true,
                'gemini_attempted': true,
                'privacy_mode': 'secure_local_minimal_ai',
                'values_sent_to_ai': columnSamples.values.fold<int>(0, (sum, values) => sum + values.length),
                'columns_sent_to_ai': columnSamples.length,
                'raw_data_sent_to_ai': false,
                'metadata_sent_to_ai': true,
                'unique_values_sent_to_ai': true,
                'local_fallback_used': false,
                'categorization_engine': 'gemini_agentic',
                'currency_engine': 'unused',
                'currency_conversion_requested': false,
                'sentiment_requested': lowerRequest.contains('sentiment') || lowerRequest.contains('satisfaction'),
                'numeric_binning_requested': RegExp(r'\b(low|medium|high|bin|bucket|band|range)\b', caseSensitive: false).hasMatch(lowerRequest),
                'columns_requested': phaseSourceColumns,
              };
              final columnMappings = operation['column_mappings'] is Map
                  ? Map<String, dynamic>.from(operation['column_mappings'] as Map)
                  : (metadata['column_mappings'] is Map ? Map<String, dynamic>.from(metadata['column_mappings'] as Map) : <String, dynamic>{});
              final transformed = _applyColumnMappings(phaseMatrix, columnMappings);
              return {
                'success': true,
                'route': 'operation',
                'local': true,
                'localRows': transformed,
                'diagnostics': diagnostics,
                'operation': {
                  'action': 'categorize',
                  'message': operation['message']?.toString() ?? 'Categorization completed.',
                  'convertedCells': 0,
                  'convertedColumns': const <String>[],
                  'columnMappings': columnMappings,
                  'numberFormats': const <String, String>{},
                },
              };
            }
          }
        }

        final result = await LocalCategorizationService.execute(
          sourceRows: phaseMatrix,
          sourceColumns: phaseSourceColumns,
          allColumns: phaseAllColumns,
          targetCurrency: phaseTargetCurrency,
          userText: phaseUserText,
        );
        return {
          'success': true,
          'route': 'operation',
          'local': true,
          'localRows': result.rows,
          'diagnostics': result.diagnostics,
          'operation': {
            'action': 'categorize',
            'message': result.messages.join('\n'),
            'convertedCells': result.convertedCells,
            'convertedColumns': result.convertedColumns,
            'numberFormats': result.numberFormats,
          },
        };
      }

      if (compoundWorkflow) {
        final categorizationResult = await runPhase(
          phaseUserText: categorizationUserText,
          phaseMatrix: matrix,
          phaseSourceColumns: categorizationColumns,
          phaseAllColumns: false,
          phaseTargetCurrency: null,
        );
        if (categorizationResult['success'] != true || categorizationResult['localRows'] is! List) {
          return {
            'success': false,
            'route': 'operation',
            'operation': {'action': 'categorize', 'message': 'Categorization failed before currency conversion could start.'},
          };
        }

        final categorizedMatrix = (categorizationResult['localRows'] as List)
            .whereType<List>()
            .map((r) => List<dynamic>.from(r))
            .toList();
        final conversionColumns = _detectCurrencyColumns(categorizedMatrix, headers);
        if (conversionColumns.isEmpty) {
          final stepMessage = categorizationResult['operation'] is Map
              ? (categorizationResult['operation']['message']?.toString() ?? 'Categorization completed.')
              : 'Categorization completed.';
          return {
            'success': true,
            'route': 'operation',
            'local': true,
            'localRows': categorizedMatrix,
            'diagnostics': categorizationResult['diagnostics'],
            'operation': {
              'action': 'categorize',
              'message': '$stepMessage\nCurrency conversion was not started because no monetary column was detected.',
              'convertedCells': 0,
              'convertedColumns': const <String>[],
              'numberFormats': const <String, String>{},
            },
          };
        }

        final conversionResult = await runPhase(
          phaseUserText: userText,
          phaseMatrix: categorizedMatrix,
          phaseSourceColumns: conversionColumns,
          phaseAllColumns: false,
          phaseTargetCurrency: effectiveTargetCurrency,
        );
        if (conversionResult['success'] != true || conversionResult['localRows'] is! List) {
          final categorizationMessage = categorizationResult['operation'] is Map
              ? (categorizationResult['operation']['message']?.toString() ?? 'Categorization completed.')
              : 'Categorization completed.';
          return {
            'success': false,
            'route': 'operation',
            'operation': {
              'action': 'categorize',
              'message': '$categorizationMessage\nCurrency conversion failed.',
            },
            'error': '$categorizationMessage Currency conversion failed.',
          };
        }

        final conversionMatrix = (conversionResult['localRows'] as List)
            .whereType<List>()
            .map((r) => List<dynamic>.from(r))
            .toList();
        final categorizationMessage = categorizationResult['operation'] is Map
            ? (categorizationResult['operation']['message']?.toString() ?? 'Categorization completed.')
            : 'Categorization completed.';
        final conversionMessage = conversionResult['operation'] is Map
            ? (conversionResult['operation']['message']?.toString() ?? 'Currency conversion completed.')
            : 'Currency conversion completed.';
        final diagnostics = categorizationResult['diagnostics'] is Map
            ? Map<String, dynamic>.from(categorizationResult['diagnostics'] as Map)
            : <String, dynamic>{};
        diagnostics['currency_conversion_requested'] = true;
        diagnostics['currency_engine'] = 'local_conversion';
        diagnostics['columns_requested'] = selectedColumns;
        final numFormats = conversionResult['operation'] is Map && conversionResult['operation']['numberFormats'] is Map
            ? Map<String, dynamic>.from(conversionResult['operation']['numberFormats'] as Map)
            : <String, dynamic>{};
        final convertedColumns = conversionResult['operation'] is Map && conversionResult['operation']['convertedColumns'] is List
            ? List<String>.from((conversionResult['operation']['convertedColumns'] as List).map((e) => e.toString()))
            : const <String>[];
        final convertedCells = conversionResult['operation'] is Map
            ? (conversionResult['operation']['convertedCells'] is int ? conversionResult['operation']['convertedCells'] as int : 0)
            : 0;
        return {
          'success': true,
          'route': 'operation',
          'local': true,
          'localRows': conversionMatrix,
          'diagnostics': diagnostics,
          'operation': {
            'action': 'categorize',
            'message': '$categorizationMessage\n$conversionMessage',
            'convertedCells': convertedCells,
            'convertedColumns': convertedColumns,
            'numberFormats': numFormats,
          },
        };
      }

      final result = await runPhase(
        phaseUserText: userText,
        phaseMatrix: matrix,
        phaseSourceColumns: requestedColumns,
        phaseAllColumns: effectiveAllColumns,
        phaseTargetCurrency: effectiveTargetCurrency,
      );
      return result;
    } catch (e) {
      return {
        'success': false,
        'route': 'operation',
        'operation': {'action': 'categorize', 'message': 'Local categorization failed: $e'},
      };
    }
  }
  // Remote mode retains the legacy endpoint for explicit remote-processing deployments.
  try {
    final res = await http.post(
      Uri.parse("$_agenticBackendUrl/agentic_categorize"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({"text": userText, "rows": rows, "categorize": categorize}),
    ).timeout(const Duration(minutes: 4));
    if (res.body.trim().isEmpty) return {"success": false, "route": "operation", "operation": {"action": "categorize", "message": "The Categorization Agent returned an empty response."}};
    return jsonDecode(res.body) as Map<String, dynamic>;
  } catch (e) {
    return {"success": false, "route": "operation", "operation": {"action": "categorize", "message": "Could not reach the Categorization Agent: ${e.toString()}"}};
  }
}

Future<String?> suggestAgenticSheetName({
  required String query,
  required String operation,
  Map<String, dynamic>? context,
}) async {
  if (secureLocalOnly) {
    final safe = query
        .replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    final op = operation.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final base = [op, safe].where((e) => e.trim().isNotEmpty).join('_');
    return base.isEmpty ? null : base.substring(0, base.length > 31 ? 31 : base.length);
  }
  try {
    final res = await http.post(
      Uri.parse("$_agenticBackendUrl/agentic_sheet_name"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "query": query,
        "operation": operation,
        "context": context ?? <String, dynamic>{},
      }),
    ).timeout(const Duration(seconds: 20));
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    final body = jsonDecode(res.body);
    final name = body is Map ? body["sheet_name"]?.toString().trim() : null;
    return (name == null || name.isEmpty) ? null : name;
  } catch (_) {
    return null;
  }
}
