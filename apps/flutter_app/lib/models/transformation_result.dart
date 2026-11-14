// lib/models/transformation_result.dart
//
// Typed models for the Enterprise Transformation Engine's response shape.
// The backend returns this same envelope for EVERY transformation
// (range_binning, rename_columns, drop_columns, merge_columns,
// split_columns, fill_missing, remove_duplicates, type_conversion,
// date_features, and any transformation added in the future):
//
// Success:
// {
//   "success": true,
//   "route": "operation",
//   "operation": {
//     "action": "range_binning",
//     "message": "Transformation completed.",
//     "preview": {...},
//     "metadata": {...},
//     "updated_schema": {...},
//     "statistics": {...},
//     "chart_recommendation": {...},
//     "ai_report": {...},
//     "data": { "columns": [...], "rows": [...] }
//   }
// }
//
// Failure:
// {
//   "success": false,
//   "route": "operation",
//   "operation": { "action": "transformation_error", "message": "Column not found." }
// }
//
// Nothing here hardcodes a list of known actions — any `operation.action`
// the backend sends is accepted. Callers dispatch on `.action` as a plain
// string, not against a whitelist, so future transformations work without
// touching this file or its callers.

/// Root response envelope from the Enterprise Transformation Engine.
class TransformationResult {
  final bool success;
  final String route;
  final TransformationOperation operation;

  const TransformationResult({
    required this.success,
    required this.route,
    required this.operation,
  });

  factory TransformationResult.fromJson(Map<String, dynamic> json) {
    return TransformationResult(
      success: json['success'] == true,
      route: (json['route'] ?? 'unknown').toString(),
      operation: TransformationOperation.fromJson(
        json['operation'] is Map
            ? Map<String, dynamic>.from(json['operation'] as Map)
            : const {},
      ),
    );
  }

  /// True when the backend reported an explicit transformation failure
  /// (`success: false`, action `transformation_error` or otherwise).
  bool get isError => !success;

  Map<String, dynamic> toJson() => {
        'success': success,
        'route': route,
        'operation': operation.toJson(),
      };
}

/// The `operation` block — one entry per transformation call. Every field
/// besides `action` and `message` is optional: error responses only ever
/// populate those two, and a given transformation may not populate every
/// optional section (e.g. a rename won't have a chart recommendation).
class TransformationOperation {
  final String action;
  final String message;
  final TransformationPreview? preview;
  final TransformationMetadata? metadata;
  final Map<String, dynamic>? updatedSchema;
  final Map<String, dynamic>? statistics;
  final Map<String, dynamic>? chartRecommendation;
  final Map<String, dynamic>? aiReport;
  final TransformationData? data;

  const TransformationOperation({
    required this.action,
    required this.message,
    this.preview,
    this.metadata,
    this.updatedSchema,
    this.statistics,
    this.chartRecommendation,
    this.aiReport,
    this.data,
  });

  factory TransformationOperation.fromJson(Map<String, dynamic> json) {
    return TransformationOperation(
      action: (json['action'] ?? 'unknown').toString(),
      message: (json['message'] ?? '').toString(),
      preview: json['preview'] is Map
          ? TransformationPreview.fromJson(Map<String, dynamic>.from(json['preview'] as Map))
          : null,
      metadata: json['metadata'] is Map
          ? TransformationMetadata.fromJson(Map<String, dynamic>.from(json['metadata'] as Map))
          : null,
      updatedSchema: json['updated_schema'] is Map ? Map<String, dynamic>.from(json['updated_schema'] as Map) : null,
      statistics: json['statistics'] is Map ? Map<String, dynamic>.from(json['statistics'] as Map) : null,
      chartRecommendation:
          json['chart_recommendation'] is Map ? Map<String, dynamic>.from(json['chart_recommendation'] as Map) : null,
      aiReport: json['ai_report'] is Map ? Map<String, dynamic>.from(json['ai_report'] as Map) : null,
      data: json['data'] is Map ? TransformationData.fromJson(Map<String, dynamic>.from(json['data'] as Map)) : null,
    );
  }

