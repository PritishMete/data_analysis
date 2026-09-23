// lib/features/dashboard/data_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import '../auth/account_management_screen.dart';
import '../auth/authorization_management_screen.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../tech_background.dart';
import '../../core/services/ai_command_executor.dart';
import '../../core/services/agentic_command_executor.dart';
import '../../core/services/transformation_manager.dart';
import '../../core/services/location_detection_service.dart';
import '../../core/services/local_categorization_service.dart';
import '../../core/interop/excel_interop.dart';
import '../../core/interop/office_host.dart';
import '../../core/services/file_upload_handler.dart';
import '../../core/services/local_pipeline_service.dart';
import '../../core/services/secure_excel_local_service.dart';
import '../../core/security/outbound_privacy_guard.dart';
import '../../core/security/privacy_mode.dart';
import '../../models/transformation_result.dart';

import '../pipelines/pipeline_screen.dart';
import '../analysis/analysis_screen.dart';
import '../pivot_workspace/pivot_editor.dart';
import 'analyze_fab.dart';
import 'execute_pipeline_fab.dart';
import 'navigation_tabs.dart';
import 'ai_report_model.dart';
import '../../widgets/overlays/ranking_limit_dialog.dart';

enum DataSourceMode { excel, uploadedFile, excelLive }

const List<Map<String, String>> kAllMetricOps = [
  {'id': 'sum', 'label': 'SUM'},
  {'id': 'average', 'label': 'AVERAGE'},
  {'id': 'count', 'label': 'COUNT'},
  {'id': 'min', 'label': 'MIN'},
  {'id': 'max', 'label': 'MAX'},
];

class _FilterPlannerPrivacyContext {
  final String sanitizedQuery;
  final Map<String, String> valuePlaceholders;
  const _FilterPlannerPrivacyContext({
    required this.sanitizedQuery,
    required this.valuePlaceholders,
  });
}

/// Decodes a backend HTTP response body as JSON, turning failure modes that
/// used to surface as a bare `FormatException: Unexpected end of input (at
/// character 1)` into an actual explanation.
///
/// That specific exception means `body` was empty — `json.decode('')` always
/// fails at character 1 because there's nothing to parse. An empty body from
/// this backend (hosted on Render's free tier) almost always means the
/// request reached the server but the server didn't finish responding:
/// a worker timing out or getting OOM-killed on a large payload, a cold-start
/// 502 with no content, or the connection getting cut mid-response — never
/// a client-side JSON bug.
Map<String, dynamic> decodeBackendResponse(String body, {int? statusCode}) {
  if (body.trim().isEmpty) {
    final status = statusCode != null ? ' (HTTP $statusCode)' : '';
    throw "Server returned an empty response$status. This usually means the "
        "backend didn't finish processing the request — often a timeout or "
        "crash on a large dataset, or a cold start on Render's free tier. "
        "Try again in a moment; if it keeps happening with this dataset, "
        "it's likely too large for the backend to handle in one request.";
  }
  try {
    final decoded = json.decode(body);
    if (decoded is! Map<String, dynamic>) {
      throw "Server returned unexpected data (not a JSON object).";
    }
    return decoded;
  } on FormatException {
    final status = statusCode != null ? ' (HTTP $statusCode)' : '';
    final preview = body.length > 200 ? '${body.substring(0, 200)}…' : body;
    throw "Server returned a non-JSON response$status: \"$preview\"";
  }
}

/// Decode any supported source payload into the one internal representation
/// used by the analysis pipeline: a rectangular 2D matrix.
///
/// Excel JS normally returns `[[...], [...]]`, but some Office hosts/wrappers
/// can return `{values: [[...]]}` or `{data: {values: [[...]]}}`. Uploaded JSON
/// may also be an array of objects. Normalising here prevents the frontend
/// from treating a valid dataset as an invalid shape.
List<dynamic> decodeSourceMatrix(String raw) {
  dynamic decoded = json.decode(raw);

  // JS interop (getSheetData / getSelectedExcelData) reports real failures
  // (e.g. a used range too large for Office.js to read in one pass) as
  // {"__error": "..."} instead of silently returning null/empty. Surface
  // that message instead of falling through to a generic "no data" state.
  if (decoded is Map && decoded['__error'] is String) {
    throw decoded['__error'] as String;
  }

  if (decoded is Map) {
    if (decoded['values'] is List) {
      decoded = decoded['values'];
    } else if (decoded['data'] is Map && decoded['data']['values'] is List) {
      decoded = decoded['data']['values'];
    } else if (decoded['rows'] is List) {
      decoded = decoded['rows'];
    }
  }

  if (decoded is! List || decoded.isEmpty) return <dynamic>[];

  // Array-of-objects: convert it to [headers, ...rows]. This makes JSON file
  // uploads follow exactly the same path as CSV/XLSX/Excel range data.
  if (decoded.first is Map) {
    final objects = decoded.whereType<Map>().toList();
    final keys = <String>[];
    for (final object in objects) {
      for (final key in object.keys) {
        final k = key.toString();
        if (!keys.contains(k)) keys.add(k);
      }
    }
    return <dynamic>[
      keys,
      ...objects.map((object) => keys.map((k) => object[k]).toList()),
    ];
  }

  final matrix = <List<dynamic>>[];
  int width = 0;
  for (final item in decoded) {
    if (item is List) {
      final row = List<dynamic>.from(item);
      matrix.add(row);
      if (row.length > width) width = row.length;
    }
  }
  if (matrix.isEmpty || width == 0) return <dynamic>[];

  // Excel ranges are rectangular. Pad irregular rows so a CSV generated from
  // the matrix cannot shift columns when one row has fewer cells.
  for (final row in matrix) {
    while (row.length < width) row.add('');
  }
  return matrix;
}

class DataScreen extends StatefulWidget {
  const DataScreen({super.key});

  @override
  State<DataScreen> createState() => DataScreenState();
}

class DataScreenState extends State<DataScreen> with TickerProviderStateMixin {
  // ── Analysis ──────────────────────────────────────────────────────────────
  Map<String, dynamic>? analysisData;
  bool isLoading = false;
  String selectedView = "ALL_SYSTEMS";

  // ── Chat ──────────────────────────────────────────────────────────────────
  final TextEditingController chatController = TextEditingController();
  final List<Map<String, dynamic>> chatHistory = [];
  List<dynamic> chatFilteredRows = [];
  List<String> chatFilteredHeaders = [];
  bool isSearchingChat = false;

  // ── Pipeline toggles ──────────────────────────────────────────────────────
  bool createNewSheet = true;
  bool deduplicate = false;
  bool freezeHeaderRow = true;
  bool enableAutoFilter = true;
  final Set<String> deduplicateColumns = {};

  final TextEditingController metricsSheetNameController =
      TextEditingController(text: "Metrics_Layer");
  final Set<String> metricsColumns = {};
  final Set<String> metricsOps = {};

  // ── Column splitter ───────────────────────────────────────────────────────
  String? splitTargetColumn;
  List<String> detectedDelimiters = [];
  String? selectedDelimiter;
  bool isDetectingDelimiters = false;
  bool isExecutingSplit = false;

  // ── WRAPROWS table builder ────────────────────────────────────────────────
  bool enableTableBuilder = false;
  final TextEditingController tableBuilderRangeController =
      TextEditingController();
  final TextEditingController tableBuilderColumnCountController =
      TextEditingController(text: "5");
  final TextEditingController tableBuilderTargetSheetController =
      TextEditingController(text: "Wrapped_Table");
  bool tableBuilderHasHeaderRow = true;
  bool isBuildingTable = false;

  // ── Colour-scale ──────────────────────────────────────────────────────────
  bool enableColorCoding = false;
  bool colorCodeHasHeaders = true;
  String? colorCodeColumn;
  final TextEditingController colorCodeColumnLetterController =
      TextEditingController();
  String colorCodeScaleType = "3-color";
  String colorCodeMinColor = "FF0000";
  String colorCodeMidColor = "FFFF00";
  String colorCodeMaxColor = "00FF00";
  bool isApplyingColorScale = false;

  // ── Pivot table ───────────────────────────────────────────────────────────
  bool generatePivotTable = false;
  List<String> pivotRowFields = [];
  List<String> pivotColumnFields = [];
  List<String> pivotFilterFields = [];
  List<Map<String, String>> pivotValueFields = [];
  final TextEditingController pivotSheetNameController = TextEditingController(
    text: "Pivot_Workspace",
  );

  String? get pivotRowField =>
      pivotRowFields.isNotEmpty ? pivotRowFields.first : null;
  set pivotRowField(String? val) {
    if (val != null) {
      if (pivotRowFields.isEmpty)
        pivotRowFields.add(val);
      else
        pivotRowFields[0] = val;
    }
  }

  String? get pivotValueField =>
      pivotValueFields.isNotEmpty ? pivotValueFields.first["field"] : null;
  set pivotValueField(String? val) {
    if (val != null) {
      if (pivotValueFields.isEmpty)
        pivotValueFields.add({"field": val, "op": "sum"});
      else
        pivotValueFields[0]["field"] = val;
    }
  }

  Set<String> get pivotValueOps =>
      pivotValueFields.isNotEmpty ? {pivotValueFields.first["op"]!} : {"sum"};

  // ── Lookup ────────────────────────────────────────────────────────────────
  bool generateLookup = false;
  String selectedLookupType = "vlookup";
  String? lookupSourceColumn;
  String? lookupTargetSheet;
  bool lookupTableHasHeaders = true;
  String? lookupRefMatchColumn;
  bool lookupUseStaticSearch = false;
  List<String> lookupSourceColumnValues = [];
  bool isFetchingLookupSourceValues = false;
  String? lookupSelectedSourceValue;
  List<String> lookupReferenceHeaders = [];
  String? lookupReturnColumnHeader;
  final TextEditingController lookupRowIndexController = TextEditingController(
    text: "2",
  );
  bool lookupExactMatch = true;
  bool lookupShowAllColumns = false;
  List<String> lookupSelectedReturnColumns = [];

  int? get resolvedLookupColIndexNum {
    if (lookupReturnColumnHeader == null) return null;
    final idx = lookupReferenceHeaders.indexOf(lookupReturnColumnHeader!);
    return idx == -1 ? null : idx + 1;
  }

  int? get resolvedLookupRowIndexNum =>
      int.tryParse(lookupRowIndexController.text.trim());

  // ── Pivot sort/filters ────────────────────────────────────────────────────
  String pivotSortOrder = "none";
  bool pivotLabelFilterEnabled = false;
  String pivotLabelFilterType = "contains";
  final TextEditingController pivotLabelFilterValueController =
      TextEditingController();
  bool pivotValueFilterEnabled = false;
  String pivotValueFilterType = "greater_than";
  final TextEditingController pivotValueFilterVal1Controller =
      TextEditingController();
  final TextEditingController pivotValueFilterVal2Controller =
      TextEditingController();

  // ── Sheet / source selection ──────────────────────────────────────────────
  List<String> availableSheets = [];
  String? selectedSourceSheet;
  bool useActiveSelection = true;
  bool showDetailAnalysis = false;
  String activeSheetName = "Active Sheet";
  final TextEditingController targetSheetNameController =
      TextEditingController();
  bool useCustomTargetName = false;

  // ── Filter ────────────────────────────────────────────────────────────────
  List<String> detectedHeaders = [];
  String? selectedFilterColumn;
  String selectedFilterType = "equals";
  bool enableFilter = false;
  final TextEditingController valController1 = TextEditingController();
  final TextEditingController valController2 = TextEditingController();
  bool pipelineProcessing = false;

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController pulseController;
  final String apiUrl = "https://data-analysis-oajs.onrender.com/analyze";

  // ── Pivot editor ──────────────────────────────────────────────────────────
  String? activePivotSheetName;
  List<String> pivotEditorRowFields = [];
  List<String> pivotEditorColumnFields = [];
  List<String> pivotEditorFilterFields = [];
  List<Map<String, String>> pivotEditorValueFields = [];
  List<String> pivotSourceHeaders = [];
  bool pivotEditorRefreshing = false;
  String pivotEditorSortOrder = "none";
  bool pivotEditorLabelFilterEnabled = false;
  String pivotEditorLabelFilterType = "contains";
  final TextEditingController pivotEditorLabelFilterValueController =
      TextEditingController();
  bool pivotEditorValueFilterEnabled = false;
  String pivotEditorValueFilterType = "greater_than";
  final TextEditingController pivotEditorValueFilterVal1Controller =
      TextEditingController();
  final TextEditingController pivotEditorValueFilterVal2Controller =
      TextEditingController();
  String? pivotSourceSheetName;

  // ── File upload ───────────────────────────────────────────────────────────
  DataSourceMode dataSourceMode = DataSourceMode.excel;
  FileUploadResult? uploadedFile;
  bool isUploadingFile = false;

  String? get currentFileName => uploadedFile?.fileName;

  Uint8List? get currentFileBytes {
    final rows = uploadedFile?.rows;
    if (rows == null || rows.isEmpty) return null;
    final csv = rows.map((row) => row.map(escapeCsvValue).join(',')).join('\n');
    return Uint8List.fromList(utf8.encode(csv));
  }

  // Power BI Detail Analysis is deliberately separate from the single-file
  // pipeline so profiling cannot overwrite the active workbook dataset.
  List<String> detailAnalysisFileNames = [];
  bool isDetailAnalysisLoading = false;
  Map<String, dynamic>? detailAnalysisResult;
  String? detailAnalysisError;

  // ── AI report tab ─────────────────────────────────────────────────────────
  String? reportText;
  AiReport? aiReport;
  bool isGeneratingReport = false;
  String? reportError;
  // Set only AFTER the user explicitly chooses to write the AI report's
  // cleaned data to a sheet via writeReportCleanedData() — generating the
  // report itself no longer creates a sheet automatically. null means
  // either nothing has been written yet, or the report ran but the data
  // needed no cleaning.
  String? reportCleanedSheetName;
  String? reportCleanedSheetError;
  // Set by exportQualityReportToExcel() below — mirrors the
  // reportCleanedSheetName/-Error pattern above, but for the full
  // multi-section Quality Report worksheet export rather than the cleaned
  // dataset. isExportingQualityReport guards the button while the Office.js
  // call is in flight.
  bool isExportingQualityReport = false;
  String? qualityReportSheetName;
  String? qualityReportExportError;
  // The raw /analyze-report(-focused) response, kept around after
  // generateReport()/generateFocusedReport() so writeReportCleanedData()
  // can act on it later without re-running the report. Cleared once
  // written (or when a new report is generated).
  Map<String, dynamic>? _pendingReportCleanedData;

  // ── Agentic location enrichment ────────────────────────────────────────
  bool _locationPromptBusy = false;
  bool _locationPromptShown = false;
  String _locationDatasetSignature = '';

  // ── AI report tab: analysis-type selection step (before generating the
  // report) — suggested analysis types (from /suggest_analysis_types), the
  // dataset "profile" echoed back by that endpoint (needed by
  // /analysis_business_context without a second file upload), which ones
  // the user has manually selected, and the resulting business-problem
  // guidance (from /analysis_business_context) for the current selection.
  // The report selector is deliberately fixed to the analytics capabilities
  // exposed by the backend. Business-domain suggestions are kept separate
  // from the actual report-result selection.
  static const List<Map<String, String>> reportAnalysisOptions = [
    {
      'id': 'executive_summary',
      'title': 'Executive Summary',
      'description': 'Overall health, key findings, risks, opportunities.',
    },
    {
      'id': 'statistics',
      'title': 'Statistics',
      'description': 'Descriptive statistics and dataset-level metrics.',
    },
    {
      'id': 'trend_detection',
      'title': 'Trend Detection',
      'description': 'Increasing, decreasing, stable and growth signals.',
    },
    {
      'id': 'outlier_detection',
      'title': 'Outlier Detection',
      'description': 'Unusual values, severity and affected columns.',
    },
    {
      'id': 'kpi_analysis',
      'title': 'KPI Analysis',
      'description': 'Important business KPIs and their performance.',
    },
    {
      'id': 'recommendations',
      'title': 'Business Recommendations',
      'description': 'Rule-based actions derived from analytical signals.',
    },
    {
      'id': 'chart_recommendation',
      'title': 'Chart Recommendation',
      'description': 'Best chart type and metadata for the selected data.',
    },
    {
      'id': 'data_quality',
      'title': 'Data Quality',
      'description': 'Quality score, completeness and data issues.',
    },
  ];

  List<Map<String, dynamic>> suggestedAnalysisTypes = reportAnalysisOptions
      .map((e) => Map<String, dynamic>.from(e))
      .toList();
  Map<String, dynamic>? analysisProfile;
  Set<String> selectedAnalysisIds = reportAnalysisOptions
      .map((e) => e['id']!)
      .toSet();
  bool isSuggestingAnalysisTypes = false;
  String? analysisSuggestError;

  List<Map<String, dynamic>> businessProblemResults = [];
  bool isLoadingBusinessContext = false;
  String? businessContextError;

  // ── Views ─────────────────────────────────────────────────────────────────
  final List<Map<String, dynamic>> views = [
    {"id": "ALL_SYSTEMS", "label": "ALL", "icon": Icons.terminal},
    {"id": "PIPELINES", "label": "PIPELINES", "icon": Icons.tune},
    {"id": "NEURAL_CHAT", "label": "AI CHAT", "icon": Icons.code},
    {"id": "OVERVIEW", "label": "OVERVIEW", "icon": Icons.layers},
    {"id": "PREVIEW", "label": "PREVIEW", "icon": Icons.grid_view},
    {"id": "STATS", "label": "STATS", "icon": Icons.analytics},
    {"id": "QUALITY", "label": "QUALITY", "icon": Icons.rule},
    {"id": "LOGS", "label": "LOGS", "icon": Icons.list_alt},
    {"id": "PIVOT_EDITOR", "label": "PIVOT", "icon": Icons.pivot_table_chart},
  ];

  final List<Map<String, String>> filterOptions = [
    {"id": "equals", "label": "Equals To"},
    {"id": "not_equals", "label": "Does Not Equal"},
    {"id": "contains", "label": "Text Contains"},
    {"id": "greater_than", "label": "Greater Than (>)"},
    {"id": "less_than", "label": "Less Than (<)"},
    {"id": "greater_than_equal", "label": "Greater or Equal (>=)"},
    {"id": "less_than_equal", "label": "Less or Equal (<=)"},
    {"id": "between", "label": "Between (range)"},
    {"id": "above_average", "label": "Above Column Average"},
    {"id": "below_average", "label": "Below Column Average"},
    {"id": "top_n", "label": "Top N Values"},
    {"id": "bottom_n", "label": "Bottom N Values"},
  ];

  // =========================================================================
  // Lifecycle — unchanged
  // =========================================================================

  // Centralized home for Enterprise Transformation Engine results — parses
  // backend responses, updates dataset/schema/statistics/AI report/chart
  // recommendation, and notifies this screen to rebuild. See
  // lib/core/services/transformation_manager.dart.
  final TransformationManager _transformationManager = TransformationManager();

