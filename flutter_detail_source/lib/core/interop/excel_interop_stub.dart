// lib/core/interop/excel_interop_stub.dart
// Used on Android / Desktop targets where Office.js is unavailable.

Future<String?> fetchExcelSelection() async => null;

Future<List<String>> getWorksheetNames() async => [];

Future<String?> getActiveWorksheetName() async => null;
Future<String?> getInsightFlowSourceWorksheetName() async => null;
Future<bool> setInsightFlowSourceWorksheetName(String sheetName) async => false;

Future<String?> fetchSheetData(String sheetName) async => null;

Future<Map<String, dynamic>> executeLocalFilterQuery(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Local Excel filter execution is only available via Excel Web Add-ins.",
  };
}

Future<Map<String, dynamic>> executePipeline(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Pipeline execution is only available via Excel Web Add-ins.",
  };
}

Future<List<String>> detectDelimiters(String? sheetName, String columnName) async => [];

Future<Map<String, dynamic>> splitColumnPipeline({
  required String? sourceSheet,
  required String columnName,
  required String delimiter,
}) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Split operation is only available via Excel Web Add-ins.",
  };
}

/// Reshapes a single flattened column (header(s) + data all stacked in one
/// column) into a proper 2D table using Excel's WRAPROWS() function.
Future<Map<String, dynamic>> buildWrapRowsTable(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Table builder (WRAPROWS) is only available via Excel Web Add-ins.",
  };
}

/// Applies a colour scale (Home > Conditional Formatting > Color Scales,
/// i.e. the Alt+H,L,S,M shortcut) to a column's values.
Future<Map<String, dynamic>> applyColorScale(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Colour scale formatting is only available via Excel Web Add-ins.",
  };
}

/// Adds a new persistent column to the sheet, labeling each row based on a
/// per-group window condition (e.g. count of repeats per CustomerName).
Future<Map<String, dynamic>> addComputedColumn(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Add-column is only available via Excel Web Add-ins.",
  };
}
Future<Map<String, dynamic>> backtrackFillMissing(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Backtracking fill is only available via Excel Web Add-ins.",
  };
}

/// Writes range-binning formulas into the workbook (stub — Excel Web
/// Add-in only).
Future<Map<String, dynamic>> writeRangeBinningFormulas(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Range-binning formulas are only available via Excel Web Add-ins.",
  };
}

/// Writes an arbitrary SQL/query result to a new sheet (stub — Excel Web
/// Add-in only).
Future<Map<String, dynamic>> writeQueryResultToSheet(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Writing query results to a sheet is only available via Excel Web Add-ins.",
  };
}

/// Writes the Quality_Report worksheet — single implementation, used by both
/// the automatic per-scan sync and the explicit export button (stub — Excel
/// Web Add-in only).
Future<Map<String, dynamic>> writeQualityReportWorksheet(String optionsJson) async {
  return {
    "success": false,
    "sheet": null,
    "rowsWritten": 0,
    "error": "Quality report export is only available via Excel Web Add-ins.",
  };
}
Future<Map<String, dynamic>> appendStaticColumn(String optionsJson) async => {"success": false, "error": "Excel Web interop unavailable."};

/// Native chart creation is available only in the Excel Web Add-in.
Future<Map<String, dynamic>> createNativeExcelChart(String optionsJson) async {
  return {
    "success": false,
    "processedRows": 0,
    "error": "Native Excel chart creation is only available via Excel Web Add-ins.",
  };
}
