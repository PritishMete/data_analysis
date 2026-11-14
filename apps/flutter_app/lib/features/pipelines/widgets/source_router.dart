// lib/features/pipelines/widgets/source_router.dart
import 'package:flutter/cupertino.dart';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/powerbi_detail_analysis_service.dart';
import '../../dashboard/data_screen.dart';
import 'shared/glass_picker_sheet.dart';

/// The landing-page source picker — Active Selection / Named Sheet / Upload
/// File, rendered as a dark liquid-glass card with a pill tab switcher.
enum _SourceTab { activeSelection, namedSheet, uploadedFile, detailAnalysis }

class SourceRouter extends StatelessWidget {
  final DataScreenState state;
  const SourceRouter({super.key, required this.state});

  _SourceTab get _currentTab {
    if (state.showDetailAnalysis) return _SourceTab.detailAnalysis;
    if (state.dataSourceMode == DataSourceMode.uploadedFile) {
      return _SourceTab.uploadedFile;
    }
    return state.useActiveSelection
        ? _SourceTab.activeSelection
        : _SourceTab.namedSheet;
  }

  Future<void> _selectTab(BuildContext context, _SourceTab tab) async {
    if (tab == _SourceTab.detailAnalysis) {
      state.setState(() => state.showDetailAnalysis = true);
      return;
    }
    switch (tab) {
      case _SourceTab.activeSelection:
        state.setState(() {
          state.showDetailAnalysis = false;
          state.dataSourceMode = DataSourceMode.excel;
          state.useActiveSelection = true;
          state.selectedSourceSheet = null;
        });
        await state.syncHeadersSilently();
        break;

      case _SourceTab.namedSheet:
        await state.refreshWorksheetNames();
        state.setState(() {
          state.showDetailAnalysis = false;
          state.dataSourceMode = DataSourceMode.excel;
          state.useActiveSelection = false;
          if (state.availableSheets.isNotEmpty) {
            state.selectedSourceSheet ??= state.availableSheets.first;
          }
        });
        await state.syncHeadersSilently();
        break;

      case _SourceTab.uploadedFile:
        // Delegates to the real upload pipeline on DataScreenState — it
        // already handles picking, parsing, resetting analysisData/view,
        // applying headers, and showing a notification. Re-implementing
        // any of that here would just drift out of sync with it.
        await state.pickAndLoadFile();
        if (state.mounted)
          state.setState(() => state.showDetailAnalysis = false);
        break;

      case _SourceTab.detailAnalysis:
        state.setState(() => state.showDetailAnalysis = true);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = _currentTab;

    return GlassCard(
      padding: const EdgeInsets.all(16),
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 14),
          _buildTabRow(context, tab),
          const SizedBox(height: 14),
          switch (tab) {
            _SourceTab.activeSelection => _buildActiveSelectionPanel(context),
            _SourceTab.namedSheet => _buildNamedSheetPanel(context),
            _SourceTab.uploadedFile => _buildUploadPanel(context),
            _SourceTab.detailAnalysis => _buildDetailAnalysisPanel(context),
          },
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: CupertinoColors.white.withValues(alpha: 0.08),
            shape: BoxShape.circle,
          ),
          child: Icon(
            CupertinoIcons.square_stack_3d_up_fill,
            size: 16,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Data Source',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
            Text(
              'Choose where the pipeline should read from',
              style: TextStyle(
                fontSize: 12,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildTabRow(BuildContext context, _SourceTab tab) {
    Widget chip(String label, _SourceTab value, {bool webOnly = false}) {
      if (webOnly && !kIsWeb) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: GlassChip(
          label: label,
          selected: tab == value,
          onTap: () => _selectTab(context, value),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          chip('Active Selection', _SourceTab.activeSelection, webOnly: true),
          chip('Named Sheet', _SourceTab.namedSheet, webOnly: true),
          chip('Upload File', _SourceTab.uploadedFile),
          chip('Detail Analysis', _SourceTab.detailAnalysis),
        ],
      ),
    );
  }

  Widget _buildActiveSelectionPanel(BuildContext context) {
    return GlassListTile(
      leading: const Icon(CupertinoIcons.cursor_rays),
      title: const Text('Using the live Excel selection'),
      subtitle: const Text(
        'The selected cell identifies the dataset around it',
      ),
      isLast: true,
    );
  }

  Widget _buildNamedSheetPanel(BuildContext context) {
    return GlassPicker(
      value: state.selectedSourceSheet,
      placeholder: 'Select a worksheet',
      icon: const Icon(CupertinoIcons.chevron_down),
      onTap: () => _showSheetPicker(context),
    );
  }

  Widget _buildUploadPanel(BuildContext context) {
    final uploaded = state.uploadedFile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (uploaded != null)
          GlassListTile(
            leading: const Icon(CupertinoIcons.doc_text_fill),
            title: Text(
              uploaded.fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${uploaded.formatLabel} · ${uploaded.dataRowCount} rows',
            ),
            trailing: GestureDetector(
              onTap: state.clearUploadedFile,
              child: const Icon(CupertinoIcons.xmark_circle_fill),
            ),
            isLast: true,
          )
        else
          GlassListTile(
            leading: const Icon(CupertinoIcons.tray_arrow_up),
            title: const Text('No file uploaded yet'),
            subtitle: const Text('CSV, TSV, JSON, or XLSX'),
            isLast: true,
          ),
        const SizedBox(height: 12),
        GlassButton(
          onTap: state.isUploadingFile
              ? () {}
              : () => _selectTab(context, _SourceTab.uploadedFile),
          enabled: !state.isUploadingFile,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          icon: state.isUploadingFile
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.folder_open),
          label: state.isUploadingFile
              ? 'Importing…'
              : (uploaded == null ? 'Choose File' : 'Replace File'),
        ),
      ],
    );
  }

