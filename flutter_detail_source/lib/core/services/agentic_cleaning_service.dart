// lib/core/services/agentic_cleaning_service.dart
//
// Companion to data_cleaning_service.dart. Instead of building a
// CleaningConfig by hand, this sends the user's raw natural-language
// cleaning request straight to /agentic_clean_data, which uses
// cleaning_agent.py to turn it into an ordered steps[] list (handling
// compound, multi-part instructions like "fill nulls in age with mean,
// then lowercase headers, then convert salary usd to inr at 83.5") and
// executes them via cleaning_ops.py. The response is the same shape as
// /clean_data, so it plugs straight into the existing CleaningResult model.

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'data_cleaning_service.dart'; // reuse CleaningResult, writeCleanedDataToSheet
import '../security/privacy_mode.dart';

const String _agenticCleaningBackendUrl = "https://data-analysis-oajs.onrender.com";

class AgenticCleaningService {
  /// Preview-only: shows the user what steps the agent understood, WITHOUT
  /// touching any data. Good for a "here's what I'll do — proceed?" prompt.
  static Future<Map<String, dynamic>> previewSteps({
    required String text,
    required List<String> availableColumns,
  }) async {
    if (secureLocalOnly) {
      return {"steps": [], "message": "Remote cleaning preview is disabled in secure local mode.", "step_count": 0};
    }
    try {
      final res = await http
          .post(
        Uri.parse("$_agenticCleaningBackendUrl/agentic_clean_preview"),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "text": text,
          "available_columns": availableColumns,
        }),
      )
          .timeout(const Duration(seconds: 15));
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (e) {
      return {"steps": [], "message": "⚠️ Could not reach AI server: $e", "step_count": 0};
    }
  }

  /// Full workflow: send the file + raw natural-language query, let the
  /// agent figure out the ordered steps, run them, and return a
  /// CleaningResult exactly like DataCleaningService.cleanData does.
  static Future<CleaningResult> cleanWithQuery({
    required List<int> fileBytes,
    required String fileName,
    required String query,
    String outputSheetName = "Cleaned_Data",
  }) async {
    if (secureLocalOnly) {
      return CleaningResult(
        success: false,
        message: "Remote AI cleaning is disabled in secure local mode.",
        before: {}, after: {}, comparison: {}, cleaningReport: {}, export: {},
        error: "SECURE_LOCAL_ONLY",
      );
    }
    try {
      final request = http.MultipartRequest(
        'POST',
        Uri.parse("$_agenticCleaningBackendUrl/agentic_clean_data"),
      );
      request.files.add(
        http.MultipartFile.fromBytes('file', fileBytes, filename: fileName),
      );
      request.fields['text'] = query;
      request.fields['output_sheet_name'] = outputSheetName;

      final streamedResponse = await request.send();
      final response = await http.Response.fromStream(streamedResponse);

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        return CleaningResult.fromJson(json);
      }
      return CleaningResult(
        success: false,
        message: "Server error: ${response.statusCode}",
        before: {}, after: {}, comparison: {}, cleaningReport: {}, export: {},
        error: response.body,
      );
    } catch (e) {
      return CleaningResult(
        success: false,
        message: "⚠️ Could not reach AI server. Check your connection.",
        before: {}, after: {}, comparison: {}, cleaningReport: {}, export: {},
        error: e.toString(),
      );
    }
  }

  /// Same convenience combo as DataCleaningService.executeCleaningWorkflow:
  /// clean via NL query, then write the result straight into a new sheet.
  static Future<String> executeAgenticCleaningWorkflow({
    required List<int> fileBytes,
    required String fileName,
    required String query,
  }) async {
    final result = await cleanWithQuery(
      fileBytes: fileBytes,
      fileName: fileName,
      query: query,
    );

    if (!result.success) {
      return "❌ Cleaning failed: ${result.error ?? result.message}";
    }

    final writeResult = await DataCleaningService.writeCleanedDataToSheet(result);
    if (writeResult['success'] != true) {
      return "⚠️ Data cleaned but failed to write to sheet: ${writeResult['error']}";
    }

    final sheetName = result.export['sheet_name'] ?? 'Cleaned_Data';
    final rowCount = result.export['row_count'] ?? 0;
    return "✅ Success! '$query' applied — $rowCount rows written to '$sheetName'.";
  }
}
