// lib/core/services/transformation_manager.dart
//
// Single source of truth for Enterprise Transformation Engine results.
//
// Backend Response → TransformationManager → UI
//
// data_screen.dart should never inspect operation.action, operation.data,
// etc. directly — it hands the raw decoded JSON to
// TransformationManager.applyResponse() and then reads the manager's
// current* getters (already updated, already notified) to refresh the UI.
//
// Because dispatch is driven entirely by TransformationResult/
// TransformationOperation parsing rather than a hardcoded action list,
// every current and future transformation the backend adds
// (range_binning, rename_columns, drop_columns, merge_columns,
// split_columns, fill_missing, remove_duplicates, type_conversion,
// date_features, ...) is handled the same way, automatically.

import 'package:flutter/foundation.dart';

import '../../models/transformation_result.dart';
import '../../features/dashboard/ai_report_model.dart';

class TransformationManager extends ChangeNotifier {
  TransformationResult? _lastResult;
  TransformationData? _currentDataset;
  Map<String, dynamic>? _currentSchema;
  Map<String, dynamic>? _currentStatistics;
  Map<String, dynamic>? _currentChartRecommendation;
  AiReport? _currentAiReport;
  TransformationPreview? _lastPreview;
  TransformationMetadata? _lastMetadata;
  String? _lastAction;
  String? _lastMessage;
  String? _lastError;
  bool _isProcessing = false;

  /// The full last-seen backend envelope, in case a caller needs something
  /// this manager doesn't already surface via a dedicated getter.
  TransformationResult? get lastResult => _lastResult;

  /// The active dataset, replaced whenever a transformation returns
  /// `operation.data`. Null until the first transformation with data runs.
  TransformationData? get currentDataset => _currentDataset;

  Map<String, dynamic>? get currentSchema => _currentSchema;
  Map<String, dynamic>? get currentStatistics => _currentStatistics;
  Map<String, dynamic>? get currentChartRecommendation => _currentChartRecommendation;
  AiReport? get currentAiReport => _currentAiReport;
  TransformationPreview? get lastPreview => _lastPreview;
  TransformationMetadata? get lastMetadata => _lastMetadata;

  String? get lastAction => _lastAction;
  String? get lastMessage => _lastMessage;
  String? get lastError => _lastError;
  bool get isProcessing => _isProcessing;

  /// Call right before sending a transformation request so the UI can show
  /// a loading state that's guaranteed to be cleared — every code path in
  /// [applyResponse] and [applyError] clears it.
  void startRequest() {
    _isProcessing = true;
    _lastError = null;
    notifyListeners();
  }

  /// Parses and validates a raw decoded backend response, updates all
  /// relevant state, and notifies listeners. Returns the parsed result so
  /// the caller can still branch on `success`/`operation.action` for
  /// side effects that live outside app state (e.g. writing the new
  /// dataset back into the active Excel sheet).
  TransformationResult applyResponse(Map<String, dynamic> decoded) {
    final result = TransformationResult.fromJson(decoded);
    _lastResult = result;
    _isProcessing = false;
    _lastAction = result.operation.action;
    _lastMessage = result.operation.message;

    if (!result.success) {
      // Never surface a generic "not sure" message for a real backend
      // transformation failure — operation.message is always the specific
      // reason (e.g. "Column not found.").
      _lastError = result.operation.message.isNotEmpty
          ? result.operation.message
          : "Transformation failed.";
      notifyListeners();
      return result;
    }

    _lastError = null;
    final op = result.operation;

    if (op.data != null && !op.data!.isEmpty) {
      _currentDataset = op.data;
    }
    if (op.updatedSchema != null) {
      _currentSchema = op.updatedSchema;
    }
    if (op.statistics != null) {
      _currentStatistics = op.statistics;
    }
    if (op.chartRecommendation != null) {
      _currentChartRecommendation = op.chartRecommendation;
    }
    if (op.aiReport != null) {
      _currentAiReport = AiReport.fromJson(op.aiReport!);
    }
    _lastPreview = op.preview;
    _lastMetadata = op.metadata;

    notifyListeners();
    return result;
  }

  /// For transport-level failures (network error, malformed JSON) that
  /// never made it into a TransformationResult at all.
  void applyError(String message) {
    _isProcessing = false;
    _lastError = message;
    notifyListeners();
  }

  /// Clears everything — call when a brand new dataset is loaded/uploaded
  /// so a stale transformation result doesn't linger.
  void reset() {
    _lastResult = null;
    _currentDataset = null;
    _currentSchema = null;
    _currentStatistics = null;
    _currentChartRecommendation = null;
    _currentAiReport = null;
    _lastPreview = null;
    _lastMetadata = null;
    _lastAction = null;
    _lastMessage = null;
    _lastError = null;
    _isProcessing = false;
    notifyListeners();
  }
}
