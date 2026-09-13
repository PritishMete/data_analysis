// lib/features/dashboard/report_tab.dart
//
// AI Report: scan -> choose analysis -> run -> render only selected results.
// Structured analytics are rendered from AiReport; the narrative report is
// kept as a secondary explanation under Executive Summary.

import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import 'data_screen.dart';
import 'ai_report_model.dart';

class ReportTab extends StatefulWidget {
  final DataScreenState state;
  const ReportTab({super.key, required this.state});

  @override
  State<ReportTab> createState() => _ReportTabState();
}

class _ReportTabState extends State<ReportTab> {
  @override
  void initState() {
    super.initState();
    final s = widget.state;

    // Do not generate a report automatically. After the dataset is scanned,
    // the user first chooses the analysis sections they want, then explicitly
    // generates the report for that selection.
    if (!s.isSuggestingAnalysisTypes && s.suggestedAnalysisTypes.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => s.suggestAnalysisTypes());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 150),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeaderBar(s),
          const SizedBox(height: 12),
          _buildAnalysisTypeSection(s),
          const SizedBox(height: 16),
          if (s.isGeneratingReport) _buildLoadingState('Analyzing the selected sections…'),
          if (!s.isGeneratingReport && s.reportError != null) _buildErrorState(s),
          if (!s.isGeneratingReport && s.reportError == null && s.aiReport != null)
            _buildSelectedResults(s),
          if (!s.isGeneratingReport && s.reportCleanedSheetName != null) ...[
            const SizedBox(height: 12),
            _buildCleanedSheetBanner(s.reportCleanedSheetName!),
          ],
          if (!s.isGeneratingReport && s.reportCleanedSheetError != null) ...[
            const SizedBox(height: 12),
            _buildCleanedSheetErrorBanner(s.reportCleanedSheetError!),
          ],
          if (!s.isGeneratingReport && s.reportError == null && s.reportText == null)
            _buildEmptyState(s),

        ],
      ),
    );
  }

  Widget _buildHeaderBar(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.panelGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.description, color: TechColors.borderActive, size: 16),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'AI DATA REPORT',
              style: TextStyle(
                color: TechColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
                letterSpacing: 0.5,
              ),
            ),
          ),
          GestureDetector(
            onTap: s.isGeneratingReport || s.selectedAnalysisIds.isEmpty ? null : s.generateFocusedReport,
            child: Icon(
              Icons.refresh,
              size: 18,
              color: s.isGeneratingReport
                  ? TechColors.textMuted
                  : TechColors.statusBlue,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Column(
        children: [
          const CircularProgressIndicator(color: TechColors.borderActive),
          const SizedBox(height: 16),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, color: TechColors.statusRed, size: 16),
              SizedBox(width: 8),
              Text(
                'REPORT FAILED',
                style: TextStyle(
                  color: TechColors.statusRed,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            s.reportError ?? 'Unknown error.',
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: s.generateReport,
            child: const Text('RETRY', style: TextStyle(color: TechColors.statusBlue)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.auto_awesome, color: TechColors.textMuted, size: 28),
          const SizedBox(height: 12),
          const Text(
            'No report generated yet.',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: s.generateReport,
            child: const Text('GENERATE REPORT'),
          ),
        ],
      ),
    );
  }

  Widget _buildReportCard(String report) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: MiniMarkdown(text: report),
    );
  }

  // Confirms the AI's cleaning step (the one described in the "Data
  // Quality" section of the report — filled nulls, dropped duplicates)
  // actually produced a new sheet in the workbook, instead of the cleaning
  // only existing as narrated text with nothing to back it up.
  Widget _buildCleanedSheetBanner(String sheetName) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Cleaned data (nulls filled, duplicates removed) written to a new sheet: '$sheetName'.",
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCleanedSheetErrorBanner(String error) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Cleaning happened, but writing it to a new sheet failed: $error",
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════════
  // Analysis-type selection + guidance — additional section, independent
  // of the report above. Lets you define the "problem statement" (which
  // analysis types apply to this dataset), see what business problems each
  // addresses, and optionally regenerate the report above focused on your
  // selection.
  // ═══════════════════════════════════════════════════════════════════════

  Widget _buildAnalysisTypeSection(DataScreenState s) {
    if (s.isSuggestingAnalysisTypes) {
      return _buildLoadingState('Preparing analysis options…');
    }
    if (s.analysisSuggestError != null) {
      return _buildSuggestErrorState(s);
    }
    return _buildAnalysisTypeSelector(s);
  }

  Widget _buildAnalysisTypeSelector(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'SELECT ANALYSIS AFTER DATASET SCAN',
                  style: TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                    letterSpacing: 0.4,
                  ),
                ),
              ),
              GestureDetector(
                onTap: s.isGeneratingReport ? null : s.resetAnalysisSelection,
                child: const Icon(Icons.refresh, size: 16, color: TechColors.statusBlue),
              ),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            'Choose exactly which analytical results should be generated and shown below.',
            style: TextStyle(color: TechColors.textMuted, fontSize: 11, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 14),
          ...s.suggestedAnalysisTypes.map((type) {
            final id = (type['id'] ?? '').toString();
            final title = (type['title'] ?? id).toString();
            final description = (type['description'] ?? '').toString();
            final selected = s.selectedAnalysisIds.contains(id);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: InkWell(
                onTap: s.isGeneratingReport ? null : () {
                  s.setState(() {
                    if (selected) {
                      s.selectedAnalysisIds.remove(id);
                    } else {
                      s.selectedAnalysisIds.add(id);
                    }
                    // Results are no longer guaranteed to match the current
                    // selection, so require an explicit generate action.
                    s.aiReport = null;
                    s.reportText = null;
                    s.reportError = null;
                  });
                },
                child: Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: selected
                        ? TechColors.borderActive.withValues(alpha: 0.12)
                        : Colors.transparent,
                    border: Border.all(
                      color: selected ? TechColors.borderActive : TechColors.borderMuted,
                    ),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        selected ? Icons.check_box : Icons.check_box_outline_blank,
                        size: 19,
                        color: selected ? TechColors.borderActive : TechColors.textMuted,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(title, style: TextStyle(
                              color: selected ? TechColors.textPrimary : TechColors.textMuted,
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'monospace',
                            )),
                            const SizedBox(height: 3),
                            Text(description, style: const TextStyle(
                              color: TechColors.textMuted,
                              fontSize: 11,
                              fontFamily: 'monospace',
                              height: 1.3,
                            )),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: s.isGeneratingReport ? null : () {
                    s.setState(() {
                      s.selectedAnalysisIds = DataScreenState.reportAnalysisOptions
                          .map((e) => e['id']!)
                          .toSet();
                      s.aiReport = null;
                      s.reportText = null;
                    });
                  },
                  child: const Text('SELECT ALL'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: s.isGeneratingReport || s.selectedAnalysisIds.isEmpty
                      ? null
                      : s.generateFocusedReport,
                  style: ElevatedButton.styleFrom(backgroundColor: TechColors.statusBlue),
                  child: Text(
                    s.selectedAnalysisIds.isEmpty
                        ? 'SELECT AN ANALYSIS'
                        : 'RUN SELECTED ANALYSIS (${s.selectedAnalysisIds.length})',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedResults(DataScreenState s) {
    final r = s.aiReport;
    if (r == null) return const SizedBox.shrink();
    final children = <Widget>[];

    void add(String id, Widget child) {
      if (s.selectedAnalysisIds.contains(id)) {
        if (children.isNotEmpty) children.add(const SizedBox(height: 12));
        children.add(child);
      }
    }

    add('executive_summary', _buildExecutiveSummaryResult(r));
    add('statistics', _buildMapResultCard('STATISTICS', r.statistics, Icons.analytics));
    add('trend_detection', _buildTrendResult(r.trendInsight));
    add('outlier_detection', _buildListResultCard('OUTLIER DETECTION', r.outliers, Icons.warning_amber));
    add('kpi_analysis', _buildListResultCard('KPI ANALYSIS', r.detectedKpis, Icons.speed));
    add('recommendations', _buildListResultCard('BUSINESS RECOMMENDATIONS', r.recommendations, Icons.lightbulb_outline));
    add('chart_recommendation', _buildMapResultCard('CHART RECOMMENDATION', r.chartRecommendation, Icons.bar_chart));
    if (s.selectedAnalysisIds.contains('data_quality')) {
      if (children.isNotEmpty) children.add(const SizedBox(height: 12));
      children.add(_buildMapResultCard('DATA QUALITY', r.dataQuality, Icons.verified));
      if (r.dataQuality.isNotEmpty) {
        children.add(const SizedBox(height: 8));
        children.add(_buildExportQualityReportButton(s));
      }
      if (s.qualityReportSheetName != null) {
        children.add(const SizedBox(height: 8));
        children.add(_buildQualityExportBanner(s.qualityReportSheetName!));
      }
      if (s.qualityReportExportError != null) {
        children.add(const SizedBox(height: 8));
        children.add(_buildQualityExportErrorBanner(s.qualityReportExportError!));
      }
    }

    if (s.selectedAnalysisIds.contains('executive_summary') && r.report != null && r.report!.trim().isNotEmpty) {
      children.add(const SizedBox(height: 12));
      children.add(_buildReportCard(r.report!));
    }

    if (children.isEmpty) {
      return _buildEmptyState(s);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  // Exports the full multi-section Quality Report worksheet, built entirely
  // from the same `r.dataQuality` (and sibling fields) already rendered
  // above — no re-analysis, see DataScreenState.exportQualityReportToExcel().
  Widget _buildExportQualityReportButton(DataScreenState s) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: s.isExportingQualityReport ? null : s.exportQualityReportToExcel,
        icon: s.isExportingQualityReport
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: TechColors.statusBlue),
              )
            : const Icon(Icons.table_chart, size: 16, color: TechColors.statusBlue),
        label: Text(
          s.isExportingQualityReport ? 'EXPORTING…' : 'EXPORT FULL QUALITY REPORT TO EXCEL',
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold),
        ),
      ),
    );
  }

  Widget _buildQualityExportBanner(String sheetName) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: Colors.greenAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Quality Report updated on the '$sheetName' sheet.",
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualityExportErrorBanner(String error) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.orangeAccent, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Couldn't export the quality report: $error",
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExecutiveSummaryResult(AiReport r) {
    final data = r.executiveSummary;
    return _buildMapResultCard('EXECUTIVE SUMMARY', data, Icons.auto_awesome);
  }

  Widget _buildTrendResult(Map<String, dynamic> data) {
    return _buildMapResultCard('TREND DETECTION', data, Icons.trending_up);
  }

  Widget _buildMapResultCard(String title, Map<String, dynamic> data, IconData icon) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: TechColors.borderActive, size: 17),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 12),
        if (data.isEmpty)
          const Text('No structured result returned for this analysis.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, fontFamily: 'monospace'))
        else
          ...data.entries.map((e) => _resultEntry(e.key, e.value)),
      ]),
    );
  }

  Widget _buildListResultCard(String title, List<dynamic> items, IconData icon) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: TechColors.borderActive, size: 17),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        ]),
        const SizedBox(height: 12),
        if (items.isEmpty)
          const Text('No results detected.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, fontFamily: 'monospace'))
        else
          ...items.map((item) {
            if (item is Map) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(border: Border.all(color: TechColors.borderMuted), borderRadius: BorderRadius.circular(5)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    ...Map<String, dynamic>.from(item).entries.map((e) => _resultEntry(e.key, e.value)),
                  ]),
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('• ${item.toString()}', style: const TextStyle(color: TechColors.textMuted, fontSize: 11.5, fontFamily: 'monospace', height: 1.35)),
            );
          }),
      ]),
    );
  }

  Widget _resultEntry(String key, dynamic value) {
    String format(dynamic v) {
      if (v is List) return v.map((e) => e.toString()).join(', ');
      if (v is Map) return v.entries.map((e) => '${e.key}: ${e.value}').join(', ');
      return v?.toString() ?? 'N/A';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: RichText(text: TextSpan(children: [
        TextSpan(text: '${key.replaceAll('_', ' ').toUpperCase()}: ', style: const TextStyle(color: TechColors.textPrimary, fontSize: 10.5, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
        TextSpan(text: format(value), style: const TextStyle(color: TechColors.textMuted, fontSize: 10.5, fontFamily: 'monospace')),
      ])),
    );
  }

  Widget _buildGuidanceCard(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.lightbulb_outline, color: TechColors.statusBlue, size: 16),
              SizedBox(width: 8),
              Text(
                'RESULT GUIDANCE',
                style: TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                  letterSpacing: 0.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...s.businessProblemResults.map((result) {
            final title = (result['title'] ?? result['id'] ?? '').toString();
            final problems = (result['business_problems'] is List)
                ? (result['business_problems'] as List)
                .map((e) => (e ?? '').toString().trim())
                .where((s) => s.isNotEmpty)
                .toList()
                : <String>[];
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: TechColors.borderActive,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...problems.map((p) => Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('•  ',
                            style: TextStyle(color: TechColors.statusBlue, fontSize: 12)),
                        Expanded(
                          child: Text(
                            p,
                            style: const TextStyle(
                              color: TechColors.textMuted,
                              fontSize: 11.5,
                              fontFamily: 'monospace',
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildGenerateFocusedReportButton(DataScreenState s) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: s.isGeneratingReport ? null : s.generateFocusedReport,
        style: ElevatedButton.styleFrom(backgroundColor: TechColors.statusBlue),
        child: const Text('REGENERATE REPORT FOR SELECTED ANALYSIS'),
      ),
    );
  }

  Widget _buildSuggestErrorState(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, color: TechColors.statusRed, size: 16),
              SizedBox(width: 8),
              Text(
                'COULD NOT SUGGEST ANALYSIS TYPES',
                style: TextStyle(
                  color: TechColors.statusRed,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            s.analysisSuggestError ?? 'Unknown error.',
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: s.suggestAnalysisTypes,
            child: const Text('RETRY', style: TextStyle(color: TechColors.statusBlue)),
          ),
        ],
      ),
    );
  }

  Widget _buildBusinessContextErrorState(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.error_outline, color: TechColors.statusRed, size: 16),
              SizedBox(width: 8),
              Text(
                'COULD NOT LOAD GUIDANCE',
                style: TextStyle(
                  color: TechColors.statusRed,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            s.businessContextError ?? 'Unknown error.',
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: s.fetchBusinessContext,
            child: const Text('RETRY', style: TextStyle(color: TechColors.statusBlue)),
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestEmptyState(DataScreenState s) {
    return GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.sectionGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 8),
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const Icon(Icons.checklist_rtl, color: TechColors.textMuted, size: 28),
          const SizedBox(height: 12),
          const Text(
            'No analysis types suggested yet.',
            style: TextStyle(
              color: TechColors.textMuted,
              fontSize: 12,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: s.suggestAnalysisTypes,
            child: const Text('SUGGEST ANALYSIS TYPES'),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Lightweight markdown renderer — no external package dependency.
// Handles just what the report agent actually produces:
//   # / ## / ### headers
//   **bold** inline spans
//   - / * bullet list items
//   blank-line-separated paragraphs
// =============================================================================

class MiniMarkdown extends StatelessWidget {
  final String text;
  const MiniMarkdown({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    final widgets = <Widget>[];

    for (final rawLine in lines) {
      final line = rawLine.trimRight();

      if (line.trim().isEmpty) {
        widgets.add(const SizedBox(height: 8));
        continue;
      }

      final headerMatch = RegExp(r'^(#{1,3})\s+(.*)').firstMatch(line);
      if (headerMatch != null) {
        final level = headerMatch.group(1)!.length;
        final content = headerMatch.group(2)!;
        widgets.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 6),
          child: _richTextFromBold(
            content,
            baseStyle: TextStyle(
              color: TechColors.textPrimary,
              fontSize: level == 1 ? 17 : (level == 2 ? 15 : 13.5),
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ));
        continue;
      }

      final bulletMatch = RegExp(r'^[\*\-]\s+(.*)').firstMatch(line);
      if (bulletMatch != null) {
        widgets.add(Padding(
          padding: const EdgeInsets.only(left: 8, bottom: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('•  ',
                  style: TextStyle(color: TechColors.statusBlue, fontSize: 12)),
              Expanded(
                child: _richTextFromBold(
                  bulletMatch.group(1)!,
                  baseStyle: const TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ));
        continue;
      }

      widgets.add(Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: _richTextFromBold(
          line,
          baseStyle: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 12,
            fontFamily: 'monospace',
            height: 1.4,
          ),
        ),
      ));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: widgets);
  }

  /// Splits a line on `**bold**` markers and renders the matched segments
  /// bold, everything else in [baseStyle].
  Widget _richTextFromBold(String line, {required TextStyle baseStyle}) {
    final spans = <TextSpan>[];
    final pattern = RegExp(r'\*\*(.+?)\*\*');
    int last = 0;

    for (final match in pattern.allMatches(line)) {
      if (match.start > last) {
        spans.add(TextSpan(text: line.substring(last, match.start), style: baseStyle));
      }
      spans.add(TextSpan(
        text: match.group(1),
        style: baseStyle.copyWith(fontWeight: FontWeight.bold, color: TechColors.textPrimary),
      ));
      last = match.end;
    }
    if (last < line.length) {
      spans.add(TextSpan(text: line.substring(last), style: baseStyle));
    }

    return RichText(text: TextSpan(children: spans));
  }
}