// lib/core/services/data_cleaning_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../interop/excel_interop.dart';
import '../security/privacy_mode.dart';

const String _backendUrl = "https://data-analysis-oajs.onrender.com";

class CleaningConfig {
  final bool standardizeCols;
  final bool removeDuplicates;
  final bool removeEmptyRows;
  final bool handleMissingValues;
  final String nullStrategy; // 'smart', 'mean', 'median', 'mode', 'forward_fill', 'drop'
  final bool normalizeText;
  final bool inferTypes;
  final bool handleOutliers;
  final String outlierMethod; // 'cap', 'remove', 'mark'
  final String outputSheetName;
  final List<Map<String, dynamic>>? steps; // optional ordered ops, e.g.
  // [{"op":"standardize_columns"},
  //  {"op":"filter_rows","column":"rating","operator":"not_equals","value":0},
  //  {"op":"handle_missing_values","strategy":"smart","columns":["rating"]},
  //  {"op":"remove_duplicates","subset":["id"]}]
  // When provided, backend runs these in order instead of the fixed pipeline.

  CleaningConfig({
    this.standardizeCols = true,
    this.removeDuplicates = true,
    this.removeEmptyRows = true,
    this.handleMissingValues = true,
    this.nullStrategy = "smart",
    this.normalizeText = true,
    this.inferTypes = true,
    this.handleOutliers = false,
    this.outlierMethod = "cap",
    this.outputSheetName = "Cleaned_Data",
    this.steps,
  });

  Map<String, dynamic> toJson() => {
    if (steps != null) "steps": steps,
    "standardize_cols": standardizeCols,
    "remove_duplicates": removeDuplicates,
    "remove_empty_rows": removeEmptyRows,
    "handle_missing_values": handleMissingValues,
    "null_strategy": nullStrategy,
    "normalize_text": normalizeText,
    "infer_types": inferTypes,
    "handle_outliers": handleOutliers,
    "outlier_method": outlierMethod,
    "output_sheet_name": outputSheetName,
  };
}

class CleaningResult {
  final bool success;
  final String message;
  final Map<String, dynamic> before;
  final Map<String, dynamic> after;
  final Map<String, dynamic> comparison;
  final Map<String, dynamic> cleaningReport;
  final Map<String, dynamic> export;
  final String? error;

  CleaningResult({
    required this.success,
    required this.message,
    required this.before,
    required this.after,
    required this.comparison,
    required this.cleaningReport,
    required this.export,
    this.error,
  });

  factory CleaningResult.fromJson(Map<String, dynamic> json) {
    return CleaningResult(
      success: json['success'] ?? false,
      message: json['summary'] ?? json['message'] ?? '',
      before: json['before'] ?? {},
      after: json['after'] ?? {},
      comparison: json['comparison'] ?? {},
      cleaningReport: json['cleaning_report'] ?? {},
      export: json['export'] ?? {},
      error: json['error'],
    );
  }

  String getComparisonSummary() {
    final rowsRemoved = comparison['rows_removed'] ?? 0;
    final cellsFilled = cleaningReport['cells_filled'] ?? 0;
    final duplicatesRemoved = comparison['total_duplicates_before'] ?? 0;

    return "📊 Comparison:\n"
        "  • Rows removed: $rowsRemoved\n"
        "  • Duplicates cleaned: $duplicatesRemoved\n"
        "  • Missing values filled: $cellsFilled\n"
        "  • Original: ${before['rows']} rows\n"
        "  • Cleaned: ${after['rows']} rows";
  }
}

class DataCleaningService {
  /// Calls the backend /clean_data endpoint with the given file and configuration
  static Future<CleaningResult> cleanData({
    required List<int> fileBytes,
    required String fileName,
    CleaningConfig? config,
  }) async {
    if (secureLocalOnly) {
      return CleaningResult(
        success: false,
        message: "Remote data cleaning is disabled in secure local mode.",
        before: {}, after: {}, comparison: {}, cleaningReport: {}, export: {},
        error: "SECURE_LOCAL_ONLY",
      );
    }
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse("$_backendUrl/clean_data"),
      );

      // Add file
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          fileBytes,
          filename: fileName,
        ),
      );

      // Add config as JSON string
      request.fields['config'] = jsonEncode(
        (config ?? CleaningConfig()).toJson(),
      );

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return CleaningResult.fromJson(json);
      } else {
        return CleaningResult(
          success: false,
          message: "Server error: ${response.statusCode}",
          before: {},
          after: {},
          comparison: {},
          cleaningReport: {},
          export: {},
          error: response.body,
        );
      }
    } catch (e) {
      return CleaningResult(
        success: false,
        message: "⚠️ Could not reach AI server. Check your connection.",
        before: {},
        after: {},
        comparison: {},
        cleaningReport: {},
        export: {},
        error: e.toString(),
      );
    }
  }

  /// Writes the cleaned data to a new Excel sheet using the Excel interop
  static Future<Map<String, dynamic>> writeCleanedDataToSheet(
      CleaningResult result,
      ) async {
    if (!result.success || result.export.isEmpty) {
      return {
        "success": false,
        "error": "No cleaned data to write",
      };
    }

    try {
      final sheetName = result.export['sheet_name'] ?? 'Cleaned_Data';
      final columns = List<String>.from(result.export['columns'] ?? []);
      final rows = List<Map<String, dynamic>>.from(result.export['rows'] ?? []);

      final optionsJson = jsonEncode({
        "targetSheetName": sheetName,
        "columns": columns,
        "rows": rows,
      });

      final response = await writeQueryResultToSheet(optionsJson);
      return response;
    } catch (e) {
      return {
        "success": false,
        "error": e.toString(),
      };
    }
  }

  /// Full workflow: clean data and write to sheet
  static Future<String> executeCleaningWorkflow({
    required List<int> fileBytes,
    required String fileName,
    CleaningConfig? config,
  }) async {
    // Step 1: Clean data
    final cleaningResult = await cleanData(
      fileBytes: fileBytes,
      fileName: fileName,
      config: config,
    );

    if (!cleaningResult.success) {
      return "❌ Cleaning failed: ${cleaningResult.error ?? cleaningResult.message}";
    }

    // Step 2: Write to Excel
    final writeResult = await writeCleanedDataToSheet(cleaningResult);

    if (writeResult['success'] != true) {
      return "⚠️ Data cleaned but failed to write to sheet: ${writeResult['error']}";
    }

    final sheetName = cleaningResult.export['sheet_name'] ?? 'Cleaned_Data';
    final rowCount = cleaningResult.export['row_count'] ?? 0;

    return "✅ Success! Cleaned data written to '$sheetName' sheet "
        "($rowCount rows, ${cleaningResult.after['columns']} columns).";
  }

  /// Get a description of what the null_strategy does
  static String describeNullStrategy(String strategy) {
    const strategies = {
      "smart": "Auto-detects best strategy per column (median for numbers, mode for categories)",
      "mean": "Uses average value for numeric columns, 'Unknown' for text",
      "median": "Uses middle value for numeric columns, 'Unknown' for text",
      "mode": "Uses most frequent value, 'Unknown' if no mode found",
      "forward_fill": "Copies value from previous row, 'Unknown' as fallback",
      "drop": "Removes entire rows with any missing values",
    };
    return strategies[strategy] ?? "Unknown strategy";
  }

  static String describeOutlierMethod(String method) {
    const methods = {
      "cap": "Adjusts extreme values to upper/lower bounds (preserves rows)",
      "remove": "Deletes rows containing outliers (reduces row count)",
      "mark": "Adds new columns flagging which values are outliers",
    };
    return methods[method] ?? "Unknown method";
  }
}
