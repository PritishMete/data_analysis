import 'dart:convert';

class AiReport {
  final String? report;
  final Map<String, dynamic> statistics;
  final Map<String, dynamic> trendInsight;
  final List<dynamic> outliers;
  // `outliers` alone can't distinguish "the backend ran outlier detection
  // and found none" (an explicit empty list) from "outlier detection never
  // ran" (the key was absent/null) — both collapse to the same `const []`
  // once parsed. This flag preserves that distinction from the raw JSON so
  // the Excel export (and any future UI) can show the right message instead
  // of guessing. It does not change what `outliers` itself contains.
  final bool outliersAnalysisPresent;
  final List<dynamic> detectedKpis;
  final List<dynamic> recommendations;
  final Map<String, dynamic> chartRecommendation;
  final Map<String, dynamic> dataQuality;
  final Map<String, dynamic> executiveSummary;

  const AiReport({
    this.report,
    this.statistics = const {},
    this.trendInsight = const {},
    this.outliers = const [],
    this.outliersAnalysisPresent = false,
    this.detectedKpis = const [],
    this.recommendations = const [],
    this.chartRecommendation = const {},
    this.dataQuality = const {},
    this.executiveSummary = const {},
  });

  factory AiReport.fromJson(Map<String, dynamic> json) {
    return AiReport(
      report: json['report']?.toString(),
      statistics: _map(json['statistics']),
      trendInsight: _map(json['trend_insight'] ?? json['trend']),
      outliers: _list(json['outliers']),
      outliersAnalysisPresent: json.containsKey('outliers') && json['outliers'] != null,
      detectedKpis: _list(json['detected_kpis'] ?? json['kpis']),
      recommendations: _list(json['recommendations']),
      chartRecommendation: _map(json['chart_recommendation']),
      dataQuality: _map(json['data_quality']),
      executiveSummary: _map(json['executive_summary']),
    );
  }

  static Map<String, dynamic> _map(dynamic value) {
    if (value is Map) return Map<String, dynamic>.from(value);
    return {};
  }

  static List<dynamic> _list(dynamic value) {
    return value is List ? List<dynamic>.from(value) : const [];
  }

  bool get hasAnyStructuredResult =>
      statistics.isNotEmpty ||
      trendInsight.isNotEmpty ||
      outliers.isNotEmpty ||
      detectedKpis.isNotEmpty ||
      recommendations.isNotEmpty ||
      chartRecommendation.isNotEmpty ||
      dataQuality.isNotEmpty ||
      executiveSummary.isNotEmpty;

  String toJsonString() => jsonEncode({
        'report': report,
        'statistics': statistics,
        'trend_insight': trendInsight,
        'outliers': outliers,
        'detected_kpis': detectedKpis,
        'recommendations': recommendations,
        'chart_recommendation': chartRecommendation,
        'data_quality': dataQuality,
        'executive_summary': executiveSummary,
      });
}
