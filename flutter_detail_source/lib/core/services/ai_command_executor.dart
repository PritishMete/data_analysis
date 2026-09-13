// lib/core/services/ai_command_executor.dart
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../interop/excel_interop.dart';
import '../security/privacy_mode.dart';

const String _backendUrl = "https://data-analysis-oajs.onrender.com";

Future<Map<String, dynamic>> executeNaturalCommand({
  required String userText,
  required List<String> availableColumns,
  required List<String> availableSheets,
}) async {
  if (secureLocalOnly) {
    final lower = userText.toLowerCase();
    if (lower.contains('create a new sheet') || lower.contains('create sheet') || lower.contains('blank sheet')) {
      return {
        "success": true,
        "intent": "create_sheet",
        "confidence": 0.95,
        "slots": {"sheet_name": "New_Sheet"},
        "message": "Local secure mode recognized a sheet-creation request.",
      };
    }
    if (lower.contains('copy sheet') || lower.contains('duplicate sheet')) {
      return {
        "success": true,
        "intent": "copy_sheet",
        "confidence": 0.95,
        "slots": {"sheet_name": "Copy_Sheet"},
        "message": "Local secure mode recognized a sheet-copy request.",
      };
    }
    if (lower.contains('list sheets')) {
      return {
        "success": true,
        "intent": "list_sheets",
        "confidence": 0.95,
        "slots": const <String, dynamic>{},
        "message": "Local secure mode recognized a sheet-list request.",
      };
    }
    if (lower.contains('show preview') || lower.contains('preview data')) {
      return {
        "success": true,
        "intent": "show_preview",
        "confidence": 0.95,
        "slots": const <String, dynamic>{},
        "message": "Local secure mode recognized a preview request.",
      };
    }
    return {
      "success": false,
      "message": "Remote AI is disabled in secure local mode.",
      "error": "SECURE_LOCAL_ONLY",
    };
  }
  Map<String, dynamic> parsed;
  try {
    final res = await http.post(
      Uri.parse("$_backendUrl/parse_command"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "text": userText,
        "available_columns": availableColumns,
      }),
    ).timeout(const Duration(seconds: 10));

    parsed = jsonDecode(res.body) as Map<String, dynamic>;
  } catch (e) {
    return {
      "success": false,
      "message": "⚠️ Could not reach AI server. Check your connection.",
      "error": e.toString(),
    };
  }

  final String intent    = parsed["intent"]     ?? "unknown";
  final double confidence = (parsed["confidence"] ?? 0.0).toDouble();
  final Map<String, dynamic> slots = Map<String, dynamic>.from(parsed["slots"] ?? {});

  if (confidence < 0.40) {
    return {
      "success":    false,
      "intent":     intent,
      "confidence": confidence,
      "slots":      slots,
      "message":    "🤔 I'm not sure what you mean (confidence: ${(confidence * 100).toStringAsFixed(0)}%). "
          "Try rephrasing — e.g. 'create a new sheet' or 'filter where status equals active'.",
    };
  }

  final options = _intentToOptions(
    intent:           intent,
    slots:            slots,
    availableColumns: availableColumns,
    availableSheets:  availableSheets,
  );

  if (options == null) {
    return {
      "success": false,
      "intent":  intent,
      "slots":   slots,
      "message": "⚠️ Intent '$intent' is recognized but not yet wired to an action.",
    };
  }

  Map<String, dynamic> result;
  try {
    result = await executePipeline(jsonEncode(options));
  } catch (e) {
    result = {"success": false, "error": e.toString(), "processedRows": 0};
  }

  final bool success = result["success"] == true;

  _logResult(
    text:       userText,
    intent:     intent,
    slots:      slots,
    result:     result,
    success:    success,
    confidence: confidence,
  );

  final String message = _buildMessage(
    intent:  intent,
    slots:   slots,
    result:  result,
    success: success,
  );

  return {
    "success":       success,
    "message":       message,
    "intent":        intent,
    "confidence":    confidence,
    "slots":         slots,
    "processedRows": result["processedRows"] ?? 0,
    "error":         result["error"],
  };
}