  void _onTransformationManagerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _transformationManager.addListener(_onTransformationManagerChanged);
    syncOnStartup();
  }

  @override
  void dispose() {
    _transformationManager.removeListener(_onTransformationManagerChanged);
    _transformationManager.dispose();
    pulseController.dispose();
    valController1.dispose();
    valController2.dispose();
    targetSheetNameController.dispose();
    pivotSheetNameController.dispose();
    pivotLabelFilterValueController.dispose();
    pivotValueFilterVal1Controller.dispose();
    pivotValueFilterVal2Controller.dispose();
    pivotEditorLabelFilterValueController.dispose();
    pivotEditorValueFilterVal1Controller.dispose();
    pivotEditorValueFilterVal2Controller.dispose();
    lookupRowIndexController.dispose();
    chatController.dispose();
    tableBuilderRangeController.dispose();
    tableBuilderColumnCountController.dispose();
    tableBuilderTargetSheetController.dispose();
    colorCodeColumnLetterController.dispose();
    super.dispose();
  }

  // =========================================================================
  // Business logic — all unchanged
  // =========================================================================

  Future<void> syncOnStartup() async {
    if (!kIsWeb) return;
    await refreshWorksheetNames();
    final persistedSource = await getInsightFlowSourceWorksheetName();
    if (persistedSource != null && persistedSource.isNotEmpty) {
      if (availableSheets.contains(persistedSource)) {
        useActiveSelection = false;
        selectedSourceSheet = persistedSource;
        activeSheetName = persistedSource;
      } else {
        useActiveSelection = false;
        selectedSourceSheet = null;
        activeSheetName = "Source worksheet unavailable";
      }
    } else {
      final candidate = await getInsightFlowSourceWorksheetName();
      if (candidate != null && candidate.isNotEmpty) {
        final saved = await setInsightFlowSourceWorksheetName(candidate);
        if (saved) {
          useActiveSelection = false;
          selectedSourceSheet = candidate;
          activeSheetName = candidate;
        }
      } else {
        useActiveSelection = false;
        selectedSourceSheet = null;
        activeSheetName = "Select an original dataset worksheet";
      }
    }
    await syncHeadersSilently();
  }

  /// Establishes the workbook's analytical source once, then reuses it for
  /// subsequent queries. Excel activation remains presentation-only.
  Future<String?> _ensureAnalyticalSourceSheet() async {
    if (dataSourceMode == DataSourceMode.uploadedFile) return null;
    if (!kIsWeb) return null;
    final persisted = await getInsightFlowSourceWorksheetName();
    if (persisted != null && persisted.isNotEmpty) {
      if (!availableSheets.contains(persisted)) {
        throw "The established source worksheet '$persisted' is no longer available. Select an original dataset worksheet before running this query.";
      }
      if (useActiveSelection || selectedSourceSheet != persisted) {
        if (mounted) {
          setState(() {
            useActiveSelection = false;
            selectedSourceSheet = persisted;
            activeSheetName = persisted;
          });
        }
      }
      return persisted;
    }
    final candidate = await getInsightFlowSourceWorksheetName();
    if (candidate == null || candidate.isEmpty) {
      throw "No analytical source worksheet is established. Select an original dataset worksheet first.";
    }
    if (!await setInsightFlowSourceWorksheetName(candidate)) {
      throw "Could not establish '$candidate' as the analytical source worksheet.";
    }
    if (mounted) {
      setState(() {
        useActiveSelection = false;
        selectedSourceSheet = candidate;
        activeSheetName = candidate;
      });
    }
    return candidate;
  }

  Future<void> refreshWorksheetNames() async {
    if (!kIsWeb) return;
    final names = await getWorksheetNames();
    if (names.isNotEmpty && mounted) setState(() => availableSheets = names);
  }

  Future<String?> safeFetchActiveSheetData() async {
    try {
      if (kIsWeb) return await fetchExcelSelection();
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> syncHeadersSilently() async {
    if (dataSourceMode == DataSourceMode.uploadedFile) {
      if (uploadedFile == null || uploadedFile!.rows.isEmpty) return;
      _applyHeadersFromRows(uploadedFile!.rows);
      return;
    }
    if (!kIsWeb) return;
    String? rawData;
    if (!useActiveSelection && selectedSourceSheet != null) {
      rawData = await getInsightFlowSourceData();
      rawData ??= await fetchSheetData(selectedSourceSheet!);
    } else {
      rawData = await safeFetchActiveSheetData();
      if (rawData == null) {
        final sheets = await getWorksheetNames();
        if (sheets.isNotEmpty) rawData = await fetchSheetData(sheets.first);
      }
    }
    if (rawData == null) return;
    try {
      final List<dynamic> parsed = decodeSourceMatrix(rawData);
      if (parsed.isEmpty || parsed.first is! List) return;
      _applyHeadersFromRows(parsed.cast<List<dynamic>>());
    } catch (_) {}
  }

  void _applyHeadersFromRows(List<List<dynamic>> rows) {
    if (rows.isEmpty || rows.first.isEmpty) return;
    final headers = rows.first
        .map((e) => e?.toString().trim() ?? '')
        .where((e) => e.isNotEmpty)
        .toList();
    if (headers.isEmpty) return;
    setState(() {
      detectedHeaders = headers;
      if (selectedFilterColumn == null ||
          !detectedHeaders.contains(selectedFilterColumn)) {
        selectedFilterColumn = detectedHeaders.first;
      }
      if (splitTargetColumn == null ||
          !detectedHeaders.contains(splitTargetColumn)) {
        splitTargetColumn = detectedHeaders.first;
        if (dataSourceMode == DataSourceMode.excel) triggerDelimiterDetection();
      }
      if (pivotRowFields.isEmpty) pivotRowFields = [detectedHeaders.first];
      if (pivotValueFields.isEmpty)
        pivotValueFields = [
          {"field": detectedHeaders.last, "op": "sum"},
        ];
      if (lookupSourceColumn == null ||
          !detectedHeaders.contains(lookupSourceColumn)) {
        lookupSourceColumn = detectedHeaders.first;
      }
      if (colorCodeColumn == null ||
          !detectedHeaders.contains(colorCodeColumn)) {
        colorCodeColumn = detectedHeaders.first;
      }
    });

    // For Excel/Web datasets, proactively detect the common location schema.
    // The backend performs a read-only preview first; no cells are modified
    // until the user explicitly accepts the proposed enrichment.
    if (kIsWeb && dataSourceMode != DataSourceMode.uploadedFile) {
      _maybeOfferLocationEnrichment(rows, headers);
    }
  }

  Future<void> _maybeOfferLocationEnrichment(
    List<List<dynamic>> rows,
    List<String> headers,
  ) async {
    if (!mounted || _locationPromptBusy || rows.length < 2) return;
    final lower = headers
        .map((h) => h.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), ''))
        .toSet();
    final hasLat = lower.any(
      (h) =>
          h == 'latitude' ||
          h == 'lat' ||
          h == 'latitudecenter' ||
          h == 'latcenter',
    );
    final hasLon = lower.any(
      (h) =>
          h == 'longitude' ||
          h == 'lon' ||
          h == 'lng' ||
          h == 'longitudecenter' ||
          h == 'loncenter',
    );
    final hasCity = lower.any(
      (h) =>
          h == 'city' || h == 'town' || h == 'municipality' || h == 'locality',
    );
    final hasRegion = lower.any(
      (h) =>
          h == 'region' ||
          h == 'state' ||
          h == 'province' ||
          h == 'stateprovince',
    );
    final hasCountry = lower.any(
      (h) => h == 'country' || h == 'countryname' || h == 'nation',
    );
    final schemaLikely =
        (hasLat && hasLon && (hasCity || hasRegion || hasCountry)) ||
        (hasCity && (hasRegion || hasCountry));
    if (!schemaLikely) return;

    final signature = headers.join('|') + '::' + rows.length.toString();
    if (_locationDatasetSignature == signature && _locationPromptShown) return;
    _locationDatasetSignature = signature;
    _locationPromptBusy = true;
    try {
      final records = <Map<String, dynamic>>[];
      for (final row in rows.skip(1)) {
        final record = <String, dynamic>{};
        for (var i = 0; i < headers.length; i++) {
          record[headers[i]] = i < row.length ? row[i] : null;
        }
        records.add(record);
      }
      final result = await detectMissingLocations(
        columns: headers,
        rows: records,
      );
      if (!mounted ||
          result['success'] != true ||
          (result['filled_cells'] ?? 0) <= 0)
        return;
      _locationPromptShown = true;

      final int filled = (result['filled_cells'] as num?)?.toInt() ?? 0;
      final int resolvedRows = (result['resolved_rows'] as num?)?.toInt() ?? 0;
      final int unresolved = (result['unresolved_rows'] as num?)?.toInt() ?? 0;
      final choice = await GlassDialog.show<String>(
        context: context,
        maxWidth: 420,
        title: 'Location data found',
        message:
            'The Location Agent found $filled missing values across $resolvedRows rows. ${unresolved > 0 ? '$unresolved rows remain ambiguous and will be left unchanged. ' : ''}Create a new enriched dataset without changing your current sheet?',
        actions: [
          GlassDialogAction(
            label: 'Not Now',
            onPressed: () => Navigator.pop(context, 'cancel'),
          ),
          GlassDialogAction(
            label: 'Fill Missing Data',
            isPrimary: true,
            onPressed: () => Navigator.pop(context, 'apply'),
          ),
        ],
      );
      if (choice != 'apply' || !mounted) return;

      final outputRows = (result['rows'] is List)
          ? (result['rows'] as List)
                .whereType<Map>()
                .map((e) => Map<String, dynamic>.from(e))
                .toList()
          : <Map<String, dynamic>>[];
      // /location/enrich returns `columns` as a logical->physical column
      // mapping. The worksheet writer needs the actual ordered header list.
      // Prefer an explicit output_columns list when supplied, otherwise use
      // the exact headers read from Excel. Never cast the mapping to List.
      final dynamic backendOutputColumns = result['output_columns'];
      final List<String> outputColumns = backendOutputColumns is List
          ? backendOutputColumns.map((e) => e.toString()).toList()
          : headers.map((e) => e.toString()).toList();
      if (outputRows.isEmpty || outputColumns.isEmpty) {
        if (mounted) {
          showError(
            'Location Agent returned no writable dataset. Please try again.',
          );
        }
        return;
      }
      final target = _uniqueLocationSheetName();
      final writeResult = await writeQueryResultToSheet(
        json.encode({
          'targetSheetName': target,
          'columns': outputColumns,
          'rows': outputRows,
        }),
      );
      if (writeResult['success'] == true) {
        await refreshWorksheetNames();
        await syncHeadersSilently();
        showNotification(
          'LOCATION DATASET CREATED: $target · $filled values filled',
          TechColors.statusGreen,
        );
      } else {
        showError(
          'Location data was resolved, but the new dataset could not be created: ${writeResult['error'] ?? 'unknown error'}',
        );
      }
    } catch (e) {
      debugPrint('[location_agent] $e');
    } finally {
      _locationPromptBusy = false;
    }
  }

  String _uniqueLocationSheetName() {
    const base = 'Location_Enriched';
    var candidate = base;
    var n = 2;
    while (availableSheets.any(
      (s) => s.toLowerCase() == candidate.toLowerCase(),
    )) {
      final suffix = '_$n';
      candidate =
          base.substring(0, math.min(31 - suffix.length, base.length)) + suffix;
      n++;
    }
    return candidate;
  }

  Future<void> pickAndLoadFile() async {
    setState(() => isUploadingFile = true);
    try {
      final result = await pickAndParseFile();
      if (result == null) return;
      setState(() {
        uploadedFile = result;
        dataSourceMode = DataSourceMode.uploadedFile;
        analysisData = null;
        aiReport = null;
        reportText = null;
        reportError = null;
        selectedView = "ALL_SYSTEMS";
      });
      _applyHeadersFromRows(result.rows);
      showNotification(
        "FILE LOADED: ${result.fileName} · ${result.dataRowCount} rows · ${result.headers.length} cols [${result.formatLabel}]",
        TechColors.statusBlue,
      );
    } catch (e) {
      showError("FILE PARSE ERROR: ${e.toString()}");
    } finally {
      if (mounted) setState(() => isUploadingFile = false);
    }
  }

  void clearUploadedFile() {
    setState(() {
      uploadedFile = null;
      dataSourceMode = DataSourceMode.excel;
      analysisData = null;
      aiReport = null;
      reportText = null;
      reportError = null;
      detectedHeaders = [];
      selectedView = "ALL_SYSTEMS";
    });
    syncHeadersSilently();
  }

  String? _uploadedFileAsJsonString() {
    if (uploadedFile == null || uploadedFile!.rows.isEmpty) return null;
    return json.encode(uploadedFile!.rows);
  }

  Future<String?> _fetchSourceData() async {
    if (dataSourceMode == DataSourceMode.uploadedFile) return _uploadedFileAsJsonString();
    final source = await _ensureAnalyticalSourceSheet();
    if (source == null || source.isEmpty) return null;
    // Analytical reads must use the persisted worksheet/range context. This
    // prevents a generated Quality_Report, Query_Result, or Pivot sheet from
    // becoming the source merely because Excel activated it.
    if (kIsWeb) {
      final persistedData = await getInsightFlowSourceData();
      if (persistedData != null && persistedData.isNotEmpty) return persistedData;
    }
    return fetchSheetData(source);
  }

  Future<void> fetchLookupReferenceHeaders(String targetSheet) async {
    final rawData = await fetchSheetData(targetSheet);
    if (rawData == null) return;
    try {
      final List<dynamic> parsed = decodeSourceMatrix(rawData);
      if (parsed.isNotEmpty && parsed.first is List) {
        final headers = List<dynamic>.from(
          parsed.first,
        ).map((e) => e.toString().trim()).toList();
        setState(() {
          lookupReferenceHeaders = headers;
          if (lookupSourceColumn != null &&
              headers.contains(lookupSourceColumn)) {
            lookupRefMatchColumn = lookupSourceColumn;
          } else {
            lookupRefMatchColumn = headers.isNotEmpty ? headers.first : null;
          }
          lookupReturnColumnHeader = headers.firstWhere(
            (h) => h != lookupRefMatchColumn,
            orElse: () => headers.isNotEmpty ? headers.first : "",
          );
          if (lookupReturnColumnHeader == "") lookupReturnColumnHeader = null;
          lookupSelectedReturnColumns = [];
        });
      }
    } catch (_) {}
  }

  Future<void> fetchLookupSourceColumnValues() async {
    final String? keyColumn = lookupSourceColumn;
    if (keyColumn == null) return;
    if (dataSourceMode == DataSourceMode.excel && !kIsWeb) return;
    setState(() => isFetchingLookupSourceValues = true);
    String? rawData = await _fetchSourceData();
    if (rawData == null) {
      if (mounted) setState(() => isFetchingLookupSourceValues = false);
      return;
    }
    try {
      final List<dynamic> parsed = decodeSourceMatrix(rawData);
      if (parsed.isEmpty || parsed.first is! List) {
        if (mounted) setState(() => isFetchingLookupSourceValues = false);
        return;
      }
      final headerRow = List<dynamic>.from(
        parsed.first,
      ).map((e) => e.toString().trim()).toList();
      final colIdx = headerRow.indexOf(keyColumn);
      if (colIdx == -1) {
        setState(() {
          lookupSourceColumnValues = [];
          isFetchingLookupSourceValues = false;
        });
        return;
      }
      final seen = <String>{};
      for (int i = 1; i < parsed.length; i++) {
        final row = parsed[i];
        if (row is! List || colIdx >= row.length) continue;
        final cell = row[colIdx]?.toString().trim() ?? "";
        if (cell.isNotEmpty) seen.add(cell);
      }
      final sortedValues = seen.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      setState(() {
        lookupSourceColumnValues = sortedValues;
        isFetchingLookupSourceValues = false;
        if (lookupSelectedSourceValue != null &&
            !sortedValues.contains(lookupSelectedSourceValue)) {
          lookupSelectedSourceValue = null;
        }
      });
    } catch (_) {
      if (mounted) setState(() => isFetchingLookupSourceValues = false);
    }
  }

  Future<void> triggerDelimiterDetection() async {
    if (splitTargetColumn == null || !kIsWeb) return;
    setState(() {
      isDetectingDelimiters = true;
      detectedDelimiters = [];
      selectedDelimiter = null;
    });
    final discovered = await detectDelimiters(
      (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      splitTargetColumn!,
    );
    setState(() {
      detectedDelimiters = discovered;
      if (detectedDelimiters.isNotEmpty)
        selectedDelimiter = detectedDelimiters.first;
      isDetectingDelimiters = false;
    });
  }

  Future<void> runColumnSplitPipeline() async {
    if (splitTargetColumn == null || selectedDelimiter == null) return;
    setState(() => isExecutingSplit = true);
    final result = await splitColumnPipeline(
      sourceSheet: (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      columnName: splitTargetColumn!,
      delimiter: selectedDelimiter!,
    );
    setState(() => isExecutingSplit = false);
    if (result["success"] == true) {
      showNotification("COLUMN SPLIT COMPLETE!", TechColors.statusGreen);
      await refreshWorksheetNames();
      await syncHeadersSilently();
    } else {
      showError(result["error"] ?? "Failed executing split.");
    }
  }

  Future<void> runTableBuilderPipeline() async {
    final rawCount = int.tryParse(
      tableBuilderColumnCountController.text.trim(),
    );
    if (rawCount == null || rawCount < 1) {
      showError("Enter a valid result column count.");
      return;
    }
    setState(() => isBuildingTable = true);
    final options = {
      "sourceSheetName": (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      "sourceRange": tableBuilderRangeController.text.trim().isNotEmpty
          ? tableBuilderRangeController.text.trim()
          : null,
      "columnCount": rawCount,
      "targetSheetName":
          tableBuilderTargetSheetController.text.trim().isNotEmpty
          ? tableBuilderTargetSheetController.text.trim()
          : "Wrapped_Table",
      "hasHeaderRow": tableBuilderHasHeaderRow,
    };
    final result = await buildWrapRowsTable(json.encode(options));
    setState(() => isBuildingTable = false);
    if (result["success"] == true) {
      showNotification(
        "TABLE BUILT: ${result['processedRows']} rows via WRAPROWS",
        TechColors.statusGreen,
      );
      await refreshWorksheetNames();
      await syncHeadersSilently();
    } else {
      showError(result["error"] ?? "Failed building wrapped table.");
    }
  }

  Future<void> runColorCodingPipeline() async {
    final String? resolvedColumn = colorCodeHasHeaders
        ? colorCodeColumn
        : (colorCodeColumnLetterController.text.trim().isNotEmpty
              ? colorCodeColumnLetterController.text.trim().toUpperCase()
              : null);
    if (resolvedColumn == null || resolvedColumn.isEmpty) {
      showError(
        colorCodeHasHeaders
            ? "Select a column header to colour."
            : "Enter a column letter (e.g. C).",
      );
      return;
    }
    setState(() => isApplyingColorScale = true);
    final options = {
      "sheetName": (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      "column": resolvedColumn,
      "hasHeaders": colorCodeHasHeaders,
      "scaleType": colorCodeScaleType,
      "minColor": colorCodeMinColor,
      "midColor": colorCodeMidColor,
      "maxColor": colorCodeMaxColor,
    };
    final result = await applyColorScale(json.encode(options));
    setState(() => isApplyingColorScale = false);
    if (result["success"] == true) {
      showNotification(
        "COLOUR SCALE APPLIED: ${result['processedRows']} cells",
        TechColors.statusGreen,
      );
    } else {
      showError(result["error"] ?? "Failed applying colour scale.");
    }
  }

  String sheetSafe(String s) {
    final cleaned = s
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9 _]'), '')
        .replaceAll(' ', '_');
    return cleaned.substring(0, math.min(cleaned.length, 15));
  }

  String filterTypeShortLabel(String type) {
    const map = {
      'equals': 'EQ',
      'not_equals': 'NEQ',
      'contains': 'HAS',
      'greater_than': 'GT',
      'less_than': 'LT',
      'greater_than_equal': 'GTE',
      'less_than_equal': 'LTE',
      'between': 'BTW',
      'above_average': 'AbvAvg',
      'below_average': 'BlwAvg',
      'top_n': 'Top',
      'bottom_n': 'Bot',
    };
    return map[type] ?? type;
  }

  // Matches characters that are invisible in Excel but aren't caught by
  // Dart's String.trim(): non-breaking space, zero-width space/non-joiner/
  // joiner, BOM, soft hyphen, word joiner. Excel silently leaves these
  // behind in "blank-looking" cells more often than you'd expect (e.g.
  // after a cell was typed into and then cleared).
  static final RegExp _invisibleCharsRe = RegExp(
    '[\u00A0\u200B\u200C\u200D\uFEFF\u00AD\u2060]',
  );

  String escapeCsvValue(dynamic value) {
    if (value == null) return "";
    if (value is bool) return value ? "TRUE" : "FALSE";
    if (value is num) return value.toString();
    String str = value.toString();
    // Strip invisible characters everywhere in the string first — not just
    // when the whole cell is blank. A name like "Ani\u200bta" would
    // otherwise survive as a distinct value from "Anita" downstream (wrong
    // unique-value counts), even though nothing looks different in Excel.
    str = str.replaceAll(_invisibleCharsRe, '');
    // Treat whitespace-only strings (a stray space, tab, etc. left in a
    // cell that looks blank) as truly blank too — not just fully empty
    // strings. Otherwise a lone space survives into the CSV as literal
    // data: pandas can't parse it as a number (so the whole column falls
    // back to object/string dtype) and isnull() doesn't flag it either,
    // so it silently escapes every null count downstream.
    if (str.trim().isEmpty) return "";
    str = str.trim();
    if (str.contains(',') ||
        str.contains('"') ||
        str.contains('\n') ||
        str.contains('\r')) {
      str = str.replaceAll('"', '""');
      return '"$str"';
    }
    return str;
  }

  void showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(
            color: Colors.white,
            fontFamily: 'Courier',
            fontSize: 13,
          ),
        ),
        backgroundColor: TechColors.statusRed,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void showNotification(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: TextStyle(
            fontFamily: 'Courier',
            color: color == TechColors.statusGreen
                ? Colors.black
                : Colors.white,
          ),
        ),
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // Base URL for /smart_query — same backend as /agentic_command and
  // /parse_command, just a different route (see main.py + query_router.py).
  static const String _backendBaseUrl = "https://data-analysis-oajs.onrender.com";
  static const String _smartQueryUrl =
      "$_backendBaseUrl/smart_query";
  static const String _sentimentUrl =
      "https://data-analysis-oajs.onrender.com/sentiment_analysis";
  static const Duration _sentimentRequestTimeout = Duration(minutes: 4);

  Map<String, dynamic>? _buildResilientFilterPlan(String text) {
    // Emergency client-side fallback for the common filter grammar. The normal
    // path is still /agentic_filter_plan; this exists only so a transient
    // backend timeout can never hand a filter request to the slow general
    // agent and leave the UI in "Processing".
    if (detectedHeaders.isEmpty) return null;

    String normalize(dynamic value) => value
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r"['`´‘’‛]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');

    String? resolveSemantic(String semantic) {
      final aliases = <String, List<String>>{
        'entity': [
          'restaurant name',
          'restaurant',
          'brand name',
          'brand',
          'entity name',
          'merchant name',
          'business name',
          'name',
        ],
        'online_delivery': [
          'has online delivery',
          'online delivery',
          'online delivery available',
          'delivery available',
          'delivery capability',
          'provides delivery',
          'delivery',
        ],
        'online_table_booking': [
          'has table booking',
          'online table booking',
          'online table reservation',
          'table booking available',
          'table booking',
          'table reservation',
          'reservation',
          'booking',
        ],
        'rating': [
          'aggregate rating',
          'average rating',
          'rating score',
          'review rating',
          'rating',
          'ratings',
        ],
      };
      final wanted = aliases[semantic] ?? const <String>[];
      final normalized = <String, String>{
        for (final h in detectedHeaders) normalize(h): h,
      };
      for (final alias in wanted) {
        final hit = normalized[normalize(alias)];
        if (hit != null) return hit;
      }
      return null;
    }

    final filters = <Map<String, dynamic>>[];
    final entity = RegExp(
      r'\b(?:show|find|filter|display|list|give|fetch|view|return)\s+(?:me\s+)?(.+?)\s+restaurants?\b',
      caseSensitive: false,
    ).firstMatch(text);
    final entityColumn = resolveSemantic('entity');
    if (entity != null && entityColumn != null) {
      final value = entity.group(1)?.trim();
      if (value != null && value.isNotEmpty) {
        filters.add({
          'column': entityColumn,
          'operator': 'contains',
          'value': value,
        });
      }
    }

    if (RegExp(
      r'\b(?:online\s+)?delivery\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      final column = resolveSemantic('online_delivery');
      if (column != null)
        filters.add({'column': column, 'operator': 'equals', 'value': true});
    }
    if (RegExp(
      r'\b(?:online\s+)?table\s+(?:booking|reservation)\b',
      caseSensitive: false,
    ).hasMatch(text)) {
      final column = resolveSemantic('online_table_booking');
      if (column != null)
        filters.add({'column': column, 'operator': 'equals', 'value': true});
    }

    final rating = RegExp(
      r'(?:\bratings?\b[^0-9]*(greater\s+than|more\s+than|above|over|less\s+than|below|under|at\s+least|at\s+most|equal\s+to|equals?)\s*(-?\d+(?:[.,]\d+)?)|'
      r'\b(greater\s+than|more\s+than|above|over|less\s+than|below|under|at\s+least|at\s+most|equal\s+to|equals?)\s*(-?\d+(?:[.,]\d+)?)\s+ratings?\b)',
      caseSensitive: false,
    ).firstMatch(text);
    if (rating != null) {
      final word = (rating.group(1) ?? rating.group(3) ?? '')
          .toLowerCase()
          .replaceAll(RegExp(r'\s+'), ' ');
      final numericValue = rating.group(2) ?? rating.group(4);
      final operator = switch (word) {
        'less than' || 'below' || 'under' => 'less_than',
        'at least' => 'greater_than_equal',
        'at most' => 'less_than_equal',
        'equal to' || 'equals' => 'equals',
        _ => 'greater_than',
      };
      final column = resolveSemantic('rating');
      if (column != null && numericValue != null) {
        filters.add({
          'column': column,
          'operator': operator,
          'value': numericValue.replaceAll(',', '.'),
        });
      }
    }

    if (filters.isEmpty) return null;
    return {'intent': 'filter', 'logic': 'AND', 'filters': filters};
  }

  bool _looksLikePlannerValue(String value) {
    final text = value.trim();
    if (text.length < 2 || text.length > 80) return false;
    if (double.tryParse(text.replaceAll(',', '')) != null) return false;
    if (RegExp(r'^\d{1,4}(?:[./-]\d{1,4}){1,3}$').hasMatch(text)) return false;
    final lower = text.toLowerCase();
    return lower != 'yes' &&
        lower != 'no' &&
        lower != 'true' &&
        lower != 'false' &&
        RegExp(r'[a-zA-Z]').hasMatch(text);
  }

  Future<_FilterPlannerPrivacyContext?> _buildFilterPlannerPrivacyContext(
    String query,
  ) async {
    final rawData = await _fetchSourceData();
    if (rawData == null) return null;
    try {
      final List<dynamic> parsed = decodeSourceMatrix(rawData);
      if (parsed.isEmpty || parsed.first is! List) return null;

      final headerRow = List<dynamic>.from(
        parsed.first,
      ).map((e) => e.toString().trim()).toList();
      if (headerRow.isEmpty) return null;

      final candidates = <String>{};
      for (
        var rowIndex = 1;
        rowIndex < parsed.length && candidates.length < 250;
        rowIndex++
      ) {
        final row = parsed[rowIndex];
        if (row is! List) continue;
        for (
          var colIndex = 0;
          colIndex < row.length && candidates.length < 250;
          colIndex++
        ) {
          final value = row[colIndex]?.toString().trim() ?? '';
          if (value.isEmpty || !_looksLikePlannerValue(value)) continue;
          candidates.add(value);
        }
      }

      final placeholderToValue = <String, String>{};
      var placeholderIndex = 1;
      final orderedCandidates = candidates.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      var sanitizedQuery = query;
      for (final candidate in orderedCandidates) {
        final placeholder =
            'ENTITY_${placeholderIndex.toString().padLeft(3, '0')}';
        final pattern = RegExp(
          r'(?<!\w)' + RegExp.escape(candidate) + r'(?!\w)',
          caseSensitive: false,
        );
        if (!pattern.hasMatch(sanitizedQuery)) continue;
        sanitizedQuery = sanitizedQuery.replaceAll(pattern, placeholder);
        placeholderToValue[placeholder] = candidate;
        placeholderIndex++;
      }

      if (sanitizedQuery == query && placeholderToValue.isEmpty) {
        return _FilterPlannerPrivacyContext(
          sanitizedQuery: query,
          valuePlaceholders: const <String, String>{},
        );
      }
      return _FilterPlannerPrivacyContext(
        sanitizedQuery: sanitizedQuery,
        valuePlaceholders: placeholderToValue,
      );
    } catch (_) {
      return null;
    }
  }

  String _applyRankingLimit(String query, RankingLimitChoice choice, bool descending) {
    final suffix = choice.all ? ' all' : ' ' + (descending ? 'top ' : 'bottom ') + choice.limit.toString();
    return query + suffix;
  }

  Future<bool> _handleRankingSelection({
    required String originalQuery,
    required Map<String, dynamic> operation,
  }) async {
    final groupBy = operation['group_by'] is List ? List<dynamic>.from(operation['group_by']) : <dynamic>[];
    final groupingColumn = groupBy.isNotEmpty ? groupBy.first.toString() : 'results';
    final availableCount = (operation['available_count'] as num?)?.toInt() ?? 0;
    final descending = operation['sort']?.toString() != 'asc';
    if (!mounted) return true;

    final choice = await RankingLimitDialog.show(
      context: context,
      descending: descending,
      groupingColumn: groupingColumn,
      availableCount: availableCount,
    );
    if (!mounted) return true;
    if (choice == null) {
      setState(() {
        isSearchingChat = false;
        chatHistory.add({
          'sender': 'system',
          'text': 'Ranking cancelled. The original worksheet was not changed.',
        });
      });
      return true;
    }
    await _executeSmartQuery(_applyRankingLimit(originalQuery, choice, descending));
    return true;
  }

  // Secure grouped-count and quality requests are claimed before the generic
  // filter planner. Grouped analytics must never be interpreted as row filters.
  Future<bool> _tryExecuteSecureExcelLocalQuery(String query) async {
    if (!secureLocalOnly || !SecureExcelLocalService.supportsQuery(query)) {
      return false;
    }
    await _executeSmartQuery(query);
    return true;
  }

  Future<bool> _tryExecuteLocalNaturalFilterQuery(String query) async {
    final text = query.trim();
    if (text.isEmpty) return false;
    final lower = text.toLowerCase();

    final isFilterWording =
        RegExp(
          r'^(show|find|filter|display|list|give|fetch|view|return)\b',
          caseSensitive: false,
        ).hasMatch(lower) ||
        lower.contains(' having ') ||
        lower.contains(' where ') ||
        lower.contains(' with ');
    if (!isFilterWording) return false;

    if (detectedHeaders.isEmpty) return false;

    final privacyContext = await _buildFilterPlannerPrivacyContext(text);
    Map<String, dynamic>? plan;
    if (privacyContext != null) {
      final response = await parseAgenticFilterPlan(
        userText: privacyContext.sanitizedQuery,
        availableColumns: detectedHeaders,
      );
      if (response['success'] == true && response['plan'] is Map) {
        plan = Map<String, dynamic>.from(response['plan'] as Map);
        plan = Map<String, dynamic>.from(
          OutboundPrivacyGuard.remapValues(
                plan,
                privacyContext.valuePlaceholders,
              )
              as Map,
        );
      } else {
        // Never fall through to the general agent for a request that already
        // looks like a row filter. That was the source of the apparent
        // "Processing" hang when the dedicated planner was slow/unavailable.
        plan = _buildResilientFilterPlan(text);
        if (plan == null) {
          return _reportLocalFilterFailure(
            response['error']?.toString() ??
                'The generic filter planner is unavailable.',
          );
        }
      }
    } else {
      plan = _buildResilientFilterPlan(text);
      if (plan == null) {
        return _reportLocalFilterFailure(
          'The generic filter planner is unavailable.',
        );
      }
    }

    if (plan['intent'] != 'filter') return false;
    final logic = (plan['logic']?.toString() ?? 'AND').toUpperCase();
    if (logic != 'AND') {
      return _reportLocalFilterFailure(
        'This filter plan uses OR logic, which is not supported by the local Excel fast path yet.',
      );
    }

    final rawFilters = plan['filters'];
    if (rawFilters is! List || rawFilters.isEmpty) return false;

    final steps = <Map<String, dynamic>>[];
    for (final raw in rawFilters) {
      if (raw is! Map) {
        return _reportLocalFilterFailure(
          'The filter planner returned an invalid predicate.',
        );
      }
      final filter = Map<String, dynamic>.from(raw);
      final column = filter['column']?.toString().trim() ?? '';
      final operator =
          filter['operator']?.toString().trim().toLowerCase() ?? '';
      if (column.isEmpty || operator.isEmpty) {
        return _reportLocalFilterFailure(
          'The filter planner returned an incomplete predicate.',
        );
      }
      if (!const {
        'equals',
        'not_equals',
        'contains',
        'greater_than',
        'less_than',
        'greater_than_equal',
        'less_than_equal',
        'between',
      }.contains(operator)) {
        return _reportLocalFilterFailure(
          "Unsupported filter operator '$operator'.",
        );
      }

      final step = <String, dynamic>{
        'op': 'filter_rows',
        'column': column,
        'operator': operator,
        'value': filter['value'],
      };
      if (operator == 'between') step['value2'] = filter['value2'];
      steps.add(step);
    }

    final result = await _runLocalFilterSteps(
      steps,
      _filterResultSheetNameFromQuery(text),
    );
    if (!mounted) return true;
    setState(() {
      isSearchingChat = false;
      chatHistory.add({
        'sender': 'system',
        'text': result['success'] == true
            ? (result['stepSummary'] ?? '✅ Filter applied locally.')
            : '❌ ${result['error'] ?? 'The filter could not be applied.'}',
      });
    });
    if (result['success'] == true) {
      await refreshWorksheetNames();
      await syncHeadersSilently();
    }
    return true;
  }

  Future<bool> _reportLocalFilterFailure(String message) async {
    if (!mounted) return true;
    setState(() {
      isSearchingChat = false;
      chatHistory.add({'sender': 'system', 'text': '❌ $message'});
    });
    return true;
  }

  String _filterResultSheetNameFromQuery(String query) {
    final lower = query.toLowerCase();
    final parts = <String>[];

    // Include a named restaurant/entity in the result sheet name, e.g.
    // Restaurant_online_delivery_online_table_booking_rating_more_than_3_5.
    final entityMatch = RegExp(
      r"\b(?:show|find|filter|display|list|give|fetch|view)\s+(.+?)\s+restaurants?\b",
      caseSensitive: false,
    ).firstMatch(query);
    if (entityMatch != null) {
      var entity = entityMatch.group(1)?.trim() ?? '';
      entity = entity
          .replaceFirst(RegExp(r'^me\s+', caseSensitive: false), '')
          .trim();
      if (entity.isNotEmpty &&
          !{
            'restaurant',
            'restaurants',
            'all',
            'the',
            'some',
          }.contains(entity.toLowerCase())) {
        parts.add(sheetSafe(entity));
      }
    }

    if (lower.contains('rating')) {
      final m = RegExp(
        r'\bratings?\b[^0-9]{0,24}(above|over|greater\s+than|more\s+than|at\s+least|below|under|less\s+than|fewer\s+than|at\s+most|equals?|equal\s+to)\s*(-?\d+(?:[.,]\d+)?)',
        caseSensitive: false,
      ).firstMatch(lower);
      if (m != null)
        parts.add(
          'rating_${m.group(1)!.replaceAll(RegExp(r'\s+'), '_')}_${m.group(2)}',
        );
    }
    if (lower.contains('online delivery') ||
        RegExp(r'\bdelivery\b').hasMatch(lower))
      parts.add('online_delivery');
    if (lower.contains('online table booking') ||
        lower.contains('table booking'))
      parts.add('online_table_booking');
    final locationMatch = RegExp(
      r"\b(?:in|at|near|around|within)\s+([A-Za-z][A-Za-z .\-'&]{0,48}?)(?=\s+(?:having|with|where|whose|and)\b|\s*$)",
      caseSensitive: false,
    ).firstMatch(lower);
    if (locationMatch != null) {
      final location = locationMatch.group(1)?.trim();
      if (location != null && location.isNotEmpty) {
        parts.add(sheetSafe(location));
      }
    }
    return parts.isEmpty ? 'Filtered_Result' : parts.join('_');
  }

  Future<void> processChatQuery() async {
    final query = chatController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      isSearchingChat = true;
      chatHistory.add({"sender": "user", "text": query});
      chatController.clear();
    });

    final lowerQuery = query.toLowerCase();
    if (dataSourceMode != DataSourceMode.uploadedFile && kIsWeb) {
      try {
        await _ensureAnalyticalSourceSheet();
        await syncHeadersSilently();
      } catch (e) {
        setState(() {
          isSearchingChat = false;
          chatHistory.add({"sender": "system", "text": "❌ " + e.toString()});
        });
        return;
      }
    }
    final isCategorizationQuery = RegExp(
      r'\b(?:categorize|categorise|classification|classify|categorization|categorisation)\b',
      caseSensitive: false,
    ).hasMatch(lowerQuery);

    // Secure worksheet analytics must win over generic filter interpretation.
    final bool localSecureHandled = await _tryExecuteSecureExcelLocalQuery(query);
    if (localSecureHandled) return;

    // Gemini is the primary natural-language planner. It receives only the
    // user query + detected column names; the workbook rows stay local. The
    // returned structured predicates are validated and executed locally.
    final bool localFilterHandled = await _tryExecuteLocalNaturalFilterQuery(
      query,
    );
    if (localFilterHandled) return;

    // Sentiment/customer-satisfaction requests are data-analysis questions,
    // not spreadsheet transformation commands. Route them directly so a
    // failure in the general agentic command parser cannot block the request.
    final isSentimentQuery =
        lowerQuery.contains('sentiment') ||
        lowerQuery.contains('sentement') ||
        lowerQuery.contains('customer satisfaction') ||
        lowerQuery.contains('satisfaction') ||
        lowerQuery.contains('review sentiment') ||
        lowerQuery.contains('based on review') ||
        lowerQuery.contains('based on reviews') ||
        lowerQuery.contains('customer feedback') ||
        lowerQuery.contains('review tone') ||
        lowerQuery.contains('how restaurants are performing');
    if (isSentimentQuery) {
      await _executeSmartQuery(query);
      return;
    }

    if (isCategorizationQuery) {
      final parsed = await parseAgenticCommand(
        userText: query,
        availableColumns: detectedHeaders,
        availableSheets: availableSheets,
      );
      final String action = (parsed["action"] ?? "categorize").toString();
      final double confidence = (parsed["confidence"] is num)
          ? (parsed["confidence"] as num).toDouble()
          : 0.0;
      debugPrint(
        "[agentic_command] categorization action=$action confidence=$confidence raw=$parsed",
      );
      await _dispatchParsedOperation(
        action == "unknown" ? "categorize" : action,
        action == "unknown"
            ? {
                ...parsed,
                "action": "categorize",
                "categorize": parsed["categorize"] is Map
                    ? Map<String, dynamic>.from(parsed["categorize"] as Map)
                    : <String, dynamic>{},
              }
            : parsed,
      );
      return;
    }

    final parsed = await parseAgenticCommand(
      userText: query,
      availableColumns: detectedHeaders,
      availableSheets: availableSheets,
    );

    final String action = (parsed["action"] ?? "unknown").toString();
    final double confidence = (parsed["confidence"] is num)
        ? (parsed["confidence"] as num).toDouble()
        : 0.0;

    // DEBUG: leave this in temporarily to confirm routing while testing —
    // remove once you've verified classification is reliable.
    debugPrint(
      "[agentic_command] action=$action confidence=$confidence raw=$parsed",
    );

    if (action != "unknown" && action.isNotEmpty && confidence >= 0.4) {
      // Fast path — no file upload needed, the backend already told us
      // exactly what to do. _dispatchParsedOperation itself decides
      // between the legacy Excel-side executors (pivot/filter/dedupe/...)
      // and the generic Enterprise Transformation Engine path — every
      // confidently-classified action is accepted here, not just a fixed
      // set of names, so new backend transformations work without any
      // Flutter change.
      await _dispatchParsedOperation(action, parsed);
      return;
    }

    // ── The agentic classifier didn't recognize this as a direct sheet
    // operation, or wasn't confident. We do NOT silently fall back to the
    // legacy sklearn classifier (`executeNaturalCommand` / `/parse_command`)
    // for everything anymore — it has no concept of add_column (or of
    // analytical questions at all) and will happily misclassify things as
    // "aggregate"/"create_sheet_with_aggregation", creating a new sheet and
    // potentially corrupting columns it was never asked to touch.
    //
    // The legacy classifier is still genuinely useful for a small set of
    // intents the newer agents don't cover at all: create_sheet, copy_sheet,
    // show_preview, list_sheets, generate_metrics, clean_data. Route to it
    // ONLY when the wording clearly matches one of those.
    const legacyOnlyKeywords = [
      "create a new sheet",
      "create sheet",
      "blank sheet",
      "copy sheet",
      "duplicate sheet",
      "show preview",
      "preview data",
      "list sheets",
      "list all sheets",
      "generate metrics",
      "metrics sheet",
      "summary sheet",
      "clean data",
      "clean the data",
    ];
    if (legacyOnlyKeywords.any((kw) => lowerQuery.contains(kw))) {
      final response = await executeNaturalCommand(
        userText: query,
        availableColumns: detectedHeaders,
        availableSheets: availableSheets,
      );
      setState(() {
        isSearchingChat = false;
        chatHistory.add({
          "sender": "system",
          "text": response["message"] ?? "Execution loop unhandled.",
        });
      });
      await refreshWorksheetNames();
      await syncHeadersSilently();
      return;
    }

    // Anything else — most likely an analytical QUESTION (e.g. "compare
    // revenue between new and returning customers") rather than a direct
    // sheet operation. Route through /smart_query: it uploads the current
    // data and lets query_router.py's LLM decide SQL vs. operation, running
    // a real DuckDB query for the former instead of just asking the user
    // to rephrase.
    await _executeSmartQuery(query);
  }

  // Actions that predate the Enterprise Transformation Engine and have
  // dedicated Excel-side executors below (real PivotTable objects, native
  // conditional-formatting colour scales, etc. — things that can't be
  // produced by just writing operation.data into a sheet). This list only
  // decides WHICH dispatch path handles a known action; it is no longer
  // used to gate acceptance — any action outside it still runs, generically,
  // via _applyGenericTransformation/TransformationManager.
  static const List<String> _kLegacyExcelActions = [
    "pivot",
    "filter",
    "deduplicate",
    "color_scale",
    "add_column",
    "fill_missing",
    "multi_step",
    "categorize",
    "detect_locations",
  ];

  // ── Shared dispatcher ─────────────────────────────────────────────────
  // Dispatches an already-parsed action to the matching executor. Used both
  // by the fast path above (parsed directly from /agentic_command) and by
  // _executeSmartQuery below (parsed["operation"] nested inside a
  // /smart_query "operation" response) — the JSON shape is identical either
  // way. Known legacy actions keep using their existing dedicated
  // executors unchanged; every other action — including every Enterprise
  // Transformation Engine action, present or future — is handled
  // automatically through TransformationManager.
  Future<void> _dispatchParsedOperation(
    String action,
    Map<String, dynamic> parsed,
  ) async {
    final permission = action == "pivot" ? "pivot.create" : "worksheet.modify";
    final authorized = await authorizeExcelOperation(
      backendBaseUrl: _backendBaseUrl,
      action: permission,
      resourceId: activeSheetName,
    );
    if (!authorized) {
      if (mounted) {
        setState(() {
          isSearchingChat = false;
          chatHistory.add({
            "sender": "system",
            "text": "You are not authorized to perform this Excel operation in the current workspace.",
          });
        });
      }
      return;
    }
    if (!_kLegacyExcelActions.contains(action) && action != "unknown") {
      await _applyGenericTransformation(parsed);
      return;
    }

    final String replyMessage = parsed["message"]?.toString() ?? "Done.";
    Map<String, dynamic> result;
    try {
      switch (action) {
        case "pivot":
          final String pivotUserText = chatHistory.reversed.firstWhere((entry) => entry["sender"] == "user", orElse: () => {"text": ""})["text"]?.toString() ?? "";
          final bool combinedChartRequested = RegExp(r"\b(chart|pivotchart)\b", caseSensitive: false).hasMatch(pivotUserText);
          final bool explicitPivotChart = RegExp(r"\bpivotchart\b", caseSensitive: false).hasMatch(pivotUserText);
          final pivotConfig = parsed["pivot"] is Map ? Map<String, dynamic>.from(parsed["pivot"] as Map) : <String, dynamic>{};
          final lower = pivotUserText.toLowerCase();
          if (combinedChartRequested) {
            final topMatch = RegExp(r"\btop\s+(\d+)\b", caseSensitive: false).firstMatch(pivotUserText);
            final limit = topMatch == null ? null : int.tryParse(topMatch.group(1)!);
            pivotConfig["sortByValue"] = "descending";
            if (limit != null && limit > 0) pivotConfig["limit"] = limit;
            pivotConfig["hideGrandTotals"] = true;
            final existingName = (pivotConfig["sheetName"]?.toString().trim().isNotEmpty ?? false) ? pivotConfig["sheetName"].toString().trim() : "Pivot Analysis";
            pivotConfig["reuseExisting"] = availableSheets.contains(existingName);
            pivotConfig["tableName"] = "Pivot_InsightFlow_Combined";
          }
          result = await _executeAgenticPivot(pivotConfig);
          if (combinedChartRequested && result["success"] == true) {
            final placement = result["pivotPlacement"] is Map ? Map<String, dynamic>.from(result["pivotPlacement"] as Map) : <String, dynamic>{};
            final chartType = lower.contains("pie") ? "pie" : (lower.contains("line") ? "line" : (lower.contains("column") ? "column" : "bar"));
            final rowField = (pivotConfig["rowFields"] is List && (pivotConfig["rowFields"] as List).isNotEmpty) ? (pivotConfig["rowFields"] as List).first.toString() : "Category";
            final valueEntry = (pivotConfig["valueFields"] is List && (pivotConfig["valueFields"] as List).isNotEmpty && (pivotConfig["valueFields"] as List).first is Map) ? Map<String, dynamic>.from((pivotConfig["valueFields"] as List).first as Map) : <String, dynamic>{};
            final valueField = valueEntry["field"]?.toString() ?? "Value";
            final valueOp = valueEntry["op"]?.toString().toLowerCase() ?? "sum";
            final opLabel = valueOp == "average" ? "Average" : (valueOp == "count" ? "Count" : (valueOp == "max" ? "Max" : (valueOp == "min" ? "Min" : "Total")));
            final limit = pivotConfig["limit"] is num ? (pivotConfig["limit"] as num).toInt() : null;
            final title = (limit != null ? "Top " + limit.toString() + " " : "") + rowField + " by " + opLabel + " " + valueField;
            final chartResult = await createNativeExcelChart(json.encode({
              "sheetName": placement["sheet"], "sourceRangeAddress": placement["pivotRangeAddress"],
              "columns": [rowField, valueField], "rows": const [{}], "categoryColumnIndex": 0, "valueColumnIndex": 1,
              "chartType": chartType, "title": title, "chartName": "InsightFlow_Pivot_Chart",
              "startCell": placement["chartStartCell"] ?? "D1", "endCell": placement["chartEndCell"] ?? "L20",
            }));
            result = {...result, "combinedChartRequested": true, "explicitPivotChart": explicitPivotChart, "chartResult": chartResult};
          }
          break;
        case "filter":
          final String filterUserText =
              chatHistory.reversed
                  .firstWhere(
                    (entry) => entry["sender"] == "user",
                    orElse: () => {"text": ""},
                  )["text"]
                  ?.toString() ??
              "";
          result = await _executeAgenticFilter(
            parsed["filter"] is Map
                ? Map<String, dynamic>.from(parsed["filter"])
                : {},
            userText: filterUserText,
          );
          break;
        case "deduplicate":
          result = await _executeAgenticDeduplicate(
            parsed["deduplicate"] is Map
                ? Map<String, dynamic>.from(parsed["deduplicate"])
                : null,
          );
          break;
        case "color_scale":
          result = await _executeAgenticColorScale(
            parsed["color_scale"] is Map
                ? Map<String, dynamic>.from(parsed["color_scale"])
                : {},
          );
          break;
        case "add_column":
          result = await _executeAgenticAddColumn(
            parsed["add_column"] is Map
                ? Map<String, dynamic>.from(parsed["add_column"])
                : {},
          );
          break;
        case "fill_missing":
          result = await _executeAgenticFillMissing(
            parsed["fill_missing"] is Map
                ? Map<String, dynamic>.from(parsed["fill_missing"])
                : {},
          );
          break;
        case "multi_step":
          result = await _executeAgenticMultiStep(
            parsed["multi_step"] is Map
                ? Map<String, dynamic>.from(parsed["multi_step"])
                : {},
          );
          break;
        case "categorize":
          final String categorizationRequest =
              chatHistory.reversed
                  .firstWhere(
                    (entry) => entry["sender"] == "user",
                    orElse: () => {"text": replyMessage},
                  )["text"]
                  ?.toString() ??
              replyMessage;
          result = await _executeAgenticCategorization(
            categorizationRequest,
            parsed["categorize"] is Map
                ? Map<String, dynamic>.from(parsed["categorize"])
                : {},
          );
          break;
        case "detect_locations":
          result = await _executeAgenticLocationDetection();
          break;
        default:
          result = {
            "success": false,
            "error": "Unrecognized action '$action'.",
          };
      }
    } catch (e) {
      result = {"success": false, "error": e.toString()};
    }

    final bool success = result["success"] == true;
    // For fill_missing/multi_step, prefer the backend's own step-by-step
    // summary (built from cleaning_report["operations"]) over the LLM's
    // one-line message, since it reflects what ACTUALLY ran.
    String finalMessage =
        (action == "multi_step" || action == "fill_missing") &&
            success &&
            result["stepSummary"] != null
        ? result["stepSummary"].toString()
        : replyMessage;
    // Surface where the PivotTable actually landed (sheet + starting row),
    // straight from the placement metadata processExcelPipeline returned
    // (see PIVOT_GAP_ROWS/pivotPlacement in web/excel_helper.js) — rather
    // than silently discarding it once the write succeeds.
    if (action == "pivot" && success && result["pivotPlacement"] is Map) {
      final placement = Map<String, dynamic>.from(result["pivotPlacement"] as Map);
      final String mode = placement["mode"] == "append_existing_sheet" ? "appended below the existing table(s)" : "placed in a new worksheet";
      finalMessage = "$finalMessage (" + placement["sheet"].toString() + ", " + mode + ", starting at row " + placement["startingRow"].toString() + ")";
      if (result["combinedChartRequested"] == true) {
        final chartResult = result["chartResult"] is Map ? Map<String, dynamic>.from(result["chartResult"] as Map) : <String, dynamic>{};
        if (chartResult["success"] == true) {
          finalMessage += "\n📊 Editable native chart linked to the PivotTable output confirmed on '" + placement["sheet"].toString() + "' (" + (chartResult["chartName"]?.toString() ?? "InsightFlow_Pivot_Chart") + ").";
          if (result["explicitPivotChart"] == true) finalMessage += " Office.js exposes PivotChart options, but this supported add-in path does not expose a PivotChart creation method, so this is accurately reported as a regular native Excel chart backed by the PivotTable cells.";
        } else {
          finalMessage += "\n⚠️ Partial completion: PivotTable created and preserved on '" + placement["sheet"].toString() + "', but chart creation failed at " + (chartResult["stage"]?.toString() ?? "unknown stage") + ": " + (chartResult["error"]?.toString() ?? "unknown error") + ".";
        }
      }
    }
    setState(() {
      isSearchingChat = false;
      chatHistory.add({
        "sender": "system",
        "text": success
            ? "✅ $finalMessage"
            : "❌ Failed: ${result['error'] ?? 'Unknown error'}",
      });
    });
    await refreshWorksheetNames();
    await syncHeadersSilently();
  }

  Future<Map<String, dynamic>> _executeAgenticCategorization(
    String userText,
    Map<String, dynamic> config,
  ) async {
    try {
      final raw = await _fetchSourceData();
      if (raw == null)
        return {
          "success": false,
          "error": "Could not read the current worksheet data.",
        };
      final parsed = decodeSourceMatrix(raw);
      if (parsed.length < 2 || parsed.first is! List) {
        return {
          "success": false,
          "error": "The current worksheet has no tabular data to categorize.",
        };
      }
      final headers = List<dynamic>.from(
        parsed.first,
      ).map((e) => e?.toString() ?? '').toList();
      final rows = <Map<String, dynamic>>[];
      for (final rawRow in parsed.skip(1)) {
        if (rawRow is! List) continue;
        final row = <String, dynamic>{};
        for (var i = 0; i < headers.length; i++) {
          row[headers[i]] = i < rawRow.length ? rawRow[i] : null;
        }
        rows.add(row);
      }
      final response = await executeAgenticCategorization(
        userText: userText,
        rows: rows,
        categorize: config,
      );
      if (response["success"] == true &&
          response["local"] == true &&
          response["localRows"] is List) {
        final localMatrix = (response["localRows"] as List)
            .whereType<List>()
            .map((r) => List<dynamic>.from(r))
            .toList();
        final operation = response["operation"] is Map
            ? Map<String, dynamic>.from(response["operation"] as Map)
            : const <String, dynamic>{};
        final numberFormats = operation["numberFormats"] is Map
            ? Map<String, dynamic>.from(operation["numberFormats"] as Map)
            : const <String, dynamic>{};
        if (dataSourceMode == DataSourceMode.uploadedFile) {
          final originalName =
              uploadedFile?.fileName.replaceFirst(RegExp(r'\.[^.]+$'), '') ??
              'dataset';
          setState(() {
            uploadedFile = FileUploadResult(
              rows: localMatrix,
              fileName: '${originalName}_categorized.csv',
              formatLabel: 'LOCAL RESULT',
            );
            dataSourceMode = DataSourceMode.uploadedFile;
            analysisData = null;
            aiReport = null;
            reportText = null;
            reportError = null;
            _applyHeadersFromRows(localMatrix);
          });
          await analyzeData();
        } else {
          final headers = localMatrix.isNotEmpty
              ? localMatrix.first.map((e) => e?.toString() ?? '').toList()
              : <String>[];
          final data = localMatrix.length > 1
              ? localMatrix.sublist(1)
              : <List<dynamic>>[];
          final sheetName = _sanitizeSheetName(
            'Categorized_${DateTime.now().millisecondsSinceEpoch % 100000}',
          );
          final writeOptions = <String, dynamic>{
            'targetSheetName': sheetName,
            'columns': headers,
            'rows': data,
          };
          if (numberFormats.isNotEmpty) {
            writeOptions['metadata'] = {'number_formats': numberFormats};
          }
          final writeResult = await writeQueryResultToSheet(
            json.encode({...writeOptions}),
          );
          if (writeResult['success'] != true) {
            return {
              "success": false,
              "error":
                  "Local categorization completed but could not write the result sheet: ${writeResult['error'] ?? 'unknown error'}",
            };
          }
          await refreshWorksheetNames();
        }
        final operationMessage = response["operation"] is Map
            ? (response["operation"]["message"]?.toString() ??
                  "Categorization completed locally.")
            : "Categorization completed locally.";
        final diagnostics = response["diagnostics"] is Map
            ? Map<String, dynamic>.from(response["diagnostics"] as Map)
            : const <String, dynamic>{};
        final executionSummary = diagnostics.isNotEmpty
            ? "Execution: ${diagnostics['categorization_engine'] ?? 'local'}; Gemini used: ${diagnostics['ai_used'] == true ? 'yes' : 'no'}; privacy: ${diagnostics['privacy_mode'] ?? 'unknown'}."
            : null;
        return {
          "success": true,
          "message": executionSummary == null
              ? operationMessage
              : "$operationMessage\n$executionSummary",
        };
      }
      await _applyGenericTransformation(response);
      return {
        "success": response["success"] == true,
        "message": response["operation"] is Map
            ? (response["operation"]["message"]?.toString() ??
                  "Categorization completed.")
            : "Categorization completed.",
      };
    } catch (e) {
      return {
        "success": false,
        "error": "Could not prepare worksheet data for categorization: $e",
      };
    }
  }

  Future<Map<String, dynamic>> _executeAgenticLocationDetection() async {
    if (!kIsWeb)
      return {
        "success": false,
        "error": "Location enrichment is available in the Excel Web Add-in.",
      };
    try {
      final active = await getActiveWorksheetName();
      final raw = active == null
          ? await safeFetchActiveSheetData()
          : await fetchSheetData(active);
      if (raw == null)
        return {
          "success": false,
          "error": "Could not read the active Excel worksheet.",
        };
      final parsed = decodeSourceMatrix(raw);
      if (parsed.isEmpty || parsed.first is! List)
        return {
          "success": false,
          "error": "The active worksheet has no tabular data.",
        };
      final matrix = parsed.cast<List<dynamic>>();
      final headers = matrix.first
          .map((e) => e?.toString().trim() ?? '')
          .toList();
      await _maybeOfferLocationEnrichment(matrix, headers);
      return {"success": true, "message": "Location Agent scan completed."};
    } catch (e) {
      return {"success": false, "error": e.toString()};
    }
  }

  // ── Enterprise Transformation Engine — generic path ────────────────────
  // Handles any operation.action that isn't one of the legacy Excel-side
  // actions above. Parses/validates via TransformationManager, writes
  // operation.data back into the active sheet (so it becomes the active
  // dataset immediately, without another upload or a full rescan), and
  // refreshes schema/statistics/AI report/chart recommendation — all from
  // whatever the backend actually returned, with no per-action Flutter code.
  //
  // Accepts either shape:
  //   - already-enveloped: {success, route, operation: {...}}  (the
  //     /smart_query "operation" route)
  //   - flat: {action, message, preview, data, ...}             (the
  //     /agentic_command fast path, which has no envelope of its own)
  Future<void> _applyGenericTransformation(Map<String, dynamic> raw) async {
    _transformationManager.startRequest();

    final Map<String, dynamic> envelope = raw['operation'] is Map
        ? {
            'success': raw['success'] ?? true,
            'route': raw['route'] ?? 'operation',
            'operation': raw['operation'],
          }
        : {
            'success': raw['success'] ?? true,
            'route': 'operation',
            'operation': raw,
          };

    final TransformationResult result = _transformationManager.applyResponse(
      envelope,
    );
    final TransformationOperation op = result.operation;

    if (!result.success) {
      final String failureMessage = op.message.isNotEmpty
          ? op.message
          : "Transformation failed.";
      setState(() {
        isSearchingChat = false;
        chatHistory.add({"sender": "system", "text": "❌ $failureMessage"});
      });
      showError(failureMessage);
      return;
    }

    // Replace the active dataset in place, if the backend returned one —
    // writes into whatever sheet is currently the data source rather than
    // spawning a new sheet, so it becomes the active dataset immediately.
    //
    // When the transformation's metadata says it's formula-capable (e.g.
    // range binning — see formula_capable/formula_intervals in
    // common/transformations/range_binning.py::apply_range_binning), try
    // writing the new column as a LIVE Excel formula first, so it keeps
    // recalculating if the user edits the source cells afterward. This
    // path only appends the ONE new column and leaves everything else on
    // the sheet untouched, so it's tried BEFORE (and instead of) the full
    // static table rewrite below — per the "formulas whenever possible,
    // static values only as a fallback" requirement. Any other
    // transformation (no formula_capable metadata) falls straight through
    // to the existing static write-back, unchanged.
    String? writebackNote;
    bool formulaWritebackSucceeded = false;

    final Map<String, dynamic>? metadataRaw = op.metadata?.raw;
    final bool isFormulaCapable =
        metadataRaw?['formula_capable'] == true &&
        metadataRaw?['formula_intervals'] is List &&
        (metadataRaw!['formula_intervals'] as List).isNotEmpty;

    if (isFormulaCapable) {
      try {
        final String targetSheet = await _resolveWritebackSheetName();
        final formulaResult = await writeRangeBinningFormulas(
          json.encode({
            "sheetName": targetSheet,
            "sourceColumn": metadataRaw!['source_column'],
            "newColumn": metadataRaw['new_column'],
            "formulaIntervals": metadataRaw['formula_intervals'],
          }),
        );
        if (formulaResult["success"] == true) {
          formulaWritebackSucceeded = true;
          await refreshWorksheetNames();
          await syncHeadersSilently();
        }
        // No else/error note here on failure — falls through to the
        // static write-back below, which has its own error handling.
      } catch (_) {
        // Fall through to the static write-back below.
      }
    }

    if (!formulaWritebackSucceeded && op.data != null && !op.data!.isEmpty) {
      try {
        final String targetSheet = await _resolveWritebackSheetName();
        final writeResult = await writeQueryResultToSheet(
          json.encode({
            "targetSheetName": targetSheet,
            "columns": op.data!.columns,
            "rows": op.data!.rows,
            "metadata": metadataRaw ?? {},
          }),
        );
        if (writeResult["success"] == true) {
          await refreshWorksheetNames();
          await syncHeadersSilently();
        } else {
          writebackNote =
              "\n\n⚠️ Transformed data computed but could not be written to the sheet: "
              "${writeResult['error'] ?? 'unknown error'}";
        }
      } catch (e) {
        writebackNote =
            "\n\n⚠️ Transformed data computed but could not be written to the sheet: $e";
      }
    }

    // If the backend included an AI report alongside the transformation,
    // refresh the AI Report page automatically — no separate analysis run
    // required.
    final AiReport? updatedAiReport = _transformationManager.currentAiReport;

    final String previewNote = _formatOperationPreview(op.preview);
    final String successMessage = op.message.isNotEmpty
        ? op.message
        : "Transformation completed.";

    setState(() {
      isSearchingChat = false;
      if (updatedAiReport != null) {
        aiReport = updatedAiReport;
      }
      chatHistory.add({
        "sender": "system",
        "text": "✅ $successMessage$previewNote${writebackNote ?? ''}",
      });
    });
  }

  // Picks which sheet a transformed dataset should be written back into so
  // it becomes the active dataset: the explicitly-selected source sheet
  // when one is set, otherwise whatever sheet is actually active in Excel.
  Future<String> _resolveWritebackSheetName() async {
    if (!useActiveSelection && (selectedSourceSheet ?? "").isNotEmpty) {
      return selectedSourceSheet!;
    }
    final String? active = await getActiveWorksheetName();
    if (active != null && active.isNotEmpty) return active;
    return availableSheets.isNotEmpty ? availableSheets.first : "Sheet1";
  }

  // Renders operation.preview (when it carries a columns/rows table) as the
  // same compact text-table format already used for /smart_query SQL
  // results in chat — reused rather than building a second table renderer.
  String _formatOperationPreview(TransformationPreview? preview) {
    if (preview == null || !preview.hasTable) return "";
    final List<String> cols = preview.columns;
    final List<Map<String, dynamic>> rows = preview.rows.take(5).toList();
    final buffer = StringBuffer("\n\n");
    buffer.write(_formatSqlResultAsText(cols, rows));
    return buffer.toString();
  }

  String _queryDerivedSheetName(
    String query, {
    String fallback = "Query_Result",
  }) {
    var text = query.trim();
    if (text.isEmpty) return fallback;
    final match = RegExp(
      r"(?:show|filter|find|display|list)(?: me)?\s+(.+?)(?:\s+(?:where|having|with|whose)\s+.+)?$",
      caseSensitive: false,
    ).firstMatch(text);
    if (match != null) text = match.group(1)!.trim();
    text = text.replaceAll(RegExp(r"\bless than\b", caseSensitive: false), "<");
    text = text.replaceAll(
      RegExp(r"\bgreater than\b", caseSensitive: false),
      ">",
    );
    text = text.replaceAll(RegExp(r"\bunder\b", caseSensitive: false), "<");
    text = text.replaceAll(RegExp(r"\bover\b", caseSensitive: false), ">");
    text = text.replaceAll(RegExp(r"[^A-Za-z0-9_<>.= -]+"), " ");
    text = text.replaceAll(RegExp(r"\s+"), "_").replaceAll(RegExp(r"_+"), "_");
    text = text.replaceAll(RegExp(r"^_+|_+$"), "");
    return text.isEmpty
        ? fallback
        : text.substring(0, math.min(31, text.length));
  }

  // Excel sheet names: max 31 chars, and can't contain \ / ? * [ ] or be
  // empty/blank. Used when generating a fresh name for query-result sheets.
  String _sanitizeSheetName(String raw) {
    var cleaned = raw.replaceAll(RegExp(r'[\\/?*\[\]:]'), '_').trim();
    if (cleaned.isEmpty) cleaned = "Query_Result";
    return cleaned.length > 31 ? cleaned.substring(0, 31) : cleaned;
  }

  // Explicit, user-triggered action — wire this to a button/menu item such
  // as "Write cleaned data to sheet" on the report tab. It intentionally
  // does NOT run automatically after generateReport()/generateFocusedReport()
  // anymore: report generation only produces the report text. Only when the
  // user actively calls this does it take the AI cleaning step's result
  // (filled a null, dropped a duplicate row — signalled by
  // decoded['data_was_modified']) and write the FULL cleaned dataset into a
  // single brand-new sheet, so "filled with median" in the report text can
  // be backed by something visible in the workbook if the user wants that.
  Future<void> writeReportCleanedData() async {
    final decoded = _pendingReportCleanedData;
    if (decoded == null) {
      setState(() {
        reportCleanedSheetName = null;
        reportCleanedSheetError = "No report has been generated yet.";
      });
      return;
    }
    final bool wasModified = decoded['data_was_modified'] == true;
    final cleanedData = decoded['cleaned_data'];
    if (!wasModified || cleanedData is! Map) {
      setState(() {
        reportCleanedSheetName = null;
        reportCleanedSheetError =
            "This report's data needed no cleaning — nothing to write.";
      });
      return;
    }
    final List<dynamic> columns = cleanedData['columns'] is List
        ? cleanedData['columns']
        : [];
    final List<dynamic> rows = cleanedData['rows'] is List
        ? cleanedData['rows']
        : [];
    if (columns.isEmpty || rows.isEmpty) {
      setState(() {
        reportCleanedSheetName = null;
        reportCleanedSheetError = null;
      });
      return;
    }
    final sheetName = _sanitizeSheetName(
      "AI_Cleaned_${DateTime.now().millisecondsSinceEpoch % 100000}",
    );
    try {
      final writeResult = await writeQueryResultToSheet(
        json.encode({
          "targetSheetName": sheetName,
          "columns": columns,
          "rows": rows,
        }),
      );
      if (writeResult["success"] == true) {
        setState(() {
          reportCleanedSheetName = sheetName;
          reportCleanedSheetError = null;
        });
        await refreshWorksheetNames();
        await syncHeadersSilently();
      } else {
        setState(() {
          reportCleanedSheetName = null;
          reportCleanedSheetError =
              writeResult['error']?.toString() ?? 'Unknown error';
        });
      }
    } catch (e) {
      setState(() {
        reportCleanedSheetName = null;
        reportCleanedSheetError = e.toString();
      });
    }
  }

  // Builds the Excel-local data-understanding profile requested for a scan.
  // It intentionally uses only the selected worksheet matrix and returns
  // hypotheses as candidates, never as confirmed business relationships.
  Future<Map<String, dynamic>> _buildDataUnderstandingProfile() async {
    final source = await _fetchSourceData();
    if (source == null || source.isEmpty) return const {};
    final raw = decodeSourceMatrix(source);
    final rows = raw
        .whereType<List<dynamic>>()
        .where((r) => r.any((v) => v != null && v.toString().trim().isNotEmpty))
        .toList();
    if (rows.length < 2) return const {};

    final headers = rows.first.map((v) => (v ?? '').toString().trim()).toList();
    final data = rows.skip(1).toList();
    final schema = <Map<String, dynamic>>[];
    final primaryKeys = <String>[];
    final foreignKeys = <String>[];
    final suspicious = <Map<String, dynamic>>[];
    final inconsistencies = <Map<String, dynamic>>[];
    final dateHints = RegExp(
      r'(date|time|timestamp|month|year|day)',
      caseSensitive: false,
    );
    final idHints = RegExp(
      r'(^|[ _-])(id|key|code)([ _-]|$)',
      caseSensitive: false,
    );
    final textHints = RegExp(
      r'(review|comment|feedback|description|message|note|text)',
      caseSensitive: false,
    );
    final categoryHints = RegExp(
      r'(country|region|city|gender|status|type|category|segment|class)',
      caseSensitive: false,
    );
    final geoHints = RegExp(
      r'(latitude|longitude|(^|[ _-])lat([ _-]|$)|(^|[ _-])long([ _-]|$)|lng|coordinate)',
      caseSensitive: false,
    );

    for (var index = 0; index < headers.length; index++) {
      final name = headers[index].isEmpty
          ? 'Unnamed_${index + 1}'
          : headers[index];
      final values = data
          .map((row) => index < row.length ? row[index] : null)
          .toList();
      final present = values
          .where((v) => v != null && v.toString().trim().isNotEmpty)
          .toList();
      final normalized = present.map((v) => v.toString().trim()).toList();
      final unique = normalized.toSet().length;
      final low = name.toLowerCase();
      String role;
      if (geoHints.hasMatch(low)) {
        role = 'geographic_coordinate';
      } else if (dateHints.hasMatch(low)) {
        role = 'datetime';
      } else if (textHints.hasMatch(low)) {
        role = 'free_text';
      } else if (idHints.hasMatch(low) ||
          low.endsWith('id') ||
          low.endsWith('key') ||
          low.endsWith('code') ||
          ['id', 'key', 'code'].contains(low)) {
        role = 'identifier';
      } else if (categoryHints.hasMatch(low)) {
        role = 'categorical';
      } else if (present.isNotEmpty &&
          present.every(
            (v) => num.tryParse(v.toString().replaceAll(',', '')) != null,
          )) {
        role = 'numeric_measure';
      } else if (present.isNotEmpty &&
          normalized.every((v) => DateTime.tryParse(v) != null)) {
        role = 'datetime';
      } else {
        final averageLength = normalized.isEmpty
            ? 0
            : normalized.map((v) => v.length).reduce((a, b) => a + b) /
                  normalized.length;
        role =
            averageLength > 45 ||
                (normalized.isNotEmpty && unique / normalized.length > .8)
            ? 'free_text'
            : 'categorical';
      }
      final missing = values.length - present.length;
      final keyCandidate =
          data.isNotEmpty &&
          missing == 0 &&
          unique == data.length &&
          (role == 'identifier' || role == 'categorical');
      if (keyCandidate) primaryKeys.add(name);
      if (role == 'identifier' && !keyCandidate) foreignKeys.add(name);
      schema.add({
        'column': name,
        'dtype': role == 'numeric_measure'
            ? 'numeric'
            : role == 'datetime'
            ? 'datetime'
            : role == 'categorical'
            ? 'text/category'
            : role,
        'role': role,
        'non_null': present.length,
        'missing': missing,
        'unique': unique,
        'key_candidate': keyCandidate,
        'sample_values': normalized.take(3).toList(),
      });
      if (missing > 0)
        suspicious.add({'column': name, 'issue': '$missing missing value(s).'});
      if (unique == 1 && data.length > 1)
        suspicious.add({
          'column': name,
          'issue': 'Constant value across all non-empty records.',
        });
      if (role == 'numeric_measure' &&
          RegExp(
            r'(amount|price|sales|revenue|profit|cost|quantity|qty)',
            caseSensitive: false,
          ).hasMatch(low)) {
        final negatives = present
            .where(
              (v) => (num.tryParse(v.toString().replaceAll(',', '')) ?? 0) < 0,
            )
            .length;
        if (negatives > 0)
          suspicious.add({
            'column': name,
            'issue':
                '$negatives negative measure value(s); verify returns or adjustments.',
          });
      }
      final variants = <String, Set<String>>{};
      for (final value in normalized) {
        variants
            .putIfAbsent(
              value.toLowerCase().split(RegExp(r'\s+')).join(' '),
              () => <String>{},
            )
            .add(value);
      }
      final variantGroups = variants.values
          .where((v) => v.length > 1)
          .map((v) => v.toList()..sort())
          .take(8)
          .toList();
      if (variantGroups.isNotEmpty && role == 'categorical') {
        inconsistencies.add({
          'column': name,
          'variants': variantGroups,
          'issue': 'Values differ only by case or whitespace.',
        });
      }
    }

    final measures = schema
        .where((c) => c['role'] == 'numeric_measure')
        .map((c) => c['column'])
        .toList();
    final dimensions = schema
        .where(
          (c) => ['categorical', 'datetime', 'identifier'].contains(c['role']),
        )
        .map((c) => c['column'])
        .toList();
    final grain =
        'One row per observed record in the scanned worksheet.' +
        (primaryKeys.isNotEmpty
            ? ' Candidate row key: ${primaryKeys.first}.'
            : ' No reliable single-column row key was observed.');
    return {
      'dataset_overview': {
        'rows': data.length,
        'columns': headers.length,
        'grain': grain,
      },
      'schema': schema,
      'primary_key_candidates': primaryKeys,
      'foreign_key_candidates': foreignKeys,
      'relationships': [
        'Relationships to other tables cannot be verified from one scanned worksheet.',
      ],
      'invalid_or_suspicious_values': suspicious,
      'categorical_inconsistencies': inconsistencies,
      'fact_table_recommendation': measures.isNotEmpty
          ? 'Use the scanned table as the fact table if each row represents a business event or transaction.'
          : 'No clear numeric measures were observed; treat this as a descriptive entity table until business grain is confirmed.',
      'dimension_table_recommendation': [
        'Candidate dimensions are categorical, date, and identifier fields: ${dimensions.isEmpty ? 'none observed' : dimensions.join(', ')}.',
        'Confirm business ownership and grain before splitting the worksheet into separate dimensions.',
      ],
      'star_schema': {
        'fact_table': measures.isNotEmpty
            ? 'Fact_ScannedDataset'
            : 'Not yet determined',
        'measures': measures,
        'dimensions': dimensions,
        'relationships':
            'Join dimensions to the fact table through verified keys only.',
      },
      'assumptions': [
        'The first row supplied by Excel is the header row.',
        'The scanned worksheet represents one logical dataset, not multiple stacked tables.',
        'Key and relationship candidates are hypotheses and require business confirmation.',
      ],
    };
  }

  // Single source of truth for the Quality_Report worksheet payload. Both
  // the automatic per-scan sync (_syncQualityReport, below) and the explicit
  // "Export Full Quality Report" button (exportQualityReportToExcel, below)
  // build their payload through this one method and both call the one
  // worksheet-writing function, writeQualityReportWorksheet() — there is no
  // second implementation anywhere in the pipeline.
  //
  // SOURCE OF TRUTH — exactly mirrors what the Quality Tab displays:
  //
  // Quality Tab widget          → analysisData field
  // ─────────────────────────────────────────────────
  // overview_metrics.dart:
  //   Rows                      → analysisData['summary']['rows']
  //   Columns                   → analysisData['summary']['columns']
  //   Duplicate rows            → analysisData['duplicates']['count']
  //   (from duplicate_rows map) → analysisData['duplicates']
  //
  // quality_report.dart:
  //   Total null values         → sum(analysisData['missing_values'].values)
  //                               (client-side computed in _computeClientSideQualityStats)
  //   Columns affected          → count of missing_values entries > 0
  //   per-column null refs      → analysisData['missing_values'][colName]
  //                               (client-side computed)
  //   per-column unique         → analysisData['unique_values'][colName]
  //                               NOTE: stored at top level in decoded, not
  //                               under 'distribution' — quality_report.dart
  //                               reads distribution['unique_values'] but that
  //                               is the same object since decoded['unique_values']
  //                               is assigned from the client-side computation.
  //
  // Quality Score / Grade: NOT present anywhere in analysisData. The Quality
  // Tab does not display a Quality Score or Grade — these fields are only
  // populated when the AI report (/analyze-report) is generated and exist in
  // AiReport.dataQuality IF the backend includes them. If the AI report has
  // them, they'll appear via r.dataQuality below; if not, N/A is correct.
  //
  // [rawDecoded] is the raw analyzeData() response (passed by the automatic
  // sync so the worksheet reflects the freshest scan immediately without
  // waiting for a full AI report). [report] is the current AiReport (only
  // available after the user explicitly generates the AI report).
  Future<Map<String, dynamic>> _buildQualityReportPayload({
    Map<String, dynamic>? rawDecoded,
    AiReport? report,
    required bool activate,
  }) async {
    final r = report ?? const AiReport();
    final localProfile = await _buildDataUnderstandingProfile();

    final bool isUpload = dataSourceMode == DataSourceMode.uploadedFile;
    String? datasetName = isUpload ? uploadedFile?.fileName : null;
    datasetName ??=
        (!isUpload && !useActiveSelection && selectedSourceSheet != null)
        ? selectedSourceSheet
        : await getActiveWorksheetName();

    // Always prefer the freshest raw scan result; fall back to whatever is
    // already sitting in analysisData so the manual export button (which
    // never has a rawDecoded) gets the same numbers as the Quality Tab.
    final summarySource = rawDecoded ?? analysisData;
    final summary = (summarySource?['summary'] as Map?) ?? const {};
    final rows = summary['rows'];
    final List<dynamic>? columnNames = summary['column_names'] is List
        ? summary['column_names'] as List
        : null;
    final columns = summary['columns'] ?? columnNames?.length;

    // missing_values: {"ColName": count} — client-side computed in
    // _computeClientSideQualityStats, stored directly in decoded (overrides
    // backend). This is the EXACT same map quality_report.dart reads.
    final rawMissingValue = summarySource?['missing_values'];
    final Map<String, dynamic> missingValuesByColumn = rawMissingValue is Map
        ? Map<String, dynamic>.from(rawMissingValue)
        : const {};

    final int missingValues = missingValuesByColumn.values.fold<int>(
      0,
      (sum, v) => sum + (v is int ? v : int.tryParse(v.toString()) ?? 0),
    );

    // unique_values: {"ColName": count} — client-side computed, stored at
    // top level in decoded. Same values shown in the Unique column of the
    // Quality Tab table.
    final rawUniqueValues = summarySource?['unique_values'];
    final Map<String, dynamic> uniqueValuesByColumn = rawUniqueValues is Map
        ? Map<String, dynamic>.from(rawUniqueValues)
        : const {};

    // duplicate_values: per-column repeated occurrences beyond the first.
    final rawDuplicateValues = summarySource?['duplicate_values'];
    final Map<String, dynamic> duplicateValuesByColumn =
        rawDuplicateValues is Map
        ? Map<String, dynamic>.from(rawDuplicateValues)
        : const {};

    // duplicates: entire duplicates map, not just the count, so JS can
    // surface any extra detail the backend put in it.
    final rawDuplicates = summarySource?['duplicates'];
    final int? duplicateRows = (rawDuplicates is Map
        ? (rawDuplicates['count'] as num?)?.toInt()
        : null);

    // describe: the raw statistics matrix (list of row-maps) shown in the
    // Statistics section of the Analysis tab. Passed through so the Excel
    // report can reproduce the same table rather than showing nothing.
    final describeRaw = summarySource?['describe'];
    final List<dynamic> describeList = describeRaw is List
        ? List<dynamic>.from(describeRaw)
        : const [];

    // column_names list — the canonical ordered column list from the scan.
    // Passed explicitly so the JS knows the actual order and real names
    // without having to infer them from other maps.
    final List<dynamic> columnNameList = columnNames ?? const [];

    // dtypes: {"ColName": "dtype"} map for every dataset column.
    //
    // Source of truth: analysisData['summary']['dtypes']
    // Added to the backend's analyze_dataframe() return value as:
    //   df.dtypes.astype(str).to_dict()
    // inside the existing "summary" envelope (same envelope that already
    // holds rows/columns/column_names — adding here keeps the grouped shape
    // the existing widgets already depend on).
    //
    // The backend's /analyze response does NOT contain an 'info' key or a
    // 'dtype' row inside 'describe' — confirmed by reading main.py's
    // analyze_dataframe() directly. The only dtype source is summary['dtypes'].
    final rawDtypes = summary['dtypes'];
    final Map<String, dynamic> dtypesByColumn = rawDtypes is Map
        ? Map<String, dynamic>.from(rawDtypes)
        : const {};

    return {
      "sheetName": "Quality_Report",
      "activate": activate,
      "datasetName": datasetName ?? "Dataset",
      "generatedAt": DateTime.now().toLocal().toString(),
      "rows": rows,
      "columns": columns,
      "columnNames": columnNameList,
      "dtypesByColumn": dtypesByColumn,
      "missingValues": missingValues,
      "missingValuesByColumn": missingValuesByColumn,
      "uniqueValuesByColumn": uniqueValuesByColumn,
      "duplicateValuesByColumn": duplicateValuesByColumn,
      "duplicateRows": duplicateRows,
      "duplicatesRaw": rawDuplicates is Map
          ? Map<String, dynamic>.from(rawDuplicates)
          : const {},
      "describe": describeList,
      "dataQuality": r.dataQuality,
      "statistics": r.statistics,
      "executiveSummary": r.executiveSummary,
      "recommendations": r.recommendations,
      "outliers": r.outliers,
      "outlierAnalysisPresent": r.outliersAnalysisPresent,
      "chartRecommendation": r.chartRecommendation,
      // The AI report's free-text summary (r.report) — shown in report_tab.dart
      // via _buildReportCard when 'executive_summary' is selected. Passed through
      // so the Excel export can render the same text it shows in the UI.
      "reportText": r.report,
      "dataUnderstandingProfile": localProfile,
    };
  }

  // Explicit, user-triggered action — wired to the "EXPORT FULL QUALITY
  // REPORT TO EXCEL" button on the report tab, next to the Data Quality
  // card. Writes (or rewrites) the single "Quality_Report" worksheet via
  // writeQualityReportWorksheet() — the same function _syncQualityReport()
  // below uses for the automatic per-scan sync. This does NOT call the
  // backend again and does NOT recompute anything — see
  // web/excel_quality_report_generator.js for the worksheet builder, and
  // AiReport (ai_report_model.dart) for the fields being reused verbatim.
  Future<void> exportQualityReportToExcel() async {
    final report = aiReport;
    if (report == null || report.dataQuality.isEmpty) {
      setState(() {
        qualityReportSheetName = null;
        qualityReportExportError =
            "No Data Quality result available yet — generate the AI report first.";
      });
      return;
    }

    setState(() {
      isExportingQualityReport = true;
      qualityReportExportError = null;
    });

    try {
      final payloadMap = await _buildQualityReportPayload(
        report: report,
        activate: true,
      );
      final result = await writeQualityReportWorksheet(json.encode(payloadMap));
      if (result["success"] == true) {
        setState(() {
          qualityReportSheetName =
              result["sheet"]?.toString() ?? "Quality_Report";
          qualityReportExportError = null;
        });
        await refreshWorksheetNames();
      } else {
        setState(() {
          qualityReportSheetName = null;
          qualityReportExportError =
              result["error"]?.toString() ?? "Unknown error";
        });
      }
    } catch (e) {
      setState(() {
        qualityReportSheetName = null;
        qualityReportExportError = e.toString();
      });
    } finally {
      if (mounted) setState(() => isExportingQualityReport = false);
    }
  }

  // ── /smart_query wiring ────────────────────────────────────────────────
  // Uploads the currently loaded sheet's data (same CSV-building pattern as
  // analyzeData()/generateReport() elsewhere in this file) plus the user's
  // question to /smart_query, and handles BOTH routes the backend can
  // return:
  //   - route "sql": a real DuckDB query already ran — render result rows
  //     as a compact text table in chat.
  //   - route "operation": identical shape to /agentic_command's response,
  //     nested under "operation" — dispatched via _dispatchParsedOperation.
  Future<void> _executeSmartQuery(String userText) async {
    try {
      final lower = userText.toLowerCase();
      final isCategorizationQuery = RegExp(
        r'\b(?:categorize|categorise|classification|classify|categorization|categorisation)\b',
        caseSensitive: false,
      ).hasMatch(lower);
      if (secureLocalOnly && isCategorizationQuery) {
        final parsed = await parseAgenticCommand(
          userText: userText,
          availableColumns: detectedHeaders,
          availableSheets: availableSheets,
        );
        final action = (parsed["action"] ?? "categorize").toString();
        await _dispatchParsedOperation(
          action == "unknown" ? "categorize" : action,
          action == "unknown"
              ? {
                  ...parsed,
                  "action": "categorize",
                  "categorize": parsed["categorize"] is Map
                      ? Map<String, dynamic>.from(parsed["categorize"] as Map)
                      : <String, dynamic>{},
                }
              : parsed,
        );
        return;
      }
      // Explicit PivotTable requests are workbook operations, not remote analytics.
      // Classify them before SecureExcelLocalService/remote fallback so secure-local
      // mode cannot reject a request the existing Office.js PivotTable engine supports.
      final explicitPivotQuery = RegExp(
        r'\bpivot\s*table\b|\bpivottable\b',
        caseSensitive: false,
      ).hasMatch(lower);
      if (explicitPivotQuery) {
        final parsedPivot = await parseAgenticCommand(
          userText: userText,
          availableColumns: detectedHeaders,
          availableSheets: availableSheets,
        );
        if (parsedPivot['needsClarification'] == true) {
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": parsedPivot['message']?.toString() ?? 'Please specify the PivotTable measure.',
            });
          });
          return;
        }
        if ((parsedPivot['action'] ?? '').toString() == 'pivot') {
          await _dispatchParsedOperation('pivot', parsedPivot);
          return;
        }
      }

      if (secureLocalOnly && SecureExcelLocalService.supportsQuery(userText)) {
        final String? jsonString = await _fetchSourceData();
        if (jsonString == null || jsonString.isEmpty) {
          throw "No data found. Select a range or load a file first.";
        }
        final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
        if (rawRows.isEmpty || rawRows.first is! List) {
          throw "Unnrecognised data shape — expected a 2D array from Excel or file.";
        }
        final rows = rawRows
            .whereType<List<dynamic>>()
            .where((r) => r.any((c) => c != null && c.toString().trim().isNotEmpty))
            .toList();
        final localResult = await SecureExcelLocalService.execute(
          sourceRows: rows,
          query: userText,
        );
        if (localResult['success'] != true) {
          throw localResult['error']?.toString() ??
              'Local secure Excel analysis failed.';
        }
        final operation = localResult['operation'] is Map
            ? Map<String, dynamic>.from(localResult['operation'] as Map)
            : <String, dynamic>{};
        final action = operation['action']?.toString() ?? 'unknown';
        if (action == 'rank_selection') {
          await _handleRankingSelection(
            originalQuery: userText,
            operation: operation,
          );
          return;
        }
        if (action == 'clarification') {
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": operation['question']?.toString() ??
                  localResult['error']?.toString() ??
                  'Please clarify the requested measure.',
            });
          });
          return;
        }
        if (action == 'quality_check' && operation['source_mutated'] == true) {
          throw 'Local quality check unexpectedly reported source mutation.';
        }

        if (action == 'synthetic_column') {
          final sheetName = localResult['sheetName']?.toString();
          final columnName = localResult['generated_column']?.toString();
          final hypothetical = localResult['hypothetical'] == true;
          if (sheetName != null && sheetName.isNotEmpty) {
            useActiveSelection = false;
            selectedSourceSheet = sheetName;
            activeSheetName = sheetName;
          }
          await refreshWorksheetNames();
          await syncHeadersSilently();
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": "${localResult['message'] ?? 'Synthetic data was created successfully.'}"
                  "\n\nWorksheet: $sheetName"
                  "\nColumn: $columnName"
                  "\nHypothetical: $hypothetical"
                  "\nSource worksheet changed: No"
                  "\nThe original worksheet remains unchanged. Retrying this request will reuse the existing protected output worksheet instead of creating a duplicate.",
            });
          });
        } else if (action == 'group' || action == 'aggregate') {
          final columns = operation['columns'] is List
              ? List<dynamic>.from(operation['columns'])
              : <dynamic>[];
          final resultRows = operation['rows'] is List
              ? List<dynamic>.from(operation['rows'])
              : <dynamic>[];
          final tableText = _formatSqlResultAsText(columns, resultRows);
          String sheetNote = "";
          try {
            final agentName = await suggestAgenticSheetName(
              query: userText,
              operation: "query_result",
              context: {
                "result_columns": columns.map((e) => e.toString()).toList(),
              },
            );
            final sheetName = _sanitizeSheetName(
              agentName ??
                  _queryDerivedSheetName(userText, fallback: "Query_Result"),
            );
            final writeResult = await writeQueryResultToSheet(
              json.encode({
                "targetSheetName": sheetName,
                "columns": columns,
                "rows": resultRows,
              }),
            );
            if (writeResult["success"] == true) {
              sheetNote = "\n\n📄 Created and switched to sheet '$sheetName'.";
              await refreshWorksheetNames();
              await syncHeadersSilently();
              final chart = operation['chart'] is Map ? Map<String,dynamic>.from(operation['chart'] as Map) : null;
              final chartRequested = RegExp(r'\bchart\b', caseSensitive: false).hasMatch(userText);
              if (chartRequested && chart == null) {
                sheetNote += "\n⚠️ Partial completion: the result table was created, but the analytical plan did not contain a chart operation.";
              } else if (chart != null) {
                final chartResult = await createNativeExcelChart(json.encode({
                  'sheetName': sheetName,
                  'columns': columns,
                  'rows': resultRows,
                  'chartType': chart['chartType'],
                  'categoryColumn': chart['categoryColumn'],
                  'valueColumn': chart['valueColumn'],
                  'title': chart['title'],
                  'chartName': 'InsightFlow_Chart',
                  'startCell': 'D1',
                  'endCell': 'L20',
                  'limit': chart['limit'],
                }));
                if (chartResult['success'] == true) {
                  sheetNote += "\n📊 Editable native chart confirmed on '" + sheetName + "' (" + (chartResult['chartName']?.toString() ?? 'InsightFlow_Chart') + ").";
                } else {
                  sheetNote += "\n⚠️ Partial completion: table created on '" + sheetName + "', but chart creation failed: " + (chartResult['error']?.toString() ?? 'unknown error');
                }
              }
            } else {
              sheetNote =
                  "\n\n⚠️ Could not write results to a sheet: ${writeResult['error'] ?? 'unknown error'}";
            }
          } catch (e) {
            sheetNote = "\n\n⚠️ Could not write results to a sheet: $e";
          }
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": "${localResult['message'] ?? 'Here is what I found:'}\n\n$tableText$sheetNote",
            });
          });
        } else {
          final missing = operation['missing_by_column'] is Map
              ? Map<String, dynamic>.from(operation['missing_by_column'] as Map)
              : <String, dynamic>{};
          final duplicate = operation['duplicate_identifier'] is Map
              ? Map<String, dynamic>.from(operation['duplicate_identifier'] as Map)
              : <String, dynamic>{};
          final duplicateValues = duplicate['values'] is List
              ? List<dynamic>.from(duplicate['values'])
              : <dynamic>[];
          final missingText = missing.isEmpty
              ? 'Missing values: none'
              : 'Missing values: ${missing.entries.map((e) => '${e.key}=${e.value}').join(', ')}';
          final duplicateText = duplicate['status'] == 'ok'
              ? 'Duplicate ${duplicate['column'] ?? 'identifier'} values: ${duplicateValues.isEmpty ? 'none' : duplicateValues.join(', ')}\nDuplicate identifier rows: ${duplicate['duplicate_row_count'] ?? 0}'
              : 'Duplicate identifier check: ${duplicate['status'] ?? 'not available'}';
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text": "${localResult['message'] ?? 'Completed the data quality check locally.'}\n\n$missingText\n$duplicateText\nSource mutated: No",
            });
          });
        }
        return;
      }
      if (secureLocalOnly) {
        setState(() {
          isSearchingChat = false;
          chatHistory.add({
            "sender": "system",
            "text":
                "❌ Remote analytical queries are disabled in secure local mode. Local filters, sorting, and workbook operations still work.",
          });
        });
        return;
      }
      final String? jsonString = await _fetchSourceData();
      if (jsonString == null || jsonString.isEmpty) {
        throw "No data found. Select a range or load a file first.";
      }
      final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
      if (rawRows.isEmpty || rawRows.first is! List) {
        throw "Unrecognised data shape — expected a 2D array from Excel or file.";
      }
      final List<List<dynamic>> rows = rawRows
          .whereType<List<dynamic>>()
          .where(
            (r) => r.any((c) => c != null && c.toString().trim().isNotEmpty),
          )
          .toList();
      if (rows.length < 2) {
        throw "Dataset too small — needs at least a header row and one data row.";
      }
      final lowerQuery = userText.toLowerCase();
      final isSentimentQuery =
          lowerQuery.contains('sentiment') ||
          lowerQuery.contains('sentement') ||
          lowerQuery.contains('customer satisfaction') ||
          lowerQuery.contains('satisfaction') ||
          lowerQuery.contains('review sentiment') ||
          lowerQuery.contains('based on review') ||
          lowerQuery.contains('based on reviews') ||
          lowerQuery.contains('customer feedback') ||
          lowerQuery.contains('review tone') ||
          lowerQuery.contains('how restaurants are performing');

      // Sentiment only needs the review and restaurant columns. Sending the
      // whole workbook duplicates unnecessary data in browser and Render.
      List<List<dynamic>> requestRows = rows;
      if (isSentimentQuery) {
        final headers = rows.first
            .map((e) => e?.toString().trim() ?? '')
            .toList();
        int reviewIndex = headers.indexWhere(
          (h) =>
              h.toLowerCase().contains('review') &&
              (h.toLowerCase().contains('text') ||
                  h.toLowerCase().contains('comment') ||
                  h.toLowerCase().contains('content')),
        );
        if (reviewIndex < 0)
          reviewIndex = headers.indexWhere(
            (h) => h.toLowerCase().contains('review'),
          );
        final restaurantIndex = headers.indexWhere(
          (h) =>
              h.toLowerCase().contains('restaurant') &&
              h.toLowerCase().contains('name'),
        );
        if (reviewIndex >= 0) {
          final indices = <int>[reviewIndex];
          if (restaurantIndex >= 0 && restaurantIndex != reviewIndex)
            indices.add(restaurantIndex);
          requestRows = rows
              .map(
                (row) =>
                    indices.map((i) => i < row.length ? row[i] : null).toList(),
              )
              .toList();
        }
      }
      final String csvData = requestRows
          .map((row) => row.map(escapeCsvValue).join(','))
          .join('\n');

      final Map<String, dynamic> decoded;
      if (secureLocalOnly && isSentimentQuery) {
        final reviewIndex = rows.first.indexWhere((cell) {
          final header = cell?.toString().toLowerCase() ?? '';
          return header.contains('review') &&
              (header.contains('text') ||
                  header.contains('comment') ||
                  header.contains('content'));
        });
        final resolvedReviewIndex = reviewIndex >= 0
            ? reviewIndex
            : rows.first.indexWhere(
                (cell) =>
                    cell?.toString().toLowerCase().contains('review') == true,
              );
        final restaurantIndex = rows.first.indexWhere((cell) {
          final header = cell?.toString().toLowerCase() ?? '';
          return header.contains('restaurant') && header.contains('name');
        });
        if (resolvedReviewIndex < 0) {
          throw "Could not find a review text column for local sentiment analysis.";
        }
        final sentiment = await LocalCategorizationService.analyzeSentiment(
          sourceRows: rows,
          reviewColumn:
              rows.first[resolvedReviewIndex]?.toString() ?? 'ReviewText',
          restaurantColumn: restaurantIndex >= 0
              ? rows.first[restaurantIndex]?.toString()
              : null,
          batchSize: 150,
        );
        decoded = {
          'success': true,
          'route': 'sentiment',
          'message': 'Analyzed customer sentiment locally.',
          'sentiment': sentiment,
        };
      } else {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse(isSentimentQuery ? _sentimentUrl : _smartQueryUrl),
        );
        if (isSentimentQuery) {
          // Dedicated sentiment endpoint: bypasses the general-purpose router.
          request.fields['batch_size'] = '150';
          request.fields['include_details'] = 'false';
        } else {
          request.fields['text'] = userText;
          request.fields['available_sheets'] = json.encode(availableSheets);
        }
        request.files.add(
          http.MultipartFile.fromString(
            'file',
            csvData,
            filename: 'data_source.csv',
          ),
        );

        final streamedResponse = await request.send().timeout(
          isSentimentQuery
              ? _sentimentRequestTimeout
              : const Duration(seconds: 60),
        );
        final body = await streamedResponse.stream.bytesToString();
        decoded = decodeBackendResponse(
          body,
          statusCode: streamedResponse.statusCode,
        );
      }

      if (decoded.containsKey('error')) {
        throw decoded['error'].toString();
      }

      final String route = (decoded['route'] ?? 'unknown').toString();
      final bool success = decoded['success'] == true;

      if (route == 'sentiment') {
        if (!success) {
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text":
                  "❌ ${decoded['message'] ?? 'Could not analyze customer sentiment.'}",
            });
          });
          return;
        }

        final sentiment = decoded['sentiment'] is Map
            ? Map<String, dynamic>.from(decoded['sentiment'])
            : <String, dynamic>{};
        final overall = sentiment['overall'] is Map
            ? Map<String, dynamic>.from(sentiment['overall'])
            : <String, dynamic>{};
        final sentimentValues = sentiment['sentiment_values'] is List
            ? List<dynamic>.from(sentiment['sentiment_values'])
            : <dynamic>[];

        String sentimentSheetNote = "";
        try {
          if (sentimentValues.isNotEmpty) {
            final targetSheet = await _resolveWritebackSheetName();
            final writeSentiment = await appendStaticColumn(
              json.encode({
                "sheetName": targetSheet,
                "columnName": sentiment['sentiment_column'] ?? "Sentiment",
                "values": sentimentValues,
              }),
            );
            if (writeSentiment["success"] == true) {
              sentimentSheetNote =
                  "\n\n🧠 Sentiment column added to '$targetSheet'.";
            } else {
              sentimentSheetNote =
                  "\n\n⚠️ Could not add sentiment column: ${writeSentiment['error'] ?? 'unknown error'}";
            }
          }
          await refreshWorksheetNames();
          await syncHeadersSilently();
        } catch (e) {
          sentimentSheetNote = "\n\n⚠️ Could not write sentiment column: $e";
        }

        final String performance =
            "Reviews analyzed: ${overall['reviews_analyzed'] ?? 0}\n"
            "Positive: ${overall['positive'] ?? 0} | Neutral: ${overall['neutral'] ?? 0} | "
            "Negative: ${overall['negative'] ?? 0} | Mixed: ${overall['mixed'] ?? 0}\n"
            "Customer satisfaction: ${overall['satisfaction_rate'] ?? 0}%\n"
            "Average sentiment score: ${overall['average_score'] ?? 0}";

        setState(() {
          isSearchingChat = false;
          chatHistory.add({
            "sender": "system",
            "text":
                "${decoded['message'] ?? 'Customer sentiment analysis complete.'}\n\n$performance$sentimentSheetNote",
          });
        });
        return;
      }

      if (route == 'sql') {
        if (!success) {
          setState(() {
            isSearchingChat = false;
            chatHistory.add({
              "sender": "system",
              "text":
                  "❌ ${decoded['message'] ?? 'Could not answer that question.'}",
            });
          });
          return;
        }
        final result = decoded['result'] is Map
            ? Map<String, dynamic>.from(decoded['result'])
            : {};
        final List<dynamic> columns = result['columns'] is List
            ? result['columns']
            : [];
        final List<dynamic> resultRows = result['rows'] is List
            ? result['rows']
            : [];
        final String tableText = _formatSqlResultAsText(columns, resultRows);

        // Also write the same result into a sheet, not just chat — reuses
        // jsWriteQueryResultToSheet (excel_helper.js) via the interop layer.
        // Native Excel PivotTables can't group by a column that doesn't
        // exist yet (e.g. a computed "new vs returning" category), so this
        // writes a plain table instead — same data, just not a native
        // PivotTable object.
        String sheetNote = "";
        try {
          final agentName = await suggestAgenticSheetName(
            query: userText,
            operation: "query_result",
            context: {
              "result_columns": columns.map((e) => e.toString()).toList(),
            },
          );
          final sheetName = _sanitizeSheetName(
            agentName ??
                _queryDerivedSheetName(userText, fallback: "Query_Result"),
          );
          final writeResult = await writeQueryResultToSheet(
            json.encode({
              "targetSheetName": sheetName,
              "columns": columns,
              "rows": resultRows,
            }),
          );
          if (writeResult["success"] == true) {
            sheetNote = "\n\n📄 Created and switched to sheet '$sheetName'.";
            await refreshWorksheetNames();
            await syncHeadersSilently();
          } else {
            sheetNote =
                "\n\n⚠️ Could not write results to a sheet: ${writeResult['error'] ?? 'unknown error'}";
          }
        } catch (e) {
          sheetNote = "\n\n⚠️ Could not write results to a sheet: $e";
        }

        setState(() {
          isSearchingChat = false;
          chatHistory.add({
            "sender": "system",
            "text":
                "${decoded['message'] ?? 'Here is what I found:'}\n\n$tableText$sheetNote",
          });
        });
        return;
      }

      // route == "operation" — either the legacy pivot/filter/... shape
      // /agentic_command also produces, or a full Enterprise Transformation
      // Engine result (range_binning, rename_columns, drop_columns, ...).
      // Both are dispatched the same way — no action name is rejected here.
      final operation = decoded['operation'] is Map
          ? Map<String, dynamic>.from(decoded['operation'])
          : <String, dynamic>{};
      final String opAction = (operation['action'] ?? 'unknown').toString();
      final bool opSuccess = decoded['success'] == true;

      if (!opSuccess) {
        // Never show "I'm not sure..." for an actual backend transformation
        // failure (e.g. action "transformation_error") — always surface the
        // specific reason the backend gave.
        final String failureMessage =
            (operation['message'] ??
                    decoded['message'] ??
                    'Transformation failed.')
                .toString();
        setState(() {
          isSearchingChat = false;
          chatHistory.add({"sender": "system", "text": "❌ $failureMessage"});
        });
        showError(failureMessage);
        return;
      }

      if (_kLegacyExcelActions.contains(opAction)) {
        await _dispatchParsedOperation(opAction, operation);
      } else {
        await _applyGenericTransformation(decoded);
      }
    } catch (e) {
      setState(() {
        isSearchingChat = false;
        chatHistory.add({
          "sender": "system",
          "text": "❌ Failed: ${e.toString()}",
        });
      });
    }
  }

  // Renders SQL query-result rows as a compact, readable text table for the
  // chat bubble — no external table widget needed.
  String _formatSentimentSummaryAsText(
    List<dynamic> columns,
    List<dynamic> rows,
  ) {
    if (columns.isEmpty || rows.isEmpty)
      return "(no restaurant-level review data)";
    final headers = columns.map((c) => c.toString()).toList();
    final buffer = StringBuffer();
    buffer.writeln(headers.join(' | '));
    buffer.writeln(headers.map((h) => '-' * h.length).join(' | '));
    for (final row in rows.take(20)) {
      final Map<String, dynamic> r = row is Map
          ? Map<String, dynamic>.from(row)
          : {};
      buffer.writeln(headers.map((h) => (r[h] ?? '').toString()).join(' | '));
    }
    if (rows.length > 20)
      buffer.writeln("… and ${rows.length - 20} more restaurants");
    return buffer.toString();
  }

  String _formatSqlResultAsText(List<dynamic> columns, List<dynamic> rows) {
    if (columns.isEmpty || rows.isEmpty) return "(no rows returned)";
    final List<String> headers = columns.map((c) => c.toString()).toList();
    final buffer = StringBuffer();
    buffer.writeln(headers.join(' | '));
    buffer.writeln(headers.map((h) => '-' * h.length).join(' | '));
    for (final row in rows.take(50)) {
      final Map<String, dynamic> r = row is Map
          ? Map<String, dynamic>.from(row)
          : {};
      buffer.writeln(headers.map((h) => (r[h] ?? '').toString()).join(' | '));
    }
    if (rows.length > 50) {
      buffer.writeln("… and ${rows.length - 50} more rows");
    }
    return buffer.toString();
  }

  // ── Agentic command dispatchers ───────────────────────────────────────
  // Each builds the exact options shape executePipeline()/applyColorScale()
  // already expect (see runTransformationPipeline/runColorCodingPipeline
  // above) from the structured JSON the command_agent backend returns.

  // AI-triggered pivot creation — reuses the EXACT SAME placement dialog and
  // the exact same executePipeline()/processExcelPipeline() Excel writer as
  // manual pivot creation (runTransformationPipeline above). No separate
  // placement logic exists for the AI path.
  //
  // [placementOverride] lets a caller that already asked the placement
  // question once (see _dispatchParsedOperation) pass the answer straight
  // through instead of prompting again — this is how "ask once per AI
  // request, reuse for every pivot in that request" is meant to work.
  // NOTE: as of this backend version, command_agent.py's LLM response
  // schema only ever returns a single pivot per request (a lone "pivot"
  // object, not a list) — see command_agent.py's PIVOT_SCHEMA /
  // ACTION_SCHEMA. So today this function is only ever called once per AI
  // request, and [placementOverride] is unused by any current call site;
  // it exists so that if/when the backend schema is extended to return
  // multiple pivots (e.g. a "pivots": [...] list), _dispatchParsedOperation
  // can ask _promptPivotPlacement ONCE and loop this function over each
  // pivot config with the same override, with no further Flutter changes
  // needed here.
  Future<Map<String, dynamic>> _executeAgenticFilter(
    Map<String, dynamic> config, {
    String userText = "",
  }) async {
    final String? columnName = config["columnName"]?.toString();
    if (columnName == null || columnName.trim().isEmpty) {
      return {
        "success": false,
        "error": "Could not determine which column to filter on.",
      };
    }

    // Keep the original natural-language request for agentic sheet naming.
    // This produces names such as `rating_less_than_3_9` instead of a generic
    // `Filtered_Result`, while the actual filtering remains entirely local.
    final requestedSubject = userText.trim().isNotEmpty
        ? userText.trim()
        : [
            config["value"]?.toString() ?? "",
            columnName,
          ].where((s) => s.trim().isNotEmpty).join(" ");
    final agentName = await suggestAgenticSheetName(
      query: requestedSubject.isEmpty ? "Filter $columnName" : requestedSubject,
      operation: "filter",
      context: {
        "column": columnName,
        "type": config["type"]?.toString() ?? "equals",
        "value": config["value"]?.toString() ?? "",
      },
    );
    final options = {
      "sourceSheetName": (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      // Always a new sheet for filter results; name is agentically derived from the query.
      "targetSheetName": _sanitizeSheetName(
        agentName ??
            _queryDerivedSheetName(
              requestedSubject,
              fallback: "Filter_${sheetSafe(columnName)}",
            ),
      ),
      "createNewSheet": true,
      "freezeHeaderRow": true,
      "enableAutoFilter": true,
      "generateSummarySheet": false,
      "removeDuplicates": false,
      "filter": {
        "columnName": columnName,
        "type": config["type"]?.toString() ?? "equals",
        "value": config["value"]?.toString() ?? "",
        "value2": config["value2"]?.toString() ?? "",
      },
    };
    return await executePipeline(json.encode(options));
  }

  Future<Map<String, dynamic>> _executeAgenticDeduplicate(
    Map<String, dynamic>? config,
  ) async {
    final List<String>? columns = (config != null && config["columns"] is List)
        ? List<String>.from(
            (config["columns"] as List)
                .map((e) => (e ?? '').toString())
                .where((s) => s.isNotEmpty),
          )
        : null;
    final String tag = (columns != null && columns.isNotEmpty)
        ? columns.take(3).map(sheetSafe).join('_')
        : 'AllCols';
    final options = {
      "sourceSheetName": (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      // Always a new sheet for deduplicated results, per requirement.
      "targetSheetName":
          "Dedup_${tag}_${DateTime.now().millisecondsSinceEpoch % 10000}",
      "createNewSheet": true,
      "freezeHeaderRow": true,
      "enableAutoFilter": true,
      "generateSummarySheet": false,
      "removeDuplicates": true,
      "deduplicateColumns": columns,
      "filter": null,
    };
    return await executePipeline(json.encode(options));
  }

  Future<Map<String, dynamic>> _executeAgenticColorScale(
    Map<String, dynamic> config,
  ) async {
    final String? column = config["column"]?.toString();
    if (column == null || column.isEmpty) {
      return {
        "success": false,
        "error": "Could not determine which column to colour-format.",
      };
    }
    final options = {
      "sheetName": (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      "column": column,
      "hasHeaders": true,
      "scaleType": config["scaleType"]?.toString() ?? "3-color",
      "minColor": config["minColor"]?.toString() ?? "F8696B",
      "midColor": config["midColor"]?.toString() ?? "FFEB84",
      "maxColor": config["maxColor"]?.toString() ?? "63BE7B",
    };
    return await applyColorScale(json.encode(options));
  }

  // Adds a new persistent column. command_agent.py's add_column action has
  // two mutually-exclusive condition styles now: "condition" (group
  // aggregate — e.g. count of repeats per CustomerName) and "formula"
  // (row-wise arithmetic — e.g. checking TotalPrice against
  // UnitPrice*Quantity). This routes to whichever one the agent actually
  // populated and maps it onto addComputedColumn's expected addColumnConfig
  // shape (see excel_interop_web.dart / excel_data_processor.js).
  Future<Map<String, dynamic>> _executeAgenticAddColumn(
    Map<String, dynamic> config,
  ) async {
    final String newColumnName =
        (config["newColumnName"]?.toString().trim().isNotEmpty ?? false)
        ? config["newColumnName"].toString().trim()
        : "Customer_Status";

    final Map<String, dynamic> condition = config["condition"] is Map
        ? Map<String, dynamic>.from(config["condition"])
        : {};
    final Map<String, dynamic> formula = config["formula"] is Map
        ? Map<String, dynamic>.from(config["formula"])
        : {};

    final String? sourceColumn = condition["column"]?.toString();
    final String? rightExpression = formula["rightExpression"]?.toString();

    // Only treat this as formula mode if condition genuinely has nothing to
    // offer AND formula actually has an expression — avoids misrouting a
    // normal aggregate request just because "formula" came back as {}.
    final bool isFormulaMode =
        (sourceColumn == null || sourceColumn.isEmpty) &&
        rightExpression != null &&
        rightExpression.isNotEmpty;

    Map<String, dynamic> addColumnConfig;

    if (isFormulaMode) {
      addColumnConfig = {
        "newColumnName": newColumnName,
        "mode": formula["mode"]?.toString() ?? "compare",
        "leftExpression": formula["leftExpression"]?.toString(),
        "rightExpression": rightExpression,
        "operator": formula["operator"]?.toString() ?? "equals",
        "tolerance": formula["tolerance"] is num ? formula["tolerance"] : 0.01,
        "thenLabel": config["thenLabel"]?.toString() ?? "Match",
        "elseLabel": config["elseLabel"]?.toString() ?? "Mismatch",
      };
    } else {
      if (sourceColumn == null || sourceColumn.isEmpty) {
        return {
          "success": false,
          "error":
              "Could not determine which column to base the new column on.",
        };
      }
      final List<dynamic> partitionByRaw = condition["partitionBy"] is List
          ? condition["partitionBy"]
          : [sourceColumn];
      final List<String> partitionBy = partitionByRaw
          .map((e) => (e ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();

      addColumnConfig = {
        "newColumnName": newColumnName,
        "windowFunction": condition["windowFunction"]?.toString() ?? "count",
        "sourceColumn": sourceColumn,
        "partitionBy": partitionBy,
        "operator": condition["operator"]?.toString() ?? "greater_than",
        "value": condition["value"]?.toString() ?? "1",
        "thenLabel": config["thenLabel"]?.toString() ?? "Returning",
        "elseLabel": config["elseLabel"]?.toString() ?? "New",
      };
    }

    final options = {
      "sheetName": (!useActiveSelection && selectedSourceSheet != null)
          ? selectedSourceSheet
          : null,
      "hasHeaders": true,
      "addColumnConfig": addColumnConfig,
    };
    return await addComputedColumn(json.encode(options));
  }

  // ── Multi-step / fill-missing cleaning (chat commands, e.g. "lower the
  // column names and replace space with _, then remove 0 rating count,
  // then fill the null ratings with median or mode or mean based, then
  // remove duplicate id", or a single "fill review rating with median
  // value") ──
  //
  // command_agent.py's multi_step and fill_missing actions both return
  // step dict(s) matching data_cleaner.py's run_steps() dispatch exactly —
  // see _runCleaningSteps() below, which does the actual work: sends the
  // CURRENT sheet's data + the ordered steps to the existing /clean_data
  // route (it already runs config["steps"] in order via
  // DataCleaner.run_steps when present — see clean_dataframe() in
  // data_cleaner.py), then writes the ONE final cleaned result to a single
  // new sheet. No intermediate sheet is created per step, and no separate
  // "report" sheet is created — only the one cleaned-data sheet.

  Future<Map<String, dynamic>> _executeAgenticMultiStep(
    Map<String, dynamic> config,
  ) async {
    final List<dynamic> stepsRaw = config["steps"] is List
        ? config["steps"] as List
        : [];
    if (stepsRaw.isEmpty) {
      return {
        "success": false,
        "error": "Could not determine any cleaning steps from that request.",
      };
    }
    // Steps are forwarded to the backend exactly as the agent produced them
    // (op/column/operator/value/strategy/columns/subset/method) — the
    // backend's DataCleaner.run_steps() dispatch table matches this shape
    // 1:1, so nothing needs to be re-mapped here.
    final List<Map<String, dynamic>> steps = stepsRaw
        .whereType<Map>()
        .map((s) => Map<String, dynamic>.from(s))
        .toList();

    final String requestedSheetName =
        (config["outputSheetName"]?.toString().trim().isNotEmpty ?? false)
        ? config["outputSheetName"].toString().trim()
        : "Cleaned_Data";

    // A pipeline consisting only of filters is a pure local query operation.
    // Do not send the workbook/CSV to the remote /clean_data endpoint. This
    // also guarantees that multiple criteria use the same local semantics as
    // the working one-filter path and are applied cumulatively.
    final bool filterOnly =
        steps.isNotEmpty &&
        steps.every(
          (step) =>
              (step["op"]?.toString().trim().toLowerCase() ?? "") ==
              "filter_rows",
        );
    if (filterOnly) {
      return _runLocalFilterSteps(steps, requestedSheetName);
    }

    return _runCleaningSteps(steps, requestedSheetName);
  }

  // Single-column "fill missing values" command (e.g. "fill review rating
  // with median value", "fill blank ratings based on type", or "write missing
  // where Restaurant Name is missing"). Maps command_agent.py's fill_missing
  // shape onto a ONE-entry steps list and runs it through the same backend
  // cleaning pipeline used by multi_step. Literal "custom" values are passed
  // through unchanged; statistical strategies still use their normal logic.
  //
  // EXCEPTION: strategy "backtrack" never goes through that backend path at
  // all. Backtracking needs to read the ACTUAL Excel formula already stored
  // in another column (e.g. "check") to invert it — that formula only
  // exists in the live worksheet, not in the CSV-of-values snapshot the
  // backend cleaning pipeline works from. So it's dispatched straight to
  // the Excel interop layer instead, operating in place on the current
  // sheet exactly like _executeAgenticAddColumn does.
  Future<Map<String, dynamic>> _executeAgenticFillMissing(
    Map<String, dynamic> config,
  ) async {
    final String? column = config["column"]?.toString();
    if (column == null || column.isEmpty) {
      return {
        "success": false,
        "error": "Could not determine which column to fill.",
      };
    }

    final String rawStrategy =
        (config["strategy"]?.toString().trim().isNotEmpty ?? false)
        ? config["strategy"].toString().trim()
        : "auto";

    if (rawStrategy == "backtrack") {
      final options = {
        "sheetName": (!useActiveSelection && selectedSourceSheet != null)
            ? selectedSourceSheet
            : null,
        "targetColumn": column,
        "sourceFormulaColumn":
            (config["sourceFormulaColumn"]?.toString().trim().isNotEmpty ??
                false)
            ? config["sourceFormulaColumn"].toString().trim()
            : null,
      };
      return await backtrackFillMissing(json.encode(options));
    }

    // command_agent.py's single-action fill_missing uses "auto" for
    // "based on type"/unspecified; data_cleaner.py's run_steps expects
    // "smart" for that same behaviour (median for numeric, mode for
    // categorical). Explicit literal replacement uses "custom" and must
    // forward the exact value unchanged.
    String strategy = rawStrategy;
    if (strategy == "auto") strategy = "smart";

    final step = <String, dynamic>{
      "op": "handle_missing_values",
      "strategy": strategy,
      "columns": [column],
    };
    if (strategy == "custom") {
      final customValue = config["customValue"];
      if (customValue == null) {
        return {
          "success": false,
          "error":
              "A literal value is required for custom missing-value filling.",
        };
      }
      step["custom_value"] = customValue;
    }

    final steps = [step];
    return _runCleaningSteps(steps, "Filled_${sheetSafe(column)}");
  }

  // Filter-only multi-step requests are executed entirely in the local
  // Excel process.  This is important for BOTH correctness and privacy:
  // sequential boolean/numeric filters must use the same Excel-side value
  // semantics as the single-filter path, and the workbook rows must never be
  // uploaded to /clean_data just to combine two filters.
  Future<Map<String, dynamic>> _runLocalFilterSteps(
    List<Map<String, dynamic>> steps,
    String requestedSheetName,
  ) async {
    try {
      // Fast generic Excel path: keep workbook data inside Office.js and do
      // the complete AND-filter in one Excel.run. This is entity-agnostic —
      // Pizza Hut, Domino's, McDonald's, KFC, or any other value follows the
      // exact same execution path. Uploaded files still use the Dart fallback.
      if (kIsWeb && dataSourceMode != DataSourceMode.uploadedFile) {
        final fastResult = await executeLocalFilterQuery(
          json.encode({
            "sourceSheet": useActiveSelection ? null : selectedSourceSheet,
            "useActiveSelection": useActiveSelection,
            "steps": steps,
            "requestedSheetName": requestedSheetName,
          }),
        );
        if (fastResult["success"] == true) {
          return fastResult;
        }
        // Do not silently lose compatibility if the Office.js fast path is
        // unavailable in an older host; fall through to the existing local
        // executor, which is still fully generic and private.
      }

      final String? jsonString = await _fetchSourceData();
      if (jsonString == null || jsonString.isEmpty) {
        return {
          "success": false,
          "error": "No data found. Select a range or load a file first.",
        };
      }

      final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
      final List<List<dynamic>> rows = rawRows
          .whereType<List<dynamic>>()
          .where(
            (r) => r.any((c) => c != null && c.toString().trim().isNotEmpty),
          )
          .map((r) => List<dynamic>.from(r))
          .toList();
      if (rows.length < 2) {
        return {
          "success": false,
          "error":
              "Dataset too small — needs at least a header row and one data row.",
        };
      }

      final List<dynamic> headerRow = List<dynamic>.from(rows.first);
      List<List<dynamic>> current = rows.skip(1).toList();
      final List<String> stepLines = [];

      for (int stepIndex = 0; stepIndex < steps.length; stepIndex++) {
        final step = steps[stepIndex];
        final requestedColumn = step["column"]?.toString().trim() ?? "";
        final operator =
            step["operator"]?.toString().trim().toLowerCase() ?? "equals";
        final value = step["value"];

        final int columnIndex = _resolveLocalFilterColumnAgainstRows(
          headerRow,
          current,
          requestedColumn,
          value,
        );
        if (columnIndex < 0) {
          return {
            "success": false,
            "error":
                "Could not resolve filter column '$requestedColumn' for step ${stepIndex + 1}.",
          };
        }

        final int before = current.length;
        current = current.where((row) {
          final cell = columnIndex < row.length ? row[columnIndex] : null;
          return _evaluateLocalFilterValue(
            cell,
            operator,
            value,
            step["value2"],
          );
        }).toList();
        final int removed = before - current.length;
        final String resolvedHeader =
            headerRow[columnIndex]?.toString() ?? requestedColumn;
        stepLines.add(
          "  • Kept rows where $resolvedHeader $operator ${value ?? ''} (removed $removed rows).",
        );

        // A zero-row result is a valid query outcome, but it is NOT a valid
        // output dataset. Never create/switch to an empty result sheet. This
        // also prevents a failed compound filter from becoming the active
        // worksheet and breaking the next query.
        if (current.isEmpty) {
          return {
            "success": false,
            "error":
                "No matching data was found for the requested criteria in the current worksheet.\n\n(no rows returned)",
          };
        }
      }

      final String requested = requestedSheetName.trim().isNotEmpty
          ? requestedSheetName.trim()
          : "Filtered_Result";
      final String targetSheetName = _sanitizeSheetName(
        "${requested}_${DateTime.now().millisecondsSinceEpoch % 100000}",
      );

      final writeResult = await writeQueryResultToSheet(
        json.encode({
          "targetSheetName": targetSheetName,
          "columns": headerRow,
          "rows": current.map((row) {
            final m = <String, dynamic>{};
            for (int i = 0; i < headerRow.length; i++) {
              final key = headerRow[i]?.toString() ?? "Column_${i + 1}";
              m[key] = i < row.length ? row[i] : null;
            }
            return m;
          }).toList(),
        }),
      );

      if (writeResult["success"] != true) {
        return {
          "success": false,
          "error":
              "Filtered locally but failed to write sheet: ${writeResult['error'] ?? 'unknown error'}",
        };
      }

      final stepSummary =
          "Ran ${steps.length} step(s) locally in order and wrote the result to '$targetSheetName' "
          "(${current.length} rows):\n${stepLines.join('\n')}";
      return {
        "success": true,
        "sheetName": targetSheetName,
        "rowCount": current.length,
        "stepSummary": stepSummary,
      };
    } catch (e) {
      return {"success": false, "error": e.toString()};
    }
  }

  int _resolveLocalFilterColumn(
    List<dynamic> headers,
    String requested, [
    dynamic valueHint,
  ]) {
    if (requested.trim().isEmpty || headers.isEmpty) return -1;

    String normalize(dynamic value) => value
        .toString()
        .toLowerCase()
        // Apostrophes are insignificant for entity/header matching.
        // Handles Domino's, Domino’s and Dominos consistently.
        .replaceAll(RegExp(r"['`´‘’‛]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');

    final wanted = normalize(requested);
    if (wanted.isEmpty) return -1;

    final names = <String>[];
    for (final header in headers) {
      names.add(normalize(header));
    }

    // 1. Exact header is always authoritative.
    for (int i = 0; i < names.length; i++) {
      if (names[i] == wanted) return i;
    }

    // 2. Deterministic domain priorities.  Do NOT reject `rating` merely
    // because a workbook also contains `Rating color` / `Rating text`.
    // Prefer the actual metric column (`Aggregate rating` / `Rating`).
    int firstMatching(
      List<RegExp> patterns, {
      List<String> preferred = const [],
    }) {
      for (final pref in preferred) {
        final idx = names.indexOf(normalize(pref));
        if (idx >= 0) return idx;
      }
      for (final pattern in patterns) {
        final matches = <int>[];
        for (int i = 0; i < headers.length; i++) {
          if (pattern.hasMatch(headers[i]?.toString() ?? '')) matches.add(i);
        }
        if (matches.length == 1) return matches.first;
        if (matches.isNotEmpty && matches.length > 1) {
          // Prefer the shortest/most specific metric-style header instead of
          // failing simply because descriptive columns contain the same word.
          matches.sort((a, b) {
            final an = names[a];
            final bn = names[b];
            int score(String n) {
              if (n == 'aggregate rating') return 100;
              if (n == 'rating') return 95;
              if (n == 'rating score') return 90;
              if (n == 'average rating') return 88;
              if (n.contains('rating') &&
                  !n.contains('color') &&
                  !n.contains('text'))
                return 80;
              return 10;
            }

            return score(bn).compareTo(score(an));
          });
          return matches.first;
        }
      }
      return -1;
    }

    if (wanted == 'rating' ||
        wanted == 'ratings' ||
        wanted == 'aggregate rating' ||
        wanted == 'review rating') {
      final idx = firstMatching(
        [
          RegExp(r'aggregate\s*rating', caseSensitive: false),
          RegExp(r'^(?:average\s+)?rating(?:\s+score)?$', caseSensitive: false),
          RegExp(r'\brating\b', caseSensitive: false),
        ],
        preferred: const [
          'Aggregate rating',
          'Rating',
          'Average rating',
          'Rating score',
        ],
      );
      if (idx >= 0) return idx;
    }

    if (wanted == 'delivery' ||
        wanted == 'online delivery' ||
        wanted == 'has online delivery' ||
        wanted == 'delivery capability') {
      final idx = firstMatching(
        [
          RegExp(r'has\s+online\s+delivery', caseSensitive: false),
          RegExp(r'online\s+delivery', caseSensitive: false),
          RegExp(r'\bdelivery\b', caseSensitive: false),
        ],
        preferred: const ['Has Online delivery', 'Online delivery', 'Delivery'],
      );
      if (idx >= 0) return idx;
    }

    if (wanted == 'table booking' ||
        wanted == 'online table booking' ||
        wanted == 'has table booking' ||
        wanted == 'booking' ||
        wanted == 'table booking capability') {
      final idx = firstMatching(
        [
          RegExp(r'has\s+table\s+booking', caseSensitive: false),
          RegExp(r'online\s+table\s+booking', caseSensitive: false),
          RegExp(r'table\s*booking|booking', caseSensitive: false),
        ],
        preferred: const [
          'Has Table booking',
          'Online table booking',
          'Table booking',
        ],
      );
      if (idx >= 0) return idx;
    }

    if (wanted == 'city' ||
        wanted == 'location' ||
        wanted == 'geographic area' ||
        wanted == 'locality' ||
        wanted == 'area' ||
        wanted == 'neighborhood' ||
        wanted == 'neighbourhood') {
      final preferredGeo = <String>[
        'City',
        'city',
        'Location',
        'location',
        'Locality',
        'locality',
        'Area',
        'area',
        'Geographic area',
        'geographic area',
        'Neighborhood',
        'neighborhood',
        'Neighbourhood',
        'neighbourhood',
      ];
      for (final pref in preferredGeo) {
        final idx = names.indexOf(normalize(pref));
        if (idx >= 0) return idx;
      }

      final geoPatterns = [
        RegExp(r'\bcity\b', caseSensitive: false),
        RegExp(r'location|locality|neighbou?rhood', caseSensitive: false),
        RegExp(r'\barea\b', caseSensitive: false),
      ];
      final candidates = <int>[];
      for (int i = 0; i < headers.length; i++) {
        if (geoPatterns.any((p) => p.hasMatch(headers[i]?.toString() ?? '')))
          candidates.add(i);
      }
      if (candidates.length == 1) return candidates.first;
    }

    // 3. Compact exact match.
    final compactWanted = wanted.replaceAll(' ', '');
    final compactMatches = <int>[];
    for (int i = 0; i < headers.length; i++) {
      if (names[i].replaceAll(' ', '') == compactWanted) compactMatches.add(i);
    }
    if (compactMatches.length == 1) return compactMatches.first;

    // 4. Conservative token overlap.  Never fall back to an arbitrary first
    // column; only accept a unique best candidate.
    final tokens = wanted.split(' ').where((t) => t.length >= 2).toSet();
    if (tokens.isNotEmpty) {
      final scored = <Map<String, dynamic>>[];
      for (int i = 0; i < names.length; i++) {
        final headerTokens = names[i]
            .split(' ')
            .where((t) => t.length >= 2)
            .toSet();
        int score = 0;
        for (final token in tokens) {
          if (headerTokens.contains(token)) score += 2;
        }
        if (names[i].contains(wanted) || wanted.contains(names[i])) score += 1;
        if (score > 0) scored.add({'index': i, 'score': score});
      }
      scored.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));
      if (scored.length == 1 ||
          (scored.isNotEmpty && scored[0]['score'] > scored[1]['score'])) {
        return scored.first['index'] as int;
      }
    }

    return -1;
  }

  int _resolveLocalFilterColumnAgainstRows(
    List<dynamic> headers,
    List<List<dynamic>> rows,
    String requested,
    dynamic valueHint,
  ) {
    final base = _resolveLocalFilterColumn(headers, requested, valueHint);
    final wanted = requested
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
    final isGeo = const {
      'city',
      'location',
      'geographic area',
      'locality',
      'area',
      'neighborhood',
      'neighbourhood',
    }.contains(wanted);
    if (!isGeo || valueHint == null || rows.isEmpty) return base;

    String norm(dynamic v) => v
        .toString()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final target = norm(valueHint);
    if (target.isEmpty) return base;

    final candidateIndexes = <int>[];
    for (int i = 0; i < headers.length; i++) {
      final h = norm(headers[i]);
      if (RegExp(
        r'\bcity\b|location|locality|neighbou?rhood|\barea\b',
        caseSensitive: false,
      ).hasMatch(h)) {
        candidateIndexes.add(i);
      }
    }
    if (candidateIndexes.isEmpty) return base;

    int bestIndex = base;
    int bestScore = 0;
    bool tie = false;
    for (final idx in candidateIndexes) {
      int score = 0;
      for (final row in rows) {
        if (idx >= row.length) continue;
        final cell = norm(row[idx]);
        if (cell.isEmpty) continue;
        if (cell == target) {
          score += 4;
        } else if (cell.contains(target) || target.contains(cell)) {
          score += 2;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        bestIndex = idx;
        tie = false;
      } else if (score > 0 && score == bestScore) {
        tie = true;
      }
    }
    return bestScore > 0 && !tie ? bestIndex : base;
  }

  bool _evaluateLocalFilterValue(
    dynamic cell,
    String operator,
    dynamic rawValue,
    dynamic rawValue2,
  ) {
    final String cellText = cell?.toString().trim().toLowerCase() ?? '';
    final String targetText = rawValue?.toString().trim().toLowerCase() ?? '';
    String entityNormalize(String value) => value
        .replaceAll(RegExp(r"['`´‘’‛]"), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    final bool blank = cell == null || cellText.isEmpty;
    final bool targetBlank = rawValue == null || targetText.isEmpty;

    if (operator == 'is_null' || operator == 'is_empty') return blank;
    if (operator == 'is_not_null' || operator == 'is_not_empty') return !blank;
    if (operator == 'equals' && targetBlank) return blank;
    if (operator == 'not_equals' && targetBlank) return !blank;
    if (blank) return false;

    // Natural-language geographic filters such as `in Kolkata` should match
    // common Excel representations like `Kolkata`, `Kolkata, West Bengal`,
    // or `Kolkata - India`, while remaining case/punctuation insensitive.
    if (operator == 'equals' && rawValue is String && targetText.isNotEmpty) {
      final normalizedCell = cellText
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      final normalizedTarget = targetText
          .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
          .trim();
      if (normalizedCell == normalizedTarget ||
          normalizedCell.startsWith('$normalizedTarget ') ||
          normalizedCell.endsWith(' $normalizedTarget')) {
        return true;
      }
    }

    bool? asBool(dynamic v) {
      if (v is bool) return v;
      final s = v?.toString().trim().toLowerCase() ?? '';
      if (s.isEmpty) return null;
      // Real-world spreadsheet capability columns commonly use all of these
      // representations. Treat them semantically instead of requiring the
      // cell to literally contain TRUE/FALSE.
      if ({
        'yes',
        'y',
        'true',
        '1',
        'available',
        'enabled',
        'active',
        'provided',
        'supported',
        'present',
        'on',
        'delivery available',
        'table booking available',
        'online delivery available',
      }.contains(s))
        return true;
      if ({
        'no',
        'n',
        'false',
        '0',
        'unavailable',
        'disabled',
        'inactive',
        'not available',
        'not provided',
        'not supported',
        'absent',
        'off',
        'none',
        'null',
        'nan',
        'delivery unavailable',
        'table booking unavailable',
        'online delivery unavailable',
      }.contains(s))
        return false;
      return null;
    }

    double? asNum(dynamic v) {
      if (v is num) return v.toDouble();
      var s = v?.toString().trim() ?? '';
      if (s.isEmpty) return null;
      // Excel/CSV rating cells are often exported as strings such as
      // `4.1/5`, `4.1 out of 5`, `Rated 4.1`, or `4,1`. Extract the first
      // meaningful numeric value so numeric comparisons work consistently.
      s = s.replaceAll(RegExp(r'\bout\s+of\b', caseSensitive: false), '/');
      s = s.replaceAll(RegExp(r'[₹$€£\s]'), '');
      if (s.contains(',') && !s.contains('.'))
        s = s.replaceAll(',', '.');
      else
        s = s.replaceAll(',', '');
      final direct = double.tryParse(s);
      if (direct != null) return direct;
      final match = RegExp(r'-?\d+(?:[.]\d+)?').firstMatch(s);
      if (match == null) return null;
      return double.tryParse(match.group(0)!);
    }

    final aBool = asBool(cell);
    final bBool = asBool(rawValue);
    if ((operator == 'equals' || operator == 'not_equals') &&
        aBool != null &&
        bBool != null) {
      return operator == 'equals' ? aBool == bBool : aBool != bBool;
    }

    final aNum = asNum(cell);
    final bNum = asNum(rawValue);
    switch (operator) {
      case 'equals':
        if (aNum != null && bNum != null) return aNum == bNum;
        return cellText == targetText;
      case 'not_equals':
        if (aNum != null && bNum != null) return aNum != bNum;
        return cellText != targetText;
      case 'contains':
        // Natural-language entity filters are intentionally punctuation-insensitive.
        // This prevents branded names containing apostrophes from behaving
        // differently from otherwise identical entity names.
        final normalizedCell = entityNormalize(cellText);
        final normalizedTarget = entityNormalize(targetText);
        return normalizedCell.contains(normalizedTarget);
      case 'greater_than':
        return aNum != null && bNum != null && aNum > bNum;
      case 'less_than':
        return aNum != null && bNum != null && aNum < bNum;
      case 'greater_than_equal':
        return aNum != null && bNum != null && aNum >= bNum;
      case 'less_than_equal':
        return aNum != null && bNum != null && aNum <= bNum;
      case 'between':
        final b2 = asNum(rawValue2);
        return aNum != null &&
            bNum != null &&
            b2 != null &&
            aNum >= bNum &&
            aNum <= b2;
      default:
        return false;
    }
  }

  // Shared by _executeAgenticMultiStep and _executeAgenticFillMissing: sends
  // the CURRENT sheet's data + an ordered list of data_cleaner.py run_steps()
  // op dicts to the existing /clean_data route, then writes the ONE final
  // result to a single new sheet. No intermediate sheet is created per step,
  // and no separate "report" sheet is created — only the one result sheet.
  static const String _cleanDataUrl =
      "https://data-analysis-oajs.onrender.com/clean_data";

  Future<Map<String, dynamic>> _runCleaningSteps(
    List<Map<String, dynamic>> steps,
    String requestedSheetName,
  ) async {
    try {
      if (secureLocalOnly) {
        return {
          "success": false,
          "error": "Remote cleaning is disabled in secure local mode.",
        };
      }
      final String? jsonString = await _fetchSourceData();
      if (jsonString == null || jsonString.isEmpty) {
        return {
          "success": false,
          "error": "No data found. Select a range or load a file first.",
        };
      }
      final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
      if (rawRows.isEmpty || rawRows.first is! List) {
        return {
          "success": false,
          "error":
              "Unrecognised data shape — expected a 2D array from Excel or file.",
        };
      }
      final List<List<dynamic>> rows = rawRows
          .whereType<List<dynamic>>()
          .where(
            (r) => r.any((c) => c != null && c.toString().trim().isNotEmpty),
          )
          .toList();
      if (rows.length < 2) {
        return {
          "success": false,
          "error":
              "Dataset too small — needs at least a header row and one data row.",
        };
      }
      final String csvData = rows
          .map((row) => row.map(escapeCsvValue).join(','))
          .join('\n');

      // A single new sheet name, generated ONCE up front — every step runs
      // against the same in-memory dataframe server-side and only the FINAL
      // result is written here, so only one sheet is ever created for this
      // whole request, however many steps it contains.
      final String targetSheetName = _sanitizeSheetName(
        "${requestedSheetName}_${DateTime.now().millisecondsSinceEpoch % 100000}",
      );

      final request = http.MultipartRequest('POST', Uri.parse(_cleanDataUrl));
       await attachFirebaseAuth(request, resourceId: activeSheetName);
      request.fields['config'] = json.encode({
        "steps": steps,
        "output_sheet_name": targetSheetName,
      });
      request.files.add(
        http.MultipartFile.fromString(
          'file',
          csvData,
          filename: 'data_source.csv',
        ),
      );

      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 60),
      );
      final body = await streamedResponse.stream.bytesToString();
      final Map<String, dynamic> decoded = decodeBackendResponse(
        body,
        statusCode: streamedResponse.statusCode,
      );

      if (decoded["success"] != true) {
        return {
          "success": false,
          "error":
              decoded["error"]?.toString() ??
              decoded["message"]?.toString() ??
              "Cleaning failed.",
        };
      }

      final Map<String, dynamic> export = decoded["export"] is Map
          ? Map<String, dynamic>.from(decoded["export"])
          : {};
      final List<dynamic> columns = export["columns"] is List
          ? export["columns"]
          : [];
      final List<dynamic> resultRows = export["rows"] is List
          ? export["rows"]
          : [];
      if (columns.isEmpty) {
        return {
          "success": false,
          "error": "Cleaning ran but returned no data to write.",
        };
      }

      final writeResult = await writeQueryResultToSheet(
        json.encode({
          "targetSheetName": targetSheetName,
          "columns": columns,
          "rows": resultRows,
        }),
      );
      if (writeResult["success"] != true) {
        return {
          "success": false,
          "error":
              "Cleaned but failed to write sheet: ${writeResult['error'] ?? 'unknown error'}",
        };
      }

      // Build a step-by-step summary straight from the backend's own
      // cleaning_report so the chat message reflects what actually ran, in
      // the order it actually ran, rather than re-describing the request.
      final Map<String, dynamic> cleaningReport =
          decoded["cleaning_report"] is Map
          ? Map<String, dynamic>.from(decoded["cleaning_report"])
          : {};
      final List<dynamic> operations = cleaningReport["operations"] is List
          ? cleaningReport["operations"]
          : [];
      final stepLines = <String>[];
      for (final op in operations.whereType<Map>()) {
        stepLines.add(
          "  • ${_describeCleaningOperation(Map<String, dynamic>.from(op))}",
        );
      }
      final int rowCount = export["row_count"] is int
          ? export["row_count"] as int
          : resultRows.length;
      final stepSummary =
          "Ran ${steps.length} step(s) in order and wrote the result to '$targetSheetName' "
          "($rowCount rows):\n${stepLines.join('\n')}";

      return {
        "success": true,
        "sheetName": targetSheetName,
        "rowCount": rowCount,
        "stepSummary": stepSummary,
      };
    } catch (e) {
      return {"success": false, "error": e.toString()};
    }
  }

  // Turns one data_cleaner.py DataCleaningReport "operations" entry into a
  // short human-readable line for the multi_step chat summary.
  String _describeCleaningOperation(Map<String, dynamic> op) {
    final String type = (op["type"] ?? "step").toString();
    switch (type) {
      case "standardize_columns":
        return "Standardized column names (lowercase, spaces → _) — ${op['columns_changed'] ?? 0} changed.";
      case "filter_rows":
        return "Kept rows where ${op['column']} ${op['operator']} ${op['value']} "
            "(removed ${op['rows_removed'] ?? 0} rows).";
      case "handle_missing_values":
        return "Filled ${op['cells_filled'] ?? 0} missing value(s) using strategy '${op['strategy'] ?? 'smart'}'.";
      case "remove_duplicates":
        return "Removed ${op['rows_removed'] ?? 0} duplicate row(s)"
            "${op['subset'] != null && op['subset'] != 'all_columns' ? ' on ${op['subset']}' : ''}.";
      case "normalize_text":
        return "Normalized text in ${op['columns_normalized'] ?? 0} column(s).";
      case "handle_outliers":
        return "Handled outliers in ${op['columns_affected'] ?? 0} column(s) using '${op['method'] ?? 'cap'}'.";
      case "infer_types":
        return "Inferred and converted column data types.";
      case "remove_all_null_rows":
        return "Removed ${op['rows_removed'] ?? 0} fully-empty row(s).";
      case "unknown_step":
        return "⚠️ Skipped unrecognized step '${op['op']}'.";
      default:
        if (op.containsKey("error"))
          return "⚠️ Step '$type' failed: ${op['error']}.";
        return "Ran step '$type'.";
    }
  }

  // Shared by BOTH manual pivot creation (runTransformationPipeline) and
  // AI-generated pivots (_executeAgenticPivot) — there is exactly one
  // placement workflow/dialog in this app; nothing below is duplicated per
  // entry point. Vertical stacking (20-row gap, see PIVOT_GAP_ROWS in
  // web/excel_helper.js) replaced the old side-by-side layout, so this
  // dialog's copy describes that behavior for both callers.
  //
  // [alwaysAsk] false (manual default): only prompts when [proposedSheetName]
  // already exists as a worksheet — if the user typed a brand-new name,
  // there's nothing to collide with, so skip straight to NEW_SHEET.
  // [alwaysAsk] true (AI default): normally would always prompt, but now
  // checks whether ANY existing pivot sheet exists first. If none do,
  // automatically returns NEW_SHEET without prompting (first pivot is
  // automatically created). Only shows the dialog when appending to an
  // existing pivot sheet is actually possible.
  Future<String?> _promptPivotPlacement(
    String proposedSheetName, {
    bool alwaysAsk = false,
  }) async {
    await refreshWorksheetNames();

    // If not always-asking, follow the old "only prompt on collision" logic
    if (!alwaysAsk && !availableSheets.contains(proposedSheetName)) {
      return "NEW_SHEET";
    }

    // For AI (alwaysAsk=true), check if any existing Pivot sheet exists.
    // Detect pivot sheets by name pattern: typically "Pivot Analysis",
    // "Pivot_Workspace", or user-custom names that explicitly contain
    // "Pivot". Also detect by scanning for ANY sheet that has a
    // PivotTable on it (expensive, so skip for now — rely on naming).
    final existingPivotSheets = availableSheets
        .where((name) => name.toLowerCase().contains('pivot'))
        .toList();

    // If this is the first pivot (no existing pivot sheet), automatically
    // create a new sheet without asking the user.
    if (alwaysAsk && existingPivotSheets.isEmpty) {
      return "NEW_SHEET";
    }

    // Only show the dialog if there's actually an existing pivot sheet
    // to append to, OR if it's a manual pivot with a collision.
    if (!alwaysAsk || existingPivotSheets.isNotEmpty) {
      return await GlassDialog.show<String>(
        context: context,
        barrierDismissible: false,
        title: 'Pivot Table Placement',
        message: 'Where would you like to place the new Pivot Table?',
        actions: [
          GlassDialogAction(
            label: 'Append below existing Pivot Tables',
            onPressed: () => Navigator.pop(context, 'APPEND_EXISTING'),
          ),
          GlassDialogAction(
            label: 'Create New Worksheet',
            isPrimary: true,
            onPressed: () => Navigator.pop(context, 'NEW_SHEET'),
          ),
        ],
      );
    }

    return "NEW_SHEET";
  }

  String? _validateLookupConfig() {
    if (lookupSourceColumn == null)
      return "Pick the key column (lookup_value) from your sheet.";
    if (lookupTargetSheet == null)
      return "Pick a reference sheet to use as table_array.";
    if (lookupRefMatchColumn == null)
      return "Pick the match column inside the reference sheet.";
    if (lookupUseStaticSearch &&
        (lookupSelectedSourceValue == null ||
            lookupSelectedSourceValue!.trim().isEmpty)) {
      return "Pick the value to search for from the dropdown, or turn off the static search switch.";
    }
    if (!lookupShowAllColumns) {
      if (selectedLookupType == "hlookup") {
        if (resolvedLookupRowIndexNum == null || resolvedLookupRowIndexNum! < 1)
          return "Enter a valid row_index_num.";
      } else {
        if (resolvedLookupColIndexNum == null)
          return "Pick a return column so col_index_num can be calculated.";
      }
    }
    return null;
  }

Future<Map<String, dynamic>> _executeManualPivotFromBuilder() async {
    final requestedSheet = pivotSheetNameController.text.trim().isNotEmpty
        ? _sanitizeSheetName(pivotSheetNameController.text.trim())
        : "Pivot_Workspace";

    final rowFields = pivotRowFields
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
    final columnFields = pivotColumnFields
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
    final filterFields = pivotFilterFields
        .map((field) => field.trim())
        .where((field) => field.isNotEmpty)
        .toList();
    final valueFields = pivotValueFields
        .map((entry) => <String, String>{
              "field": (entry["field"] ?? "").trim(),
              "op": (entry["op"] ?? "sum").trim().toLowerCase(),
            })
        .where((entry) => entry["field"]!.isNotEmpty)
        .toList();

    if (rowFields.isEmpty) {
      return {"success": false, "error": "Pick at least one PivotTable row field."};
    }
    if (valueFields.isEmpty) {
      return {"success": false, "error": "Pick at least one PivotTable value field."};
    }

    const supportedPivotOps = {
      "sum",
      "average",
      "count",
      "counta",
      "max",
      "min",
      "product",
      "stdev",
    };
    final unsupported = valueFields
        .map((entry) => entry["op"]!)
        .firstWhere(
          (op) => !supportedPivotOps.contains(op),
          orElse: () => "",
        );
    if (unsupported.isNotEmpty) {
      return {
        "success": false,
        "error": "Unsupported PivotTable aggregation: " + unsupported,
      };
    }

    // Manual Builder deliberately delegates to the exact same native executor
    // used by AI/query PivotTable requests. This keeps source resolution,
    // placement, native hierarchy assignment, verification, and cleanup in
    // one implementation instead of maintaining two divergent contracts.
    final result = await _executeAgenticPivot(
      {
        "sheetName": requestedSheet,
        "tableName":
            "Pivot_" + (DateTime.now().millisecondsSinceEpoch % 10000).toString(),
        "rowFields": rowFields,
        "columnFields": columnFields,
        "valueFields": valueFields,
        "filterFields": filterFields,
        "reuseExisting": false,
      },
      placementOverride: null,
    );

    if (result["success"] == true) {
      String actualPivotSheet = requestedSheet;
      final placementRaw = result["pivotPlacement"];
      if (placementRaw is Map && placementRaw["sheet"] is String) {
        actualPivotSheet = placementRaw["sheet"].toString();
      } else if (placementRaw is String && placementRaw.trim().isNotEmpty) {
        try {
          final placement = json.decode(placementRaw);
          if (placement is Map && placement["sheet"] is String) {
            actualPivotSheet = placement["sheet"].toString();
          }
        } catch (_) {}
      }
      result["manualPivotSheet"] = actualPivotSheet;
    }
    return result;
  }

  Future<void> runTransformationPipeline() async {
    final permission = generatePivotTable ? "pivot.create" : "worksheet.modify";
    final authorized = await authorizeExcelOperation(
      backendBaseUrl: _backendBaseUrl,
      action: permission,
      resourceId: activeSheetName,
    );
    if (!authorized) {
      showNotification(
        "You are not authorized to perform this Excel operation in the current workspace.",
        TechColors.statusOrange,
      );
      return;
    }
    if (secureLocalOnly &&
        dataSourceMode == DataSourceMode.uploadedFile &&
        uploadedFile == null) {
      showNotification(
        'Choose a local dataset first.',
        TechColors.statusOrange,
      );
      return;
    }
    if (generateLookup) {
      final lookupError = _validateLookupConfig();
      if (lookupError != null) {
        showError(lookupError);
        return;
      }
    }
    if (generatePivotTable) {
      setState(() => pipelineProcessing = true);
      final result = await _executeManualPivotFromBuilder();
      if (!mounted) return;
      setState(() => pipelineProcessing = false);

      if (result["success"] == true) {
        final actualPivotSheet =
            result["manualPivotSheet"]?.toString().trim().isNotEmpty == true
                ? result["manualPivotSheet"].toString()
                : pivotSheetNameController.text.trim();

        setState(() {
          activePivotSheetName = actualPivotSheet;
          pivotEditorRowFields = List<String>.from(pivotRowFields);
          pivotEditorColumnFields = List<String>.from(pivotColumnFields);
          pivotEditorValueFields =
              List<Map<String, String>>.from(pivotValueFields);
          pivotEditorFilterFields = List<String>.from(pivotFilterFields);
          pivotSourceHeaders = List<String>.from(detectedHeaders);
        });
        showNotification("✅ Native PivotTable created.", TechColors.statusGreen);
      } else {
        showNotification(
          "PIVOT ERROR: " + (result["error"] ?? "Unknown error").toString(),
          TechColors.statusRed,
        );
      }
      return;
    }
    String desiredPivotSheet = pivotSheetNameController.text.trim().isNotEmpty
        ? pivotSheetNameController.text.trim()
        : "Pivot_Workspace";
    bool appendMode = false;
    if (generatePivotTable) {
      // The manual builder owns its requested destination. Do not replace it
      // with an agentic sheet-name suggestion.
      desiredPivotSheet = _sanitizeSheetName(desiredPivotSheet);
      if (desiredPivotSheet.isEmpty) {
        desiredPivotSheet = "Pivot_Workspace";
      }
    }
    if (generatePivotTable && kIsWeb) {
      final choice = await _promptPivotPlacement(desiredPivotSheet);
      if (choice == null) return;
      if (choice == "APPEND_EXISTING") {
        appendMode = true;
      } else if (availableSheets.contains(desiredPivotSheet)) {
        desiredPivotSheet =
            "${desiredPivotSheet}_${DateTime.now().millisecondsSinceEpoch % 10000}";
      }
    }
    setState(() => pipelineProcessing = true);
    String? autoTargetName;
    if (!useCustomTargetName || targetSheetNameController.text.trim().isEmpty) {
      if (deduplicate && enableFilter) {
        final dedupTag = deduplicateColumns.isNotEmpty
            ? deduplicateColumns.take(2).map(sheetSafe).join('_')
            : 'AllCols';
        final filterTag = sheetSafe(selectedFilterColumn ?? 'Col');
        autoTargetName = 'Dedup_${dedupTag}__Filter_$filterTag';
      } else if (deduplicate) {
        autoTargetName = deduplicateColumns.isNotEmpty
            ? 'Dedup_${deduplicateColumns.take(3).map(sheetSafe).join('_')}'
            : 'Dedup_AllCols';
      } else if (enableFilter && selectedFilterColumn != null) {
        autoTargetName =
            'Filter_${sheetSafe(selectedFilterColumn!)}_${filterTypeShortLabel(selectedFilterType)}';
      }
    }
    String? agentPipelineSheetName;
    if (createNewSheet) {
      final pipelineParts = <String>[
        if (deduplicate) "deduplicate ${deduplicateColumns.join(', ')}",
        if (enableFilter && selectedFilterColumn != null)
          "filter ${selectedFilterColumn} ${filterTypeShortLabel(selectedFilterType)} ${valController1.text}",
        if (generateLookup) "lookup ${lookupSourceColumn ?? ''}",
        if (generatePivotTable)
          "create pivot ${pivotRowFields.join(', ')} ${pivotValueFields.map((e) => e['field']).join(', ')}",
      ];
      final pipelineQuery =
          'Manual pipeline: ${pipelineParts.where((s) => s.trim().isNotEmpty).join('; ')}';
      agentPipelineSheetName = await suggestAgenticSheetName(
        query: pipelineQuery,
        operation: "manual_pipeline",
        context: {
          "deduplicate": deduplicate,
          "filter": enableFilter
              ? {
                  "column": selectedFilterColumn,
                  "type": selectedFilterType,
                  "value": valController1.text,
                }
              : null,
          "lookup": generateLookup
              ? {
                  "column": lookupSourceColumn,
                  "reference_sheet": lookupTargetSheet,
                }
              : null,
          "pivot": generatePivotTable
              ? {"rows": pivotRowFields, "values": pivotValueFields}
              : null,
        },
      );
    }
    final String? pivotSource = generatePivotTable
        ? await _ensureAnalyticalSourceSheet()
        : ((!useActiveSelection && selectedSourceSheet != null)
            ? selectedSourceSheet
            : null);
    if (generatePivotTable) {
      // Manual PivotBuilder and AI pivot queries use the same native Office.js
      // pivotConfig contract. Normalize the Flutter state before dispatch.
      pivotRowFields = pivotRowFields
          .map((field) => field.trim())
          .where((field) => field.isNotEmpty)
          .toList();
      pivotColumnFields = pivotColumnFields
          .map((field) => field.trim())
          .where((field) => field.isNotEmpty)
          .toList();
      pivotFilterFields = pivotFilterFields
          .map((field) => field.trim())
          .where((field) => field.isNotEmpty)
          .toList();
      pivotValueFields = pivotValueFields
          .map((entry) => <String, String>{
                "field": (entry["field"] ?? "").trim(),
                "op": (entry["op"] ?? "sum").trim().toLowerCase(),
              })
          .where((entry) => entry["field"]!.isNotEmpty)
          .toList();

      if (pivotRowFields.isEmpty) {
        setState(() => pipelineProcessing = false);
        showError("Pick at least one PivotTable row field.");
        return;
      }
      if (pivotValueFields.isEmpty) {
        setState(() => pipelineProcessing = false);
        showError("Pick at least one PivotTable value field.");
        return;
      }

      const supportedPivotOps = {
        "sum",
        "average",
        "count",
        "counta",
        "max",
        "min",
        "product",
        "stdev",
      };
      final unsupported = pivotValueFields
          .map((entry) => entry["op"]!)
          .firstWhere(
            (op) => !supportedPivotOps.contains(op),
            orElse: () => "",
          );
      if (unsupported.isNotEmpty) {
        setState(() => pipelineProcessing = false);
        showError("Unsupported PivotTable aggregation: " + unsupported);
        return;
      }
    }

    final Map<String, dynamic> options = {
      "sourceSheetName": pivotSource,
      // Native PivotTables write directly to pivotConfig.sheetName.
      // Never create a parallel copied-data result sheet for the Pivot path.
      "targetSheetName": generatePivotTable
          ? null
          : ((useCustomTargetName &&
                  targetSheetNameController.text.trim().isNotEmpty)
              ? targetSheetNameController.text.trim()
              : (agentPipelineSheetName ?? autoTargetName)),
      "createNewSheet": true,
      "freezeHeaderRow": freezeHeaderRow,
      "enableAutoFilter": enableAutoFilter,
      "generateSummarySheet": false,
      "removeDuplicates": deduplicate,
      "deduplicateColumns": deduplicate && deduplicateColumns.isNotEmpty
          ? deduplicateColumns.toList()
          : null,
      "filter": (enableFilter && selectedFilterColumn != null)
          ? {
              "columnName": selectedFilterColumn,
              "type": selectedFilterType,
              "value": valController1.text,
              "value2": valController2.text,
            }
          : null,
      "lookupConfig": generateLookup
          ? {
              "type": selectedLookupType,
              "lookupColumn": lookupSourceColumn,
              "referenceSheetName": lookupTargetSheet,
              "tableHasHeaders": lookupTableHasHeaders,
              "refMatchColumn": lookupRefMatchColumn ?? lookupSourceColumn,
              "colIndexNum": selectedLookupType == "hlookup"
                  ? null
                  : resolvedLookupColIndexNum,
              "rowIndexNum": selectedLookupType == "hlookup"
                  ? resolvedLookupRowIndexNum
                  : null,
              "returnColumnHeader": lookupReturnColumnHeader,
              "rangeLookup": !lookupExactMatch,
              "searchItemValue": lookupUseStaticSearch
                  ? lookupSelectedSourceValue
                  : null,
              "showAllColumns": lookupShowAllColumns,
              "returnColumns": lookupSelectedReturnColumns,
            }
          : null,
      "metricsConfig": null,
      "pivotConfig": generatePivotTable
          ? {
              "sheetName": desiredPivotSheet,
              "tableName":
                  "Pivot_${DateTime.now().millisecondsSinceEpoch % 10000}",
              "rowFields": pivotRowFields,
              "columnFields": pivotColumnFields,
              "valueFields": pivotValueFields,
              "filterFields": pivotFilterFields,
              "appendMode": appendMode,
            }
          : null,
    };
    // Uploaded files in secure-local mode have no Excel workbook behind them,
    // so Office.js cannot execute the pipeline. Run the same core filter /
    // dedup operations entirely in Dart instead of silently failing.
    if (secureLocalOnly && dataSourceMode == DataSourceMode.uploadedFile) {
      if (generateLookup || generatePivotTable) {
        setState(() => pipelineProcessing = false);
        showNotification(
          'This uploaded-file pipeline supports filter/deduplicate locally. Lookup and Pivot require an Excel workbook.',
          TechColors.statusOrange,
        );
        return;
      }
      final localResult = executeLocalPipeline(
        sourceRows: uploadedFile!.rows,
        options: options,
      );
      setState(() => pipelineProcessing = false);
      if (localResult.success) {
        final originalName = uploadedFile!.fileName.replaceFirst(
          RegExp(r'\.[^.]+$'),
          '',
        );
        uploadedFile = FileUploadResult(
          rows: localResult.rows,
          fileName: '${localResult.targetName}_from_$originalName.csv',
          formatLabel: 'LOCAL RESULT',
        );
        dataSourceMode = DataSourceMode.uploadedFile;
        analysisData = null;
        aiReport = null;
        reportText = null;
        reportError = null;
        _applyHeadersFromRows(localResult.rows);
        showNotification(
          'LOCAL PIPELINE COMPLETE: ${localResult.processedRows} rows · ${localResult.targetName}',
          TechColors.statusGreen,
        );
        await analyzeData();
      } else {
        showNotification(
          'PIPELINE ERROR: ${localResult.error ?? 'Execution failed'}',
          TechColors.statusRed,
        );
      }
      return;
    }

    final result = await executePipeline(json.encode(options));
    setState(() => pipelineProcessing = false);
    if (result["success"] == true) {
      await refreshWorksheetNames();
      if (generatePivotTable) {
        String actualPivotSheet = desiredPivotSheet;
        final placementRaw = result["pivotPlacement"];
        if (placementRaw is String && placementRaw.trim().isNotEmpty) {
          try {
            final placement = json.decode(placementRaw);
            if (placement is Map && placement["sheet"] is String) {
              actualPivotSheet = placement["sheet"].toString();
            }
          } catch (_) {
            // Native creation already succeeded; retain the requested name
            // only as a UI fallback if placement metadata cannot be decoded.
          }
        }
        setState(() {
          activePivotSheetName = actualPivotSheet;
          pivotSourceSheetName = pivotSource;
          pivotEditorRowFields = List<String>.from(pivotRowFields);
          pivotEditorColumnFields = List<String>.from(pivotColumnFields);
          pivotEditorValueFields = List<Map<String, String>>.from(
            pivotValueFields,
          );
          pivotEditorFilterFields = List<String>.from(pivotFilterFields);
          pivotSourceHeaders = List<String>.from(detectedHeaders);
        });
        showNotification("✅ Pivot synchronized.", TechColors.statusGreen);
        return;
      }
      showNotification(
        "EXEC COMPLETE: ${result['processedRows']} rows written",
        TechColors.statusGreen,
      );
    } else {
      showNotification(
        "PIPELINE ERROR: ${result['error'] ?? 'Execution Failed'}",
        TechColors.statusRed,
      );
    }
  }

  Future<Map<String, dynamic>> _executeAgenticPivot(
    Map<String, dynamic> config, {
    String? placementOverride,
  }) async {
    final String sheetName =
        (config["sheetName"]?.toString().trim().isNotEmpty ?? false)
            ? config["sheetName"].toString().trim()
            : "Pivot Analysis";

    final List<String> rowFields = config["rowFields"] is List
        ? List<String>.from((config["rowFields"] as List).map((e) => (e ?? "").toString()).where((s) => s.isNotEmpty))
        : <String>[];
    final List<String> columnFields = config["columnFields"] is List
        ? List<String>.from((config["columnFields"] as List).map((e) => (e ?? "").toString()).where((s) => s.isNotEmpty))
        : <String>[];
    final List<String> filterFields = config["filterFields"] is List
        ? List<String>.from((config["filterFields"] as List).map((e) => (e ?? "").toString()).where((s) => s.isNotEmpty))
        : <String>[];
    final List<Map<String, String>> valueFields = config["valueFields"] is List
        ? (config["valueFields"] as List).map<Map<String, String>>((v) {
            final m = v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
            return {"field": (m["field"] ?? "").toString(), "op": (m["op"] ?? "sum").toString()};
          }).toList()
        : <Map<String, String>>[];

    if (rowFields.isEmpty || valueFields.isEmpty || valueFields.any((v) => v["field"]!.isEmpty)) {
      return {"success": false, "error": "Could not determine pivot row/value fields from that request."};
    }

    final bool reuseExisting = config["reuseExisting"] == true;
    final String? choice = reuseExisting
        ? "REUSE_EXISTING"
        : (placementOverride ?? await _promptPivotPlacement(sheetName, alwaysAsk: true));
    if (choice == null) return {"success": false, "error": "Pivot placement not confirmed.", "cancelled": true};

    final bool appendMode = choice == "APPEND_EXISTING";
    String targetSheetName = sheetName;
    await refreshWorksheetNames();
    if (!appendMode && !reuseExisting && availableSheets.contains(targetSheetName)) {
      targetSheetName = targetSheetName + "_" + (DateTime.now().millisecondsSinceEpoch % 10000).toString();
    }

    final String? source = await _ensureAnalyticalSourceSheet();
    final options = {
      "sourceSheetName": source,
      "targetSheetName": null,
      "createNewSheet": false,
      "freezeHeaderRow": false,
      "enableAutoFilter": false,
      "generateSummarySheet": false,
      "removeDuplicates": false,
      "filter": null,
      "pivotConfig": {
        "sheetName": targetSheetName,
        "tableName": (config["tableName"]?.toString().trim().isNotEmpty ?? false)
            ? config["tableName"].toString().trim()
            : "Pivot_" + (DateTime.now().millisecondsSinceEpoch % 10000).toString(),
        "rowFields": rowFields,
        "columnFields": columnFields,
        "valueFields": valueFields,
        "filterFields": filterFields,
        "appendMode": appendMode,
        "reuseExisting": reuseExisting,
        if (config["sortByValue"] != null) "sortByValue": config["sortByValue"],
        if (config["limit"] != null) "limit": config["limit"],
        if (config["hideGrandTotals"] != null) "hideGrandTotals": config["hideGrandTotals"],
      },
    };

    if (secureLocalOnly && dataSourceMode == DataSourceMode.uploadedFile) {
      return {"success": false, "error": "Pivot creation requires an Excel workbook in secure-local mode."};
    }
    final result = await executePipeline(json.encode(options));
    await refreshWorksheetNames();
    if (result["success"] == true) {
      setState(() {
        activePivotSheetName = targetSheetName;
        pivotSourceSheetName = source;
        pivotEditorRowFields = List<String>.from(rowFields);
        pivotEditorColumnFields = List<String>.from(columnFields);
        pivotEditorValueFields = List<Map<String, String>>.from(valueFields);
        pivotEditorFilterFields = List<String>.from(filterFields);
        pivotSourceHeaders = List<String>.from(detectedHeaders);
      });
    }
    return result;
  }
  Future<void> rerunPivot() async {
    if (activePivotSheetName == null) return;
    final String? source =
        pivotSourceSheetName ??
        (availableSheets.isNotEmpty ? availableSheets.first : null);
    if (source == null) return;
    setState(() => pivotEditorRefreshing = true);
    final options = {
      "sourceSheetName": source,
      "targetSheetName": null,
      "createNewSheet": true,
      "freezeHeaderRow": false,
      "enableAutoFilter": false,
      "generateSummarySheet": false,
      "removeDuplicates": false,
      "filter": null,
      "pivotConfig": {
        "sheetName": activePivotSheetName,
        "tableName": "Pivot_Manual_Refactor",
        "rowFields": pivotEditorRowFields,
        "columnFields": pivotEditorColumnFields,
        "valueFields": pivotEditorValueFields,
        "filterFields": pivotEditorFilterFields,
        "appendMode": false,
      },
    };
    final result = await executePipeline(json.encode(options));
    setState(() => pivotEditorRefreshing = false);
    if (result["success"] == true) {
      String actualPivotSheet = activePivotSheetName!;
      final placementRaw = result["pivotPlacement"];
      if (placementRaw is String && placementRaw.trim().isNotEmpty) {
        try {
          final placement = json.decode(placementRaw);
          if (placement is Map && placement["sheet"] is String) {
            actualPivotSheet = placement["sheet"].toString();
          }
        } catch (_) {}
      }
      setState(() => activePivotSheetName = actualPivotSheet);
      showNotification("✅ Pivot updated.", TechColors.statusGreen);
    } else {
      showNotification(
        "PIVOT ERROR: " + (result["error"] ?? "Unknown error").toString(),
        TechColors.statusRed,
      );
    }
  }

  // Same blank/invisible-character detection as escapeCsvValue, but without
  // CSV quoting — used purely for computing quality stats, not for building
  // the CSV payload.
  String _cleanCellForStats(dynamic value) {
    if (value == null) return "";
    if (value is bool) return value ? "TRUE" : "FALSE";
    if (value is num) return value.toString();
    String str = value.toString();
    str = str.replaceAll(_invisibleCharsRe, '');
    return str.trim();
  }

  // Computes missing_values and unique_values directly from the rows already
  // in memory — the SAME rows used to build the CSV sent to /analyze — so
  // the Quality tab is guaranteed correct regardless of whether the backend
  // is running the latest deploy. This removes the backend as a possible
  // source of truth mismatch entirely for these two stats.
  Map<String, dynamic> _computeClientSideQualityStats(
    List<List<dynamic>> rows,
    List<String> headers,
  ) {
    final Map<String, int> missing = {for (final h in headers) h: 0};
    final Map<String, Set<String>> uniqueSets = {
      for (final h in headers) h: <String>{},
    };
    final Map<String, int> duplicateValues = {for (final h in headers) h: 0};
    for (int r = 1; r < rows.length; r++) {
      // row 0 is the header row
      final row = rows[r];
      for (int c = 0; c < headers.length; c++) {
        final String cleaned = _cleanCellForStats(
          c < row.length ? row[c] : null,
        );
        final h = headers[c];
        if (cleaned.isEmpty) {
          missing[h] = missing[h]! + 1;
        } else {
          // A duplicate value is a repeated occurrence after the first one.
          // Example: [A, A, A, B] => 2 duplicates. Missing values are
          // excluded because they already have their own Missing count.
          if (uniqueSets[h]!.contains(cleaned)) {
            duplicateValues[h] = duplicateValues[h]! + 1;
          } else {
            uniqueSets[h]!.add(cleaned);
          }
        }
      }
    }
    return {
      "missing_values": missing,
      "unique_values": {for (final h in headers) h: uniqueSets[h]!.length},
      "duplicate_values": duplicateValues,
    };
  }

  List<Map<String, dynamic>> _rowsToMapRows(
    List<List<dynamic>> rows,
    List<String> headers,
  ) {
    return rows.map((row) {
      final mapped = <String, dynamic>{};
      for (var i = 0; i < headers.length; i++) {
        mapped[headers[i]] = i < row.length ? row[i] : '';
      }
      return mapped;
    }).toList();
  }

  Future<void> analyzeData() async {
    setState(() => isLoading = true);
    try {
      // Active Selection is an explicit source-selection action. Capture the
      // worksheet identity before scanning can create/activate any generated
      // report sheet. Once captured, all analytical queries use this persisted
      // source context rather than Excel's presentation-active worksheet.
      if (kIsWeb &&
          dataSourceMode == DataSourceMode.excel &&
          useActiveSelection) {
        final established =
            await establishInsightFlowSourceFromActiveWorksheet();
        if (established == null || established.isEmpty) {
          throw "Select an original dataset worksheet before scanning.";
        }
        if (mounted) {
          setState(() {
            useActiveSelection = false;
            selectedSourceSheet = established;
            activeSheetName = established;
          });
        }
        await refreshWorksheetNames();
      }

      final String? jsonString = await _fetchSourceData();
      if (jsonString == null || jsonString.isEmpty)
        throw "No data found. Select a range or load a file first.";
      final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
      if (rawRows.isEmpty || rawRows.first is! List)
        throw "Unrecognised data shape — expected a 2D array from Excel or file.";
      final List<List<dynamic>> rows = rawRows
          .whereType<List<dynamic>>()
          .where(
            (r) => r.any((c) => c != null && c.toString().trim().isNotEmpty),
          )
          .toList();
      if (rows.length < 2)
        throw "Dataset too small — needs at least a header row and one data row.";
      final cleanHeaders = rows.first
          .map((e) => (e ?? '').toString().trim())
          .toList();
      setState(() {
        detectedHeaders = cleanHeaders;
        selectedFilterColumn ??= detectedHeaders.first;
        pivotRowFields = [detectedHeaders.first];
        pivotValueFields = [
          {"field": detectedHeaders.last, "op": "sum"},
        ];
        lookupSourceColumn = detectedHeaders.first;
        colorCodeColumn = detectedHeaders.first;
      });
      if (secureLocalOnly) {
        final clientStats = _computeClientSideQualityStats(rows, cleanHeaders);
        final previewRows = _rowsToMapRows(
          rows.skip(1).take(5).toList(),
          cleanHeaders,
        );
        final sampleSource = rows.length > 6
            ? rows.skip(((rows.length - 1) / 2).floor()).take(5).toList()
            : rows.skip(1).take(5).toList();
        final sampleRows = _rowsToMapRows(sampleSource, cleanHeaders);
        final duplicateCount = (clientStats['duplicate_values'] as Map).values
            .fold<int>(
              0,
              (sum, value) =>
                  sum +
                  (value is int ? value : int.tryParse(value.toString()) ?? 0),
            );
        setState(() {
          analysisData = {
            "summary": {
              "rows": rows.length - 1,
              "columns": cleanHeaders.length,
              "column_names": cleanHeaders,
              "dtypes": {for (final h in cleanHeaders) h: "unknown"},
            },
            "missing_values": clientStats['missing_values'],
            "unique_values": clientStats['unique_values'],
            "duplicate_values": clientStats['duplicate_values'],
            "distribution": {
              "unique_values": clientStats['unique_values'],
              "duplicate_values": clientStats['duplicate_values'],
            },
            "preview": previewRows,
            "sample": sampleRows,
            "describe": <Map<String, dynamic>>[],
            "info":
                "Local secure scan completed without sending row values or column names to a remote API.",
            "duplicates": {"count": duplicateCount},
          };
          aiReport = null;
          reportText = null;
          reportError = "Remote analysis is disabled in secure local mode.";
          _pendingReportCleanedData = null;
          chatFilteredHeaders = cleanHeaders;
        });
        if (kIsWeb && dataSourceMode != DataSourceMode.uploadedFile) {
          await _syncQualityReport(analysisData!);
        }
        return;
      }
      final String csvData = rows
          .map((row) => row.map(escapeCsvValue).join(','))
          .join('\n');
      final request = http.MultipartRequest('POST', Uri.parse(apiUrl));
      await attachFirebaseAuth(request, resourceId: activeSheetName);
      request.files.add(
        http.MultipartFile.fromString(
          'file',
          csvData,
          filename: 'data_source.csv',
        ),
      );
      final streamedResponse = await request.send();
      final body = await streamedResponse.stream.bytesToString();
      final Map<String, dynamic> decoded = decodeBackendResponse(
        body,
        statusCode: streamedResponse.statusCode,
      );
      if (decoded.containsKey('error'))
        throw "Analysis engine error: ${decoded['error']}";
      // Override the backend's missing_values/unique_values with stats
      // computed directly from these exact rows — see
      // _computeClientSideQualityStats for why. Everything else in
      // `decoded` (preview, describe, duplicates, etc.) still comes from
      // the backend as before.
      final clientStats = _computeClientSideQualityStats(rows, cleanHeaders);
      decoded['missing_values'] = clientStats['missing_values'];
      decoded['unique_values'] = clientStats['unique_values'];
      decoded['duplicate_values'] = clientStats['duplicate_values'];
      setState(() {
        analysisData = decoded;
        // A new dataset scan invalidates any previous AI Report results.
        aiReport = null;
        reportText = null;
        reportError = null;
        _pendingReportCleanedData = null;
        // 'column_names' now lives under the nested 'summary' object in the
        // backend response (see main.py's analyze_dataframe) rather than at
        // the top level.
        chatFilteredHeaders = List<String>.from(
          decoded['summary']?['column_names'] ?? [],
        );
      });
      // Automatically create/update the Quality_Report worksheet immediately
      // after every successful scan. This is awaited so the report cannot be
      // silently skipped when the Office/Excel bridge is still busy.
      await _syncQualityReport(decoded);
    } catch (e) {
      showError(e.toString());
    } finally {
      if (mounted) setState(() => isLoading = false);
    }
  }

  // Keeps the single "Quality_Report" worksheet's overview numbers
  // (rows/missing/duplicates) current after every scan, via the SAME
  // writeQualityReportWorksheet() implementation the explicit export button
  // uses (see _buildQualityReportPayload() / exportQualityReportToExcel()
  // above) — there is no separate rollup writer anymore. Runs silently
  // (activate:false, no banner state touched) so a routine scan never
  // interrupts the user or yanks their view onto the report sheet.
  //
  // Note: analyzeData() nulls out `aiReport` on every fresh scan (a new scan
  // invalidates whatever AI report was showing before), so at the moment
  // this fires there is normally no AiReport yet — the sheet gets rewritten
  // with just the overview section until "Generate Report" is run and/or
  // the export button is pressed, at which point the full sections appear.
  Future<void> _syncQualityReport(Map<String, dynamic> decoded) async {
    try {
      final payloadMap = await _buildQualityReportPayload(
        rawDecoded: decoded,
        report: aiReport,
        // Automatic report generation should actually create and show the
        // Quality_Report worksheet. Previously this was false and failures
        // were swallowed, making the feature appear to do nothing.
        activate: true,
      );
      final result = await writeQualityReportWorksheet(json.encode(payloadMap));
      if (result['success'] != true) {
        throw result['error'] ?? 'Quality_Report could not be created.';
      }
      if (mounted) {
        setState(() {
          qualityReportSheetName =
              result['sheet']?.toString() ?? 'Quality_Report';
          qualityReportExportError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => qualityReportExportError = e.toString());
        showError('Quality report could not be generated: ${e.toString()}');
      }
    }
  }

  Future<void> generateReport() async {
    setState(() {
      isGeneratingReport = true;
      reportError = null;
    });
    try {
      if (secureLocalOnly) {
        if (analysisData == null) throw "Scan the dataset first.";
        final summary = (analysisData!['summary'] as Map?) ?? const {};
        final missing = (analysisData!['missing_values'] as Map?) ?? const {};
        final unique = (analysisData!['unique_values'] as Map?) ?? const {};
        final duplicates = (analysisData!['duplicates'] as Map?) ?? const {};
        final rowCount = (summary['rows'] as num?)?.toInt() ?? 0;
        final colCount = (summary['columns'] as num?)?.toInt() ?? 0;
        final totalMissing = missing.values.fold<int>(
          0,
          (a, v) =>
              a + (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0),
        );
        final localText =
            'Local secure report: $rowCount rows across $colCount columns. Total missing values: $totalMissing. Duplicate rows: ${duplicates['count'] ?? 0}. All dataset processing remained on this device.';
        setState(() {
          reportText = localText;
          aiReport = AiReport(
            report: localText,
            dataQuality: {
              'rows': rowCount,
              'columns': colCount,
              'missing_values': totalMissing,
              'missing_values_by_column': missing,
              'unique_values_by_column': unique,
              'duplicate_rows': duplicates['count'] ?? 0,
            },
            statistics: {'rows': rowCount, 'columns': colCount},
            executiveSummary: {'summary': localText},
          );
          reportError = null;
          _pendingReportCleanedData = null;
        });
        if (kIsWeb && dataSourceMode != DataSourceMode.uploadedFile) {
          await _syncQualityReport(analysisData!);
        }
        return;
      }
      final String? jsonString = await _fetchSourceData();
      if (jsonString == null || jsonString.isEmpty) {
        throw "No data found. Select a range or load a file first.";
      }
      final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
      if (rawRows.isEmpty || rawRows.first is! List) {
        throw "Unrecognised data shape — expected a 2D array from Excel or file.";
      }
      final List<List<dynamic>> rows = rawRows
          .whereType<List<dynamic>>()
          .where(
            (r) => r.any((c) => c != null && c.toString().trim().isNotEmpty),
          )
          .toList();
      if (rows.length < 2) {
        throw "Dataset too small — needs at least a header row and one data row.";
      }
      final String csvData = rows
          .map((row) => row.map(escapeCsvValue).join(','))
          .join('\n');
      final request = http.MultipartRequest(
        'POST',
        Uri.parse("https://data-analysis-oajs.onrender.com/analyze-report"),
      );
      await attachFirebaseAuth(request, resourceId: activeSheetName);
      request.files.add(
        http.MultipartFile.fromString(
          'file',
          csvData,
          filename: 'data_source.csv',
        ),
      );
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 90),
      );
      final body = await streamedResponse.stream.bytesToString();
      final Map<String, dynamic> decoded = decodeBackendResponse(
        body,
        statusCode: streamedResponse.statusCode,
      );
      if (decoded.containsKey('error'))
        throw "Report engine error: ${decoded['error']}";
      // NOTE: this used to call _writeCleanedDataIfPresent(decoded) here,
      // which silently created a brand-new "AI_Cleaned_..." sheet every
      // time a report was generated, even though the user never asked for
      // one. Report generation should only produce the report text — it
      // must NOT create a sheet on its own. The cleaned data (if the report
      // engine's own cleaning step modified anything) is kept around so the
      // user can write it to a sheet explicitly via writeReportCleanedData()
      // if they actually want it.
      setState(() {
        reportText = decoded['report'] as String?;
        aiReport = AiReport.fromJson(decoded);
        _pendingReportCleanedData = decoded;
        reportCleanedSheetName = null;
        reportCleanedSheetError = null;
        qualityReportSheetName = null;
        qualityReportExportError = null;
      });
      // Refresh the same automatic Quality_Report sheet with the AI report
      // sections as soon as report generation finishes.
      if (analysisData != null) {
        await _syncQualityReport(analysisData!);
      }
    } catch (e) {
      setState(() => reportError = e.toString());
    } finally {
      if (mounted) setState(() => isGeneratingReport = false);
    }
  }

  // Builds the same CSV payload used by generateReport()/analyzeData(), so
  // the three report-tab endpoints (/suggest_analysis_types,
  // /analysis_business_context via profile, /analyze-report-focused) all
  // see identical data without duplicating the fetch/validate logic.
  Future<String> _buildCurrentCsvPayload() async {
    final String? jsonString = await _fetchSourceData();
    if (jsonString == null || jsonString.isEmpty) {
      throw "No data found. Select a range or load a file first.";
    }
    final List<dynamic> rawRows = decodeSourceMatrix(jsonString);
    if (rawRows.isEmpty || rawRows.first is! List) {
      throw "Unrecognised data shape — expected a 2D array from Excel or file.";
    }
    final List<List<dynamic>> rows = rawRows
        .whereType<List<dynamic>>()
        .where((r) => r.any((c) => c != null && c.toString().trim().isNotEmpty))
        .toList();
    if (rows.length < 2) {
      throw "Dataset too small — needs at least a header row and one data row.";
    }
    return rows.map((row) => row.map(escapeCsvValue).join(',')).join('\n');
  }

  // Step 1: ask the backend which analysis types this dataset actually
  // supports (Pricing Analysis, Revenue Analysis, Market Behaviour, etc. —
  // whichever ones genuinely fit the real columns present), so the user can
  // manually pick before any report is generated.
  Future<void> suggestAnalysisTypes() async {
    // The post-scan selector is deterministic. These are the concrete report
    // capabilities the backend can return, so no extra LLM suggestion call is
    // needed just to populate the checkboxes.
    setState(() {
      isSuggestingAnalysisTypes = false;
      analysisSuggestError = null;
      suggestedAnalysisTypes = reportAnalysisOptions
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      selectedAnalysisIds = reportAnalysisOptions.map((e) => e['id']!).toSet();
      businessProblemResults = [];
      businessContextError = null;
    });
  }

  // Step 2: given the user's manual selection from suggestAnalysisTypes(),
  // fetch concrete business problems each selected analysis type would
  // address for this specific dataset.
  Future<void> fetchBusinessContext() async {
    if (selectedAnalysisIds.isEmpty || analysisProfile == null) return;
    setState(() {
      isLoadingBusinessContext = true;
      businessContextError = null;
      businessProblemResults = [];
    });
    try {
      if (secureLocalOnly) {
        setState(
          () => businessContextError =
              "Remote business-context analysis is disabled in secure local mode.",
        );
        return;
      }
      final Map<String, String> titleLookup = {
        for (final t in suggestedAnalysisTypes)
          (t['id'] ?? '').toString(): (t['title'] ?? t['id'] ?? '').toString(),
      };
      final response = await http
          .post(
            Uri.parse(
              "https://data-analysis-oajs.onrender.com/analysis_business_context",
            ),
            headers: {"Content-Type": "application/json"},
            body: json.encode({
              "profile": analysisProfile,
              "selected_ids": selectedAnalysisIds.toList(),
              "analysis_titles": titleLookup,
            }),
          )
          .timeout(const Duration(seconds: 45));
      final Map<String, dynamic> decoded = decodeBackendResponse(
        response.body,
        statusCode: response.statusCode,
      );
      if (decoded.containsKey('error') && decoded['error'] != null) {
        throw decoded['error'].toString();
      }
      final List<dynamic> results = decoded['results'] is List
          ? decoded['results']
          : [];
      setState(() {
        businessProblemResults = results
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
      });
    } catch (e) {
      setState(() => businessContextError = e.toString());
    } finally {
      if (mounted) setState(() => isLoadingBusinessContext = false);
    }
  }

  // Step 3: generate the actual report, weighted toward whichever analysis
  // type(s) the user selected — same shape as generateReport() above, just
  // posting to /analyze-report-focused with the selection attached.
  Future<void> generateFocusedReport() async {
    if (selectedAnalysisIds.isEmpty) {
      setState(() => reportError = 'Select at least one analysis type.');
      return;
    }
    setState(() {
      isGeneratingReport = true;
      reportError = null;
      reportCleanedSheetName = null;
      reportCleanedSheetError = null;
      qualityReportSheetName = null;
      qualityReportExportError = null;
    });
    try {
      if (secureLocalOnly) {
        if (analysisData == null) throw "Scan the dataset first.";
        final summary = (analysisData!['summary'] as Map?) ?? const {};
        final missing = (analysisData!['missing_values'] as Map?) ?? const {};
        final unique = (analysisData!['unique_values'] as Map?) ?? const {};
        final duplicates = (analysisData!['duplicates'] as Map?) ?? const {};
        final rowCount = (summary['rows'] as num?)?.toInt() ?? 0;
        final colCount = (summary['columns'] as num?)?.toInt() ?? 0;
        final totalMissing = missing.values.fold<int>(
          0,
          (a, v) =>
              a + (v is num ? v.toInt() : int.tryParse(v.toString()) ?? 0),
        );
        final localText =
            'Local secure report: $rowCount rows, $colCount columns, $totalMissing missing values, and ${duplicates['count'] ?? 0} duplicate rows.';
        setState(() {
          reportText = localText;
          aiReport = AiReport(
            report: localText,
            dataQuality: {
              'rows': rowCount,
              'columns': colCount,
              'missing_values': totalMissing,
              'missing_values_by_column': missing,
              'unique_values_by_column': unique,
              'duplicate_rows': duplicates['count'] ?? 0,
            },
            statistics: {'rows': rowCount, 'columns': colCount},
          );
          reportError = null;
        });
        if (kIsWeb && dataSourceMode != DataSourceMode.uploadedFile) {
          await _syncQualityReport(analysisData!);
        }
        return;
      }
      final csvData = await _buildCurrentCsvPayload();
      final selectedTypes = reportAnalysisOptions
          .where((t) => selectedAnalysisIds.contains(t['id']))
          .map((t) => {'id': t['id'], 'title': t['title']})
          .toList();

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
          "https://data-analysis-oajs.onrender.com/analyze-report-focused",
        ),
      );
      await attachFirebaseAuth(request, resourceId: activeSheetName);
      request.fields['focus_analysis_types'] = json.encode(selectedTypes);
      request.files.add(
        http.MultipartFile.fromString(
          'file',
          csvData,
          filename: 'data_source.csv',
        ),
      );
      final streamedResponse = await request.send().timeout(
        const Duration(seconds: 90),
      );
      final body = await streamedResponse.stream.bytesToString();
      final Map<String, dynamic> decoded = decodeBackendResponse(
        body,
        statusCode: streamedResponse.statusCode,
      );
      if (decoded.containsKey('error') && decoded['error'] != null) {
        throw "Report engine error: ${decoded['error']}";
      }
      setState(() {
        reportText = decoded['report'] as String?;
        aiReport = AiReport.fromJson(decoded);
        _pendingReportCleanedData = decoded;
      });
    } catch (e) {
      setState(() => reportError = e.toString());
    } finally {
      if (mounted) setState(() => isGeneratingReport = false);
    }
  }

  // Resets just the analysis-type selection + guidance flow (not the
  // auto-generated report itself) — used by the "refresh suggestions"
  // control in the analysis-type section.
  void resetAnalysisSelection() {
    setState(() {
      suggestedAnalysisTypes = reportAnalysisOptions
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      analysisProfile = null;
      selectedAnalysisIds = reportAnalysisOptions.map((e) => e['id']!).toSet();
      businessProblemResults = [];
      analysisSuggestError = null;
      businessContextError = null;
    });
    suggestAnalysisTypes();
  }

  // =========================================================================
  // Build — full liquid glass screen (same pattern as password manager)
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      SecureExcelLocalService.registerDialogContext(() => context);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      body: LiquidGlassScope(
        child: Stack(
          children: [
            // ── Animated cyberpunk background — captured for glass refraction
            Positioned.fill(
              child: GlassBackgroundSource(
                child: const TechAnimatedBackground(),
              ),
            ),

            // ── Full-screen content column
            Positioned.fill(
              child: SafeArea(
                child: Column(
                  children: [
                    // ── Glass app bar ──────────────────────────────────────
                    _buildGlassAppBar(),

                    // ── Navigation tabs (only when data is loaded) ─────────
                    if (analysisData != null) NavigationTabs(state: this),

                    // ── Body ──────────────────────────────────────────────
                    Expanded(child: _buildBody()),
                  ],
                ),
              ),
            ),

            // ── Fixed bottom action dock ────────────────────────────────
            // Wide "electric" pill (Run Pipeline) + small circular Analyse
            // button side by side. `Scaffold.floatingActionButton` only
            // anchors to a corner and can't do a full-width bar, so this is
            // a plain Positioned row instead — same fixed-at-bottom result,
            // just not routed through the FAB slot.
            if (selectedView != 'NEURAL_CHAT')
              Positioned(
                left: 20,
                right: 20,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Expanded(child: ElectricTaskButton(state: this)),
                        const SizedBox(width: 12),
                        ScanButton(state: this),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Glass app bar — replaces AppBar, sits inside the LiquidGlassScope ────
  //
  // The EXCEL / UPLOAD FILE toggle (previously `DataSourceToggle`) has been
  // removed entirely — [SourceRouter] inside the Pipelines tab is now the
  // one place source selection happens, and `_buildEmptyState()` below
  // already shows an uploaded-file badge, so this panel is just the title.
  Widget _buildGlassAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: Row(
          children: [
            const Icon(Icons.terminal, color: TechColors.borderActive, size: 18),
            const SizedBox(width: 10),
            const Text(
              'InsightFlow',
              style: TextStyle(
                color: TechColors.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Access management',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AuthorizationManagementScreen(),
                ),
              ),
              icon: const Icon(
                Icons.admin_panel_settings_outlined,
                size: 18,
                color: TechColors.textPrimary,
              ),
            ),
            IconButton(
              tooltip: 'Account',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const AccountManagementScreen(),
                ),
              ),
              icon: const Icon(
                Icons.account_circle_outlined,
                size: 18,
                color: TechColors.textPrimary,
              ),
            ),
            IconButton(
              tooltip: 'Sign out',
              onPressed: () => InsightFlowAuthService.signOut(),
              icon: const Icon(
                Icons.logout,
                size: 18,
                color: TechColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: TechColors.borderActive),
      );
    }
    if (analysisData == null || analysisData!.containsKey('error')) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 150),
        child: Column(
          children: [
            _buildEmptyState(),
            const SizedBox(height: 12),
            PipelineScreen(state: this),
          ],
        ),
      );
    }
    if (selectedView == "PIPELINES") {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 150),
        child: PipelineScreen(state: this),
      );
    }
    if (selectedView == "PIVOT_EDITOR") return PivotEditor(state: this);
    return AnalysisScreen(state: this);
  }

  Widget _buildEmptyState() {
    if (dataSourceMode == DataSourceMode.uploadedFile && uploadedFile != null) {
      return GlassContainer(
        useOwnLayer: true,
        // See the officeHost check in main.dart — GlassQuality.standard
        // still depends on a fragment shader, which is what forces this
        // down to .minimal specifically inside the Excel Add-in WebView.
        quality: isRunningInsideOffice
            ? GlassQuality.minimal
            : GlassQuality.standard,
        settings: TechColors.sectionGlass,
        shape: const LiquidRoundedSuperellipse(borderRadius: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(
              Icons.insert_drive_file_outlined,
              size: 14,
              color: TechColors.statusBlue,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    uploadedFile!.fileName,
                    style: const TextStyle(
                      color: TechColors.statusBlue,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(
                    '${uploadedFile!.formatLabel}  ·  ${uploadedFile!.dataRowCount} rows  ·  ${uploadedFile!.headers.length} columns',
                    style: const TextStyle(
                      color: TechColors.textMuted,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: clearUploadedFile,
              child: const Icon(
                Icons.close,
                size: 14,
                color: TechColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }
    return const Text(
      'SYSTEM STATUS: UNBUFFERED',
      style: TextStyle(
        color: TechColors.textMuted,
        fontSize: 11,
        fontFamily: 'monospace',
      ),
    );
  }
}