  Widget _buildDetailAnalysisPanel(BuildContext context) {
    final report = state.detailAnalysisResult;
    final reportText = report == null
        ? null
        : const JsonEncoder.withIndent('  ').convert(report);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Analyze multiple datasets or every non-empty worksheet together to propose fact tables, dimension tables, relationships, and a star schema.',
          style: TextStyle(fontSize: 12, height: 1.35),
        ),
        const SizedBox(height: 10),
        const Text(
          'This uses the local Detail Analysis backend. It does not replace the active-selection scan.',
          style: TextStyle(fontSize: 11),
        ),
        const SizedBox(height: 12),
        if (state.detailAnalysisFileNames.isNotEmpty)
          GlassListTile(
            leading: const Icon(CupertinoIcons.doc_on_doc_fill),
            title: Text(
              '${state.detailAnalysisFileNames.length} dataset(s) selected',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              state.detailAnalysisFileNames.join(', '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            isLast: true,
          ),
        if (state.detailAnalysisError != null) ...[
          const SizedBox(height: 8),
          Text(
            state.detailAnalysisError!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ],
        if (reportText != null) ...[
          const SizedBox(height: 10),
          Container(
            constraints: const BoxConstraints(maxHeight: 360),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CupertinoColors.black.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                reportText,
                style: const TextStyle(fontSize: 11, height: 1.35),
              ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        GlassButton(
          onTap: state.isDetailAnalysisLoading
              ? () {}
              : _runPowerBiDetailAnalysis,
          enabled: !state.isDetailAnalysisLoading,
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          icon: state.isDetailAnalysisLoading
              ? const CupertinoActivityIndicator()
              : const Icon(CupertinoIcons.chart_bar_fill),
          label: state.isDetailAnalysisLoading
              ? 'Profiling datasets…'
              : (report == null ? 'Choose Power BI Files' : 'Run Again'),
        ),
        const SizedBox(height: 8),
        GlassButton(
          onTap: () async {
            await launchUrl(
              Uri.parse('http://127.0.0.1:8000/ui'),
              webOnlyWindowName: '_blank',
            );
          },
          width: double.infinity,
          height: 46,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          icon: const Icon(CupertinoIcons.arrow_up_right_square),
          label: 'Open Detail Analysis Console',
        ),
      ],
    );
  }

  Future<void> _runPowerBiDetailAnalysis() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'xlsx', 'xlsm', 'xls', 'json'],
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    state.setState(() {
      state.isDetailAnalysisLoading = true;
      state.detailAnalysisError = null;
      state.detailAnalysisResult = null;
      state.detailAnalysisFileNames = picked.files
          .map((file) => file.name)
          .toList();
    });
    try {
      final result = await PowerBiDetailAnalysisService().analyze(picked.files);
      if (!state.mounted) return;
      state.setState(() => state.detailAnalysisResult = result);
    } catch (error) {
      if (!state.mounted) return;
      state.setState(() => state.detailAnalysisError = error.toString());
    } finally {
      if (state.mounted)
        state.setState(() => state.isDetailAnalysisLoading = false);
    }
  }

  Future<void> _showSheetPicker(BuildContext context) async {
    await state.refreshWorksheetNames();
    if (state.availableSheets.isEmpty) return;

    final picked = await showGlassPickerSheet<String>(
      context: context,
      title: 'Select Worksheet',
      items: state.availableSheets,
      itemLabel: (s) => s,
      initialItem: state.selectedSourceSheet,
    );

    if (picked != null) {
      state.setState(() {
        state.useActiveSelection = false;
        state.selectedSourceSheet = picked;
      });
      await state.syncHeadersSilently();
    }
  }
}