  /// This is the one action name this file ever compares against, and only
  /// to decide how to *display* an error — not to gate which transformations
  /// are accepted. Any other failed action is still a failure via `success`.
  bool get isTransformationError => action == 'transformation_error';

  Map<String, dynamic> toJson() => {
        'action': action,
        'message': message,
        if (preview != null) 'preview': preview!.toJson(),
        if (metadata != null) 'metadata': metadata!.toJson(),
        if (updatedSchema != null) 'updated_schema': updatedSchema,
        if (statistics != null) 'statistics': statistics,
        if (chartRecommendation != null) 'chart_recommendation': chartRecommendation,
        if (aiReport != null) 'ai_report': aiReport,
        if (data != null) 'data': data!.toJson(),
      };
}

/// `operation.preview` — shape varies by transformation, so this keeps the
/// raw map available while lifting out `columns`/`rows` when present (the
/// common case: a small before/after sample table).
class TransformationPreview {
  final List<String> columns;
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> raw;

  const TransformationPreview({
    this.columns = const [],
    this.rows = const [],
    this.raw = const {},
  });

  factory TransformationPreview.fromJson(Map<String, dynamic> json) {
    return TransformationPreview(
      columns: json['columns'] is List
          ? List<dynamic>.from(json['columns'] as List).map((e) => e.toString()).toList()
          : const [],
      rows: _rowsFrom(json['rows']),
      raw: json,
    );
  }

  bool get isEmpty => columns.isEmpty && rows.isEmpty && raw.isEmpty;
  bool get hasTable => columns.isNotEmpty && rows.isNotEmpty;

  Map<String, dynamic> toJson() => raw;
}

/// `operation.metadata` — free-form, transformation-specific details
/// (e.g. rows affected, columns touched, bins created). Kept as a raw map
/// with a couple of convenience getters for the common fields.
class TransformationMetadata {
  final Map<String, dynamic> raw;

  const TransformationMetadata(this.raw);

  factory TransformationMetadata.fromJson(Map<String, dynamic> json) => TransformationMetadata(json);

  int? get rowsAffected => _asInt(raw['rows_affected'] ?? raw['rowsAffected']);
  List<String>? get columnsAffected {
    final v = raw['columns_affected'] ?? raw['columnsAffected'];
    if (v is List) return v.map((e) => e.toString()).toList();
    return null;
  }

  dynamic operator [](String key) => raw[key];

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  Map<String, dynamic> toJson() => raw;
}

/// `operation.data` — the full transformed dataset. This becomes the new
/// active dataset in the UI once a transformation succeeds.
class TransformationData {
  final List<String> columns;
  final List<Map<String, dynamic>> rows;

  const TransformationData({
    this.columns = const [],
    this.rows = const [],
  });

  factory TransformationData.fromJson(Map<String, dynamic> json) {
    final columns = json['columns'] is List
        ? List<dynamic>.from(json['columns'] as List).map((e) => e.toString()).toList()
        : <String>[];
    return TransformationData(
      columns: columns,
      rows: _rowsFrom(json['rows'], columns: columns),
    );
  }

  bool get isEmpty => columns.isEmpty;

  /// Rows as plain 2D values (column order), for writing back to a sheet.
  List<List<dynamic>> asMatrix() => rows.map((r) => columns.map((c) => r[c]).toList()).toList();

  Map<String, dynamic> toJson() => {'columns': columns, 'rows': rows};
}

/// Shared row-list parsing: the backend may send rows as a list of
/// column-keyed records (`[{"col": "val"}, ...]`) or, less commonly, as
/// plain positional lists paired with a sibling `columns` list. Both are
/// normalized to `List<Map<String, dynamic>>`.
List<Map<String, dynamic>> _rowsFrom(dynamic rows, {List<String> columns = const []}) {
  if (rows is! List) return const [];
  return rows.map<Map<String, dynamic>>((r) {
    if (r is Map) return Map<String, dynamic>.from(r);
    if (r is List && columns.isNotEmpty) {
      final map = <String, dynamic>{};
      for (var i = 0; i < columns.length && i < r.length; i++) {
        map[columns[i]] = r[i];
      }
      return map;
    }
    return <String, dynamic>{};
  }).toList();
}
