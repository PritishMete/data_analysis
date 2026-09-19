// lib/core/interop/excel_interop_web.dart
@JS()
library excel_sheet_interop;

import 'dart:convert';
import 'dart:js_interop';
import 'package:http/http.dart' as http;
import '../security/privacy_mode.dart';

// ── JS Bindings ──────────────────────────────────────────────────────────────

@JS('processExcelPipeline')
external JSPromise<JSObject> _processExcelPipeline(JSString optionsJson);

@JS('getSelectedExcelData')
external JSPromise<JSString?> _getSelectedExcelData();

@JS('getWorksheetNames')
external JSPromise<JSArray<JSString>> _getWorksheetNames();

@JS('getActiveWorksheetName')
external JSPromise<JSString?> _getActiveWorksheetName();

@JS('getSheetData')
external JSPromise<JSString?> _getSheetData(JSString sheetName);

@JS('jsDetectDelimiters')
external JSPromise<JSArray<JSString>> _jsDetectDelimiters(JSString? sheetName, JSString columnName);

@JS('jsSplitColumnPipeline')
external JSPromise<JSObject> _jsSplitColumnPipeline(JSString? sourceSheet, JSString columnName, JSString delimiter);

@JS('jsBuildWrapRowsTable')
external JSPromise<JSObject> _jsBuildWrapRowsTable(JSString optionsJson);

@JS('jsApplyColorScale')
external JSPromise<JSObject> _jsApplyColorScale(JSString optionsJson);

@JS('jsAddComputedColumn')
external JSPromise<JSObject> _jsAddComputedColumn(JSString optionsJson);

@JS('jsWriteQueryResultToSheet')
external JSPromise<JSObject> _jsWriteQueryResultToSheet(JSString optionsJson);

@JS('jsExecuteLocalFilterQuery')
external JSPromise<JSObject> _jsExecuteLocalFilterQuery(JSString optionsJson);

@JS('jsWriteRangeBinningFormulas')
external JSPromise<JSObject> _jsWriteRangeBinningFormulas(JSString optionsJson);

@JS('jsAppendStaticColumn')
external JSPromise<JSObject> _jsAppendStaticColumn(JSString optionsJson);

@JS('createNativeExcelChart')
external JSPromise<JSObject> _createNativeExcelChart(JSString optionsJson);

@JS('jsWriteQualityReportWorksheet')
external JSPromise<JSObject> _jsWriteQualityReportWorksheet(JSString optionsJson);

// ── Extension Type for Type-Safe JS Responses ──────────────────────────────

extension type PipelineResponse._(JSObject _) implements JSObject {
  external bool get success;
  external int get processedRows;
  external String? get error;
  external String? get stage;
  external String? get chartId;
  external String? get chartName;
  external String? get sheetName;
  external String? get chartType;
  external String? get sourceRange;
  external String? get title;
  // Only set by processExcelPipeline when opts.pivotConfig was present —
  // a JSON string (see JSON.stringify(...) in web/excel_helper.js) rather
  // than a nested JS object, decoded the same way every other JSON payload
  // in this file already is. Shape: {mode, sheet, startingRow, gapRows,
  // pivotCount, sheetAlreadyExisted} — see PIVOT_GAP_ROWS in
  // web/excel_helper.js for the source of truth.
  external String? get pivotPlacement;
}