Map<String, dynamic>? _intentToOptions({
  required String intent,
  required Map<String, dynamic> slots,
  required List<String> availableColumns,
  required List<String> availableSheets,
}) {
  final String? sheetName   = slots["sheet_name"] as String?;
  final String? column      = slots["column"]     as String?;
  final String? filterType  = slots["filter_type"] as String?;
  final String? value       = slots["value"]?.toString();
  final String? value2      = slots["value2"]?.toString();

  switch (intent) {
    case "create_sheet":
    // FIX: this used to default sourceSheetName to availableSheets.first,
    // which meant "create a new sheet" / "create a blank sheet" silently
    // copied the first existing sheet's data into the new one — same
    // behaviour as "copy_sheet" below. A genuinely blank/new sheet should
    // not carry over any source data, so sourceSheetName is now null.
      return {
        "sourceSheetName":     null,
        "targetSheetName":     sheetName,
        "createNewSheet":      true,
        "generateSummarySheet": false,
        "removeDuplicates":    false,
        "filter":              null,
      };

    case "create_sheet_with_aggregation":
      return {
        "sourceSheetName":     null,
        "targetSheetName":     sheetName ?? "AI_Summary",
        "createNewSheet":      true,
        "generateSummarySheet": true,
        "removeDuplicates":    false,
        "filter":              null,
      };

    case "aggregate":
      return {
        "sourceSheetName":     null,
        "targetSheetName":     "Aggregation_${column ?? 'Result'}",
        "createNewSheet":      true,
        "generateSummarySheet": true,
        "removeDuplicates":    false,
        "filter":              null,
      };

    case "deduplicate":
    case "clean_data":
      return {
        "sourceSheetName":     null,
        "targetSheetName":     "Cleaned_Data",
        "createNewSheet":      true,
        "generateSummarySheet": false,
        "removeDuplicates":    true,
        "filter":              null,
      };

    case "filter":
      String resolvedFilterType = filterType ?? "equals";
      const topSynonyms    = ["top_n",    "most_expensive", "highest", "top",    "max", "largest",  "biggest"];
      const bottomSynonyms = ["bottom_n", "least_expensive","cheapest","lowest", "bottom", "min", "smallest"];
      if (topSynonyms.contains(resolvedFilterType)) {
        resolvedFilterType = "top_n";
      } else if (bottomSynonyms.contains(resolvedFilterType)) {
        resolvedFilterType = "bottom_n";
      }

      String filterSheetName = "Filtered_Result";
      if (resolvedFilterType == "top_n") {
        filterSheetName = "Top_${value ?? '10'}_${column ?? 'Result'}";
      } else if (resolvedFilterType == "bottom_n") {
        filterSheetName = "Bottom_${value ?? '10'}_${column ?? 'Result'}";
      }

      return {
        "sourceSheetName":     null,
        "targetSheetName":     filterSheetName,
        "createNewSheet":      true,
        "generateSummarySheet": false,
        "removeDuplicates":    false,
        "filter": {
          "columnName": column ?? (availableColumns.isNotEmpty ? availableColumns.first : ""),
          "type":       resolvedFilterType,
          "value":      value ?? "10",
          "value2":     value2 ?? "",
        },
      };

    case "generate_metrics":
      return {
        "sourceSheetName":     null,
        "targetSheetName":     null,
        "createNewSheet":      false,
        "generateSummarySheet": true,
        "removeDuplicates":    false,
        "filter":              null,
      };

    case "copy_sheet":
      return {
        "sourceSheetName":     availableSheets.isNotEmpty ? availableSheets.first : null,
        "targetSheetName":     sheetName ?? "Copy_${DateTime.now().millisecondsSinceEpoch % 10000}",
        "createNewSheet":      true,
        "generateSummarySheet": false,
        "removeDuplicates":    false,
        "filter":              null,
      };

    case "show_preview":
    case "list_sheets":
      return {"ui_only": true, "intent": intent};

    default:
      return null;
  }
}

String _buildMessage({
  required String intent,
  required Map<String, dynamic> slots,
  required Map<String, dynamic> result,
  required bool success,
}) {
  if (!success) {
    final err = result["error"]?.toString() ?? "Unknown error";
    return "❌ Failed: $err";
  }

  final col   = slots["column"] as String?;
  final sheet = slots["sheet_name"] as String?;
  final rows  = result["processedRows"] as int? ?? 0;

  switch (intent) {
    case "create_sheet":
      return "✅ New sheet '${sheet ?? 'Cleaned_Data'}' created successfully.";
    case "create_sheet_with_aggregation":
      return "✅ Created sheet '${sheet ?? 'AI_Summary'}' with metrics for ${col ?? 'all columns'} ($rows rows).";
    case "aggregate":
      return "✅ Aggregation complete for column '${col ?? 'data'}' — check Aggregation sheet.";
    case "deduplicate":
    case "clean_data":
      return "✅ Duplicates removed. $rows unique rows written to 'Cleaned_Data'.";
    case "filter":
      final filterType2 = slots["filter_type"] as String? ?? "";
      const topMsgs    = ["top_n",    "most_expensive", "highest", "top",    "max", "largest",  "biggest"];
      const bottomMsgs = ["bottom_n", "least_expensive","cheapest","lowest", "bottom", "min", "smallest"];
      if (topMsgs.contains(filterType2)) {
        return "✅ Top ${slots['value'] ?? '10'} rows by '${col ?? 'column'}' written to sheet (sorted highest → lowest).";
      } else if (bottomMsgs.contains(filterType2)) {
        return "✅ Bottom ${slots['value'] ?? '10'} rows by '${col ?? 'column'}' written to sheet (sorted lowest → highest).";
      }
      return "✅ Filter applied — $rows rows match your criteria. See 'Filtered_Result' sheet.";
    case "generate_metrics":
      return "✅ Metrics_Analysis sheet created with stats for all columns.";
    case "copy_sheet":
      return "✅ Sheet copied to '${sheet ?? 'Copy'}' successfully.";
    default:
      return "✅ Done — $rows rows processed.";
  }
}

void _logResult({
  required String text,
  required String intent,
  required Map<String, dynamic> slots,
  required Map<String, dynamic> result,
  required bool success,
  required double confidence,
}) {
  unawaited(http.post(
    Uri.parse("$_backendUrl/log_result"),
    headers: {"Content-Type": "application/json"},
    body: jsonEncode({
      "text": text,
      "intent": intent,
      "slots": slots,
      "result": result,
      "success": success,
      "confidence": confidence,
    }),
  ));
}

Future<bool> submitCorrection({
  required String text,
  required String wrongIntent,
  required String correctIntent,
  Map<String, dynamic>? slots,
}) async {
  try {
    final res = await http.post(
      Uri.parse("$_backendUrl/add_training"),
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "text":           text,
        "wrong_intent":   wrongIntent,
        "correct_intent": correctIntent,
        "slots":          slots ?? {},
      }),
    );
    return res.statusCode == 200;
  } catch (_) {
    return false;
  }
}