extension type QualityReportWorksheetResponse._(JSObject _) implements JSObject {
  external bool get success;
  external String? get sheet;
  external int get rowsWritten;
  external String? get error;
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Fetches currently selected Excel range as JSON string.
Future<String?> fetchExcelSelection() async {
  try {
    final result = await _getSelectedExcelData().toDart;
    if (result == null || result.isNull || result.isUndefined) return null;
    return result.toDart;
  } catch (_) {
    return null;
  }
}

/// Returns list of all worksheet names in the workbook.
Future<List<String>> getWorksheetNames() async {
  try {
    final jsArr = await _getWorksheetNames().toDart;
    final List<String> names = [];
    for (int i = 0; i < jsArr.length; i++) {
      names.add(jsArr[i].toDart);
    }
    return names;
  } catch (_) {
    return [];
  }
}

/// Returns the name of whichever worksheet is currently active, or null if
/// it can't be determined (e.g. no workbook context yet).
Future<String?> getActiveWorksheetName() async {
  try {
    final result = await _getActiveWorksheetName().toDart;
    if (result == null || result.isNull || result.isUndefined) return null;
    return result.toDart;
  } catch (_) {
    return null;
  }
}

@JS('getInsightFlowSourceWorksheetName')
external JSPromise<JSString?> _getInsightFlowSourceWorksheetName();

@JS('establishInsightFlowSourceFromActiveWorksheet')
external JSPromise<JSString?> _establishInsightFlowSourceFromActiveWorksheet();

Future<String?> establishInsightFlowSourceFromActiveWorksheet() async {
  try {
    final result = await _establishInsightFlowSourceFromActiveWorksheet().toDart;
    if (result == null || result.isNull || result.isUndefined) return null;
    return result.toDart;
  } catch (_) {
    return null;
  }
}

@JS('setInsightFlowSourceWorksheetName')
external JSPromise<JSBoolean> _setInsightFlowSourceWorksheetName(JSString sheetName);

Future<String?> getInsightFlowSourceWorksheetName() async {
  try {
    final result = await _getInsightFlowSourceWorksheetName().toDart;
    if (result == null || result.isNull || result.isUndefined) return null;
    return result.toDart;
  } catch (_) {
    return null;
  }
}

Future<bool> setInsightFlowSourceWorksheetName(String sheetName) async {
  try {
    return (await _setInsightFlowSourceWorksheetName(sheetName.toJS).toDart).toDart;
  } catch (_) {
    return false;
  }
}

/// Reads all data from a named sheet, returns JSON string (2D array).
Future<String?> fetchSheetData(String sheetName) async {
  try {
    final result = await _getSheetData(sheetName.toJS).toDart;
    if (result == null || result.isNull || result.isUndefined) return null;
    return result.toDart;
  } catch (_) {
    return null;
  }
}


/// Executes a filter-only query directly inside Office.js. This keeps the
/// workbook data in Excel and avoids the expensive Excel -> Dart JSON -> Dart
/// row filtering -> JSON -> Excel round-trip used by the legacy local path.
Future<Map<String, dynamic>> executeLocalFilterQuery(String optionsJson) async {
  try {
    final jsObj = await _jsExecuteLocalFilterQuery(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown Excel filter interop error"};
    }
    final response = LocalFilterResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
      "sheetName": response.sheetName,
      "rowCount": response.rowCount,
      "stepSummary": response.stepSummary,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

extension type LocalFilterResponse._(JSObject _) implements JSObject {
  external bool get success;
  external int get processedRows;
  external String? get error;
  external String? get sheetName;
  external int? get rowCount;
  external String? get stepSummary;
}

/// Executes the full transformation pipeline with source/target sheet control.
Future<Map<String, dynamic>> executePipeline(String optionsJson) async {
  try {
    final jsObj = await _processExcelPipeline(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    final Map<String, dynamic> result = {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
    // Present only for pivot-config requests (see PIVOT_GAP_ROWS/
    // pivotPlacement in web/excel_helper.js) — surfaced here rather than
    // silently dropped, so callers like _executeAgenticPivot/
    // _dispatchParsedOperation in data_screen.dart can report exactly
    // where the PivotTable landed.
    if (response.pivotPlacement != null) {
      try {
        result["pivotPlacement"] = jsonDecode(response.pivotPlacement!);
      } catch (_) {
        // Malformed/unexpected payload — leave pivotPlacement out rather
        // than fail the whole (already-successful) pipeline call over it.
      }
    }
    return result;
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Analyzes column data to suggest discovered text delimiters.
Future<List<String>> detectDelimiters(String? sheetName, String columnName) async {
  try {
    final jsArr = await _jsDetectDelimiters(sheetName?.toJS, columnName.toJS).toDart;
    final List<String> delimiters = [];
    for (int i = 0; i < jsArr.length; i++) {
      delimiters.add(jsArr[i].toDart);
    }
    return delimiters;
  } catch (_) {
    return [];
  }
}

/// Executes the physical cell division and column creation script pipeline.
Future<Map<String, dynamic>> splitColumnPipeline({
  required String? sourceSheet,
  required String columnName,
  required String delimiter,
}) async {
  try {
    final jsObj = await _jsSplitColumnPipeline(
      sourceSheet?.toJS,
      columnName.toJS,
      delimiter.toJS,
    ).toDart;
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Reshapes a single flattened column (header(s) + data all stacked in one
/// column) into a proper 2D table by writing an `=WRAPROWS(range, columnCount)`
/// formula (with a static fallback) into the target sheet.
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "sourceSheetName": "Sheet1" | null,
///   "sourceRange": "A1:A500" | null,
///   "columnCount": 5,
///   "targetSheetName": "Wrapped_Table" | null,
///   "hasHeaderRow": true
/// }
/// ```
Future<Map<String, dynamic>> buildWrapRowsTable(String optionsJson) async {
  try {
    final jsObj = await _jsBuildWrapRowsTable(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Applies a 2 or 3 colour Conditional Formatting colour scale
/// (Excel ribbon path: Home > Conditional Formatting > Color Scales,
/// reachable via the Alt+H, L, S, M accelerator-key sequence) to a column.
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "sheetName": "Sheet1" | null,
///   "column": "Revenue" | "C",
///   "hasHeaders": true,
///   "minColor": "F8696B",
///   "midColor": "FFEB84",
///   "maxColor": "63BE7B",
///   "scaleType": "3-color" | "2-color"
/// }
/// ```
/// When `hasHeaders` is true, `column` is resolved by matching it against the
/// first row of the sheet (the header row) and colouring starts at row 2.
/// When false, `column` is treated as a raw column letter and colouring
/// starts at row 1.
Future<Map<String, dynamic>> applyColorScale(String optionsJson) async {
  try {
    final jsObj = await _jsApplyColorScale(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Adds a new persistent column to the sheet, labeling each row based on a
/// per-group window condition — e.g. classifying customers as "Returning"
/// if their name appears more than once, else "New".
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "sheetName": "Sheet1" | null,
///   "hasHeaders": true,
///   "addColumnConfig": {
///     "newColumnName": "Customer_Status",
///     "windowFunction": "count" | "sum" | "avg" | "min" | "max",
///     "sourceColumn": "CustomerName",
///     "partitionBy": ["CustomerName"],
///     "operator": "greater_than" | "equals" | "not_equals" | "less_than" |
///                 "greater_than_equal" | "less_than_equal",
///     "value": "1",
///     "thenLabel": "Returning",
///     "elseLabel": "New"
///   }
/// }
/// ```
/// The new column is appended immediately after the last used column on the
/// sheet. When `hasHeaders` is true, row 1 gets `newColumnName` as its
/// header and data classification starts at row 2.
Future<Map<String, dynamic>> addComputedColumn(String optionsJson) async {
  try {
    final jsObj = await _jsAddComputedColumn(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Sends sheet data to the Python AI backend to dynamically deduce equations
/// and fill missing values, then writes the result back to Excel.
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "sheetName": "Sheet1",
///   "targetColumn": "DiscountPct"
/// }
/// ```
Future<Map<String, dynamic>> backtrackFillMissing(String optionsJson) async {
  try {
    if (secureLocalOnly) {
      return {"success": false, "error": "Remote backtrack fill is disabled in secure local mode."};
    }
    // 1. Parse the options. sheetName is nullable — null means "use the
    // active selection" (see _executeAgenticFillMissing in data_screen.dart),
    // matching every other function in this file (e.g. _fetchSourceData).
    final Map<String, dynamic> options = jsonDecode(optionsJson);
    final String? sheetName = options['sheetName'] as String?;
    final String targetColumn = options['targetColumn'];
    final String? sourceFormulaColumn = options['sourceFormulaColumn'] as String?;

    // 2. Fetch the raw data as a 2D array — from the named sheet, or from
    // the active selection when no sheet name was given.
    final String? rawDataJson =
    sheetName != null ? await fetchSheetData(sheetName) : await fetchExcelSelection();
    if (rawDataJson == null) {
      return {"success": false, "error": "Failed to read sheet data."};
    }

    final List<dynamic> sheetData2D = jsonDecode(rawDataJson);
    if (sheetData2D.isEmpty || sheetData2D.length < 2) {
      return {"success": false, "error": "Sheet does not contain enough data."};
    }

    // 3. Convert 2D Array into a List of Maps (Records) for Pandas
    final List<dynamic> headers = sheetData2D.first;
    final List<Map<String, dynamic>> records = [];

    for (int i = 1; i < sheetData2D.length; i++) {
      final List<dynamic> row = sheetData2D[i];
      final Map<String, dynamic> record = {};
      for (int j = 0; j < headers.length; j++) {
        record[headers[j].toString()] = j < row.length ? row[j] : null;
      }
      records.add(record);
    }

    // 4. Send data to the actual Python backend (same host as every other
    // route in this file — see _cleanDataUrl's counterpart in data_screen.dart).
    final Uri apiUrl = Uri.parse('https://data-analysis-oajs.onrender.com/api/clean/dynamic_backtrack');

    final response = await http.post(
      apiUrl,
      headers: {"Content-Type": "application/json"},
      body: jsonEncode({
        "data": records,
        "target_column": targetColumn,
        "source_formula_column": sourceFormulaColumn,
      }),
    );

    if (response.statusCode == 200) {
      final responseBody = jsonDecode(response.body);
      final List<dynamic> cleanedData = responseBody['cleaned_data'];

      if (cleanedData.isEmpty) {
        return {"success": true, "processedRows": 0, "error": null};
      }

      // 5. Extract column keys from the returned records for the write function
      final List<String> outColumns = (cleanedData.first as Map<String, dynamic>).keys.toList();

      // 6. Write the cleanedData back to Excel using the generic write interop
      // When sheetName was null (active-selection mode), there's no sheet
      // name to write back in place to, so fall back to a clearly-labelled
      // new sheet instead of the generic "Query_Result" default.
      final writeOptions = jsonEncode({
        "targetSheetName": sheetName ?? "Backtrack_Result",
        "columns": outColumns,
        "rows": cleanedData
      });

      final writeResult = await writeQueryResultToSheet(writeOptions);

      return {
        "success": writeResult['success'],
        "processedRows": cleanedData.length,
        "error": writeResult['error'],
      };
    } else {
      final errorBody = jsonDecode(response.body);
      return {"success": false, "error": errorBody['detail'] ?? "Backend API Error"};
    }
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Writes an arbitrary SQL/query result — a list of column names plus a
/// list of row records — into a new sheet as a plain table (headers bolded,
/// columns autofit). Used for the /smart_query "sql" route so a reporting
/// question like "revenue by returning vs new customers" can be written to
/// a sheet in addition to being shown in chat.
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "targetSheetName": "Query_Result",
///   "columns": ["customer_status", "total_revenue"],
///   "rows": [{"customer_status": "New", "total_revenue": 3659117.91}, ...]
/// }
/// ```
Future<Map<String, dynamic>> writeQueryResultToSheet(String optionsJson) async {
  try {
    final jsObj = await _jsWriteQueryResultToSheet(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Creates or replaces an editable native Excel chart on an existing result worksheet.
Future<Map<String,dynamic>> createNativeExcelChart(String optionsJson) async {
  try {
    final obj = await _createNativeExcelChart(optionsJson.toJS).toDart;
    final response = PipelineResponse._(obj);
    return {
      'success': response.success,
      'processedRows': response.processedRows,
      'error': response.error,
      'stage': response.stage,
      'chartId': response.chartId,
      'chartName': response.chartName,
      'sheetName': response.sheetName,
      'chartType': response.chartType,
      'sourceRange': response.sourceRange,
      'title': response.title,
    };
  } catch (e) {
    return {'success': false, 'error': e.toString(), 'stage': 'interop'};
  }
}

/// Writes a range-binning derived column back to the live sheet as LIVE
/// Excel formulas (a nested `IF()` chain) rather than static computed
/// values, so the column recalculates automatically if the user edits the
/// source cells. Backed by `jsWriteRangeBinningFormulas` in
/// web/excel_helper.js, which appends just the ONE new column via formulas
/// — it does not rewrite the rest of the sheet, unlike
/// [writeQueryResultToSheet]'s full-table static write-back.
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "sheetName": "Sheet1" | null,
///   "sourceColumn": "Aggregate rating",
///   "newColumn": "Rating_Range",
///   "formulaIntervals": [
///     {"low": 0, "high": 1, "low_open": false, "high_open": false, "label": "0-1"},
///     ...
///   ]
/// }
/// ```
///
/// `formulaIntervals` should come straight from the backend response's
/// `operation.metadata.formula_intervals` (see
/// common/transformations/range_binning.py::_formula_intervals) — this
/// function does not derive or validate ranges itself.
///
/// Returns `{"success": false, ...}` (never throws) whenever live formulas
/// can't be written for this sheet (e.g. the source column isn't present on
/// it, or `formulaIntervals` is missing/empty). Callers should treat that as
/// a signal to fall back to [writeQueryResultToSheet] for static values —
/// see `_applyGenericTransformation` in
/// lib/features/dashboard/data_screen.dart.
/// Appends one static column to the existing live worksheet without
/// rewriting the rest of the sheet. Used by sentiment analysis so the
/// original data stays in place and only `Sentiment` is added.
Future<Map<String, dynamic>> appendStaticColumn(String optionsJson) async {
  try {
    final jsObj = await _jsAppendStaticColumn(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

Future<Map<String, dynamic>> writeRangeBinningFormulas(String optionsJson) async {
  try {
    final jsObj = await _jsWriteRangeBinningFormulas(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = PipelineResponse._(jsObj);
    return {
      "success": response.success,
      "processedRows": response.processedRows,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

/// Builds the full, multi-section "Quality_Report" worksheet described in
/// web/excel_quality_report_generator.js. This is the SINGLE worksheet
/// generation implementation in the app — used both by the automatic
/// per-scan sync (DataScreenState._syncQualityReport(), overview-level
/// fields only, activate:false) and the explicit export button (full
/// AiReport). No re-analysis happens on either side of this call.
///
/// Expected [optionsJson] shape:
/// ```json
/// {
///   "sheetName": "Quality_Report",
///   "activate": true,
///   "datasetName": "Orders" | "myfile.csv",
///   "generatedAt": "8/7/2026, 3:45:00 PM",
///   "rows": 5000,
///   "columns": 12,
///   "missingValues": 15,
///   "missingValuesByColumn": { "City": 12, "Rating": 25, "Price": 8 },
///   "uniqueValuesByColumn": { "City": 40, "Rating": 10, "Price": 25 },
///   "duplicateRows": 20,
///   "duplicatesRaw": { "count": 20, ... },
///   "columnNames": ["City", "Rating", "Price"],
///   "describe": [ { "index": "count", "City": "...", ... }, ... ],
///   "dataQuality": { ... AiReport.dataQuality, verbatim, or {} ... },
///   "statistics": { ... AiReport.statistics, verbatim, or {} ... },
///   "executiveSummary": { ... AiReport.executiveSummary, verbatim, or {} ... },
///   "recommendations": [ ... AiReport.recommendations, verbatim, or [] ... ],
///   "outliers": [ ... AiReport.outliers, verbatim, or [] ... ],
///   "chartRecommendation": { ... AiReport.chartRecommendation, verbatim, or {} ... }
/// }
/// ```
/// `sheetName` always defaults to "Quality_Report" — the same worksheet is
/// reused (cleared and rewritten) on every call rather than creating copies.
/// `activate` defaults to true; pass false to leave the user's current
/// sheet/selection undisturbed (used by the background sync).
/// See DataScreenState._buildQualityReportPayload() for how this is built.
Future<Map<String, dynamic>> writeQualityReportWorksheet(String optionsJson) async {
  try {
    final jsObj = await _jsWriteQualityReportWorksheet(optionsJson.toJS).toDart;
    if (jsObj == null || jsObj.isNull || jsObj.isUndefined) {
      return {"success": false, "error": "Unknown JavaScript Interop error"};
    }
    final response = QualityReportWorksheetResponse._(jsObj);
    return {
      "success": response.success,
      "sheet": response.sheet,
      "rowsWritten": response.rowsWritten,
      "error": response.error,
    };
  } catch (e) {
    return {"success": false, "error": e.toString()};
  }
}

// appendQualityReportRow() was removed. Its only responsibility — writing
// the minimal Table|Rows|Missing|Duplicates rollup into "Quality_Report" —
// is now handled by writeQualityReportWorksheet() above, which is the single
// implementation used both by the automatic per-scan sync
// (DataScreenState._syncQualityReport(), passing activate:false and only
// overview-level fields) and by the explicit export button (passing the
// full AiReport). See excel_quality_report_generator.js's
// jsWriteQualityReportWorksheet() for the current implementation.
