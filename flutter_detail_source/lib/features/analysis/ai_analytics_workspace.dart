import 'package:flutter/material.dart';

import '../../app_colors.dart';
import '../dashboard/data_screen.dart';
import '../neural_chat/chat_console.dart';

/// A dedicated analytics workspace that reuses DataScreenState's existing
/// authenticated data and analysis operations. Workspace navigation is local
/// UI state; it does not grant new dataset permissions.
class AiAnalyticsWorkspace extends StatefulWidget {
  final DataScreenState state;

  const AiAnalyticsWorkspace({super.key, required this.state});

  @override
  State<AiAnalyticsWorkspace> createState() => _AiAnalyticsWorkspaceState();
}

class _AiAnalyticsWorkspaceState extends State<AiAnalyticsWorkspace> {
  int _selectedSection = 0;

  static const List<_WorkspaceSection> _sections = <_WorkspaceSection>[
    _WorkspaceSection('Overview', Icons.dashboard_outlined),
    _WorkspaceSection('Data Explorer', Icons.table_chart_outlined),
    _WorkspaceSection('AI Analyst', Icons.auto_awesome_outlined),
    _WorkspaceSection('Reports', Icons.summarize_outlined),
    _WorkspaceSection('Monitoring', Icons.monitor_heart_outlined),
    _WorkspaceSection('Governance', Icons.admin_panel_settings_outlined),
    _WorkspaceSection('History', Icons.history_outlined),
  ];

  DataScreenState get state => widget.state;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(context),
          const SizedBox(height: 16),
          _buildSectionNavigation(context),
          const SizedBox(height: 14),
          Expanded(
            child: IndexedStack(
              index: _selectedSection,
              children: [
                _OverviewSection(state: state),
                _DataExplorerSection(state: state),
                _AiAnalystSection(state: state),
                _ReportsSection(state: state),
                _MonitoringSection(state: state),
                _GovernanceSection(state: state),
                _HistorySection(state: state),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: TechColors.borderActive.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: TechColors.borderActive.withValues(alpha: 0.4),
            ),
          ),
          child: const Icon(
            Icons.auto_awesome,
            color: TechColors.borderActive,
            size: 24,
          ),
        ),
        const SizedBox(width: 12),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Analytics Workspace',
                style: TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'Explore data, ask questions, review reports, and monitor analytical activity.',
                style: TextStyle(color: TechColors.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSectionNavigation(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: TechColors.panelBg.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TechColors.borderMuted),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(5),
        child: Row(
          children: List<Widget>.generate(_sections.length, (index) {
            final section = _sections[index];
            final selected = index == _selectedSection;
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Semantics(
                button: true,
                selected: selected,
                child: Material(
                  color: selected
                      ? colorScheme.primary.withValues(alpha: 0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => setState(() => _selectedSection = index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            section.icon,
                            size: 17,
                            color: selected
                                ? colorScheme.primary
                                : TechColors.textMuted,
                          ),
                          const SizedBox(width: 7),
                          Text(
                            section.label,
                            style: TextStyle(
                              color: selected
                                  ? colorScheme.primary
                                  : TechColors.textMuted,
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _WorkspaceSection {
  final String label;
  final IconData icon;

  const _WorkspaceSection(this.label, this.icon);
}

class _WorkspacePanel extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  final Widget? trailing;

  const _WorkspacePanel({
    required this.title,
    required this.subtitle,
    required this.child,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TechColors.panelBg.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TechColors.borderMuted),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: TechColors.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: const TextStyle(
                        color: TechColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _OverviewSection extends StatelessWidget {
  final DataScreenState state;

  const _OverviewSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final report = state.aiReport;
    final summary = state.analysisData?['summary'];
    final managedRowCount = summary is Map ? summary['rows'] : null;
    final uploadedRowCount = state.uploadedFile?.dataRowCount;
    final rowCount = uploadedRowCount ?? (managedRowCount is num ? managedRowCount.toInt() : null);
    return ListView(
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _MetricCard(
              label: 'DATA COLUMNS',
              value: '${state.detectedHeaders.length}',
              icon: Icons.view_column_outlined,
            ),
            _MetricCard(
              label: 'UPLOADED ROWS',
              value: rowCount == null ? 'Workbook' : rowCount.toString(),
              icon: Icons.table_rows_outlined,
            ),
            _MetricCard(
              label: 'DETECTED KPIs',
              value: '${report?.detectedKpis.length ?? 0}',
              icon: Icons.insights_outlined,
            ),
            _MetricCard(
              label: 'OUTLIER FINDINGS',
              value: '${report?.outliers.length ?? 0}',
              icon: Icons.query_stats,
            ),
          ],
        ),
        const SizedBox(height: 14),
        _WorkspacePanel(
          title: 'Workspace status',
          subtitle: 'Current session signals from the existing data screen.',
          child: Column(
            children: [
              _StatusRow(
                label: 'Data source',
                value: state.dataSourceMode == DataSourceMode.uploadedFile
                    ? (state.currentFileName ?? 'Uploaded file')
                    : state.activeSheetName,
                icon: Icons.storage_outlined,
              ),
              _StatusRow(
                label: 'AI report',
                value: state.isGeneratingReport
                    ? 'Generating'
                    : report == null
                        ? 'Not generated yet'
                        : 'Available',
                icon: Icons.assessment_outlined,
              ),
              _StatusRow(
                label: 'Dataset context',
                value: state.isManagedDatasetSession
                    ? 'Managed dataset session'
                    : 'Current workbook or local source',
                icon: Icons.dataset_outlined,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _WorkspacePanel(
          title: 'Get started',
          subtitle: 'Choose a section above to continue your analysis.',
          child: const Text(
            'Inspect the available columns in Data Explorer, ask a question in AI Analyst, or generate a report. Governance and History show the session context available to this app; they do not create new permissions or claim server-side audit history that has not been loaded.',
            style: TextStyle(color: TechColors.textMuted, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _DataExplorerSection extends StatefulWidget {
  final DataScreenState state;

  const _DataExplorerSection({required this.state});

  @override
  State<_DataExplorerSection> createState() => _DataExplorerSectionState();
}

class _DataExplorerSectionState extends State<_DataExplorerSection> {
  List<List<dynamic>>? _rows;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadPreview();
  }

  Future<void> _loadPreview() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final state = widget.state;
      List<List<dynamic>> rows;
      if (state.isManagedDatasetSession) {
        // Display only the bounded preview returned by the authorized profile endpoint.
        final headers = state.detectedHeaders;
        final preview = state.analysisData?['preview'];
        rows = <List<dynamic>>[
          headers.cast<dynamic>(),
          if (preview is List)
            for (final item in preview.whereType<Map>())
              headers.map((header) => item[header]).toList(growable: false),
        ].where((row) => row.isNotEmpty).toList(growable: false);
      } else if (state.dataSourceMode == DataSourceMode.uploadedFile) {
        final uploadedRows = state.uploadedFile?.rows ?? <List<dynamic>>[];
        rows = uploadedRows
            .map((row) => List<dynamic>.from(row))
            .toList(growable: false);
      } else {
        final raw = await state.safeFetchActiveSheetData();
        if (raw == null || raw.trim().isEmpty) {
          rows = <List<dynamic>>[];
        } else {
          rows = decodeSourceMatrix(raw)
              .whereType<List>()
              .map((row) => List<dynamic>.from(row))
              .toList(growable: false);
        }
      }
      if (!mounted) return;
      setState(() => _rows = rows);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final headers = widget.state.detectedHeaders;
    final rows = _rows ?? <List<dynamic>>[];
    final hasRows = rows.isNotEmpty;
    final displayHeaders = hasRows
        ? rows.first.map((value) => value?.toString() ?? '').toList()
        : headers;
    final dataRows = hasRows ? rows.skip(1).take(8).toList() : <List<dynamic>>[];

    return ListView(
      children: [
        _WorkspacePanel(
          title: 'Dataset schema',
          subtitle: 'Columns detected from the active analysis source.',
          trailing: IconButton(
            tooltip: 'Refresh preview',
            onPressed: _loading ? null : _loadPreview,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          child: headers.isEmpty
              ? const _EmptyState(
                  message: 'No columns are available yet. Open a dataset or select a source worksheet first.',
                )
              : Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: headers
                      .map(
                        (header) => Chip(
                          avatar: const Icon(Icons.view_column_outlined, size: 16),
                          label: Text(header),
                        ),
                      )
                      .toList(),
                ),
        ),
        const SizedBox(height: 14),
        _WorkspacePanel(
          title: 'Data preview',
          subtitle: hasRows
              ? 'Showing up to 8 rows from the current source. Preview is read-only.'
              : 'A read-only preview of the current source.',
          child: _loading && _rows == null
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _EmptyState(message: 'Could not load preview: $_error')
                  : !hasRows || displayHeaders.isEmpty
                      ? const _EmptyState(
                          message: 'No preview rows are available. For workbook data, select a range or worksheet and refresh.',
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: DataTable(
                            columns: displayHeaders
                                .take(8)
                                .map(
                                  (header) => DataColumn(
                                    label: Text(
                                      header.isEmpty ? '(blank)' : header,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ),
                                )
                                .toList(),
                            rows: dataRows
                                .map(
                                  (row) => DataRow(
                                    cells: List<DataCell>.generate(
                                      displayHeaders.take(8).length,
                                      (index) => DataCell(
                                        Text(
                                          index < row.length
                                              ? (row[index]?.toString() ?? '')
                                              : '',
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                        ),
        ),
        if (widget.state.availableSheets.isNotEmpty) ...[
          const SizedBox(height: 14),
          _WorkspacePanel(
            title: 'Available worksheets',
            subtitle: 'Worksheets reported by the current workbook session.',
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: widget.state.availableSheets
                  .map((sheet) => Chip(label: Text(sheet)))
                  .toList(),
            ),
          ),
        ],
      ],
    );
  }
}

class _AiAnalystSection extends StatelessWidget {
  final DataScreenState state;

  const _AiAnalystSection({required this.state});

  static const List<String> _suggestedPrompts = <String>[
    'Summarize the most important findings',
    'Find unusual patterns and possible risks',
    'Compare the strongest and weakest metrics',
    'What should I investigate next?',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _WorkspacePanel(
          title: 'Ask your data',
          subtitle: 'Questions use the existing chat and privacy/authorization flow.',
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _suggestedPrompts
                .map(
                  (prompt) => ActionChip(
                    avatar: const Icon(Icons.arrow_outward, size: 14),
                    label: Text(prompt),
                    onPressed: state.isSearchingChat
                        ? null
                        : () {
                            state.chatController.text = prompt;
                            state.processChatQuery();
                          },
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        Expanded(child: ChatConsole(state: state, fullHeight: true)),
      ],
    );
  }
}

class _ReportsSection extends StatelessWidget {
  final DataScreenState state;

  const _ReportsSection({required this.state});

  @override
  Widget build(BuildContext context) {
    final report = state.aiReport;
    return ListView(
      children: [
        _WorkspacePanel(
          title: 'AI reports',
          subtitle: 'Generate an analytical report from the current authorized source.',
          trailing: FilledButton.tonalIcon(
            onPressed: state.isGeneratingReport ? null : state.generateReport,
            icon: state.isGeneratingReport
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow, size: 18),
            label: Text(state.isGeneratingReport ? 'Generating…' : 'Generate'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _MetricCard(
                    label: 'KPIs',
                    value: '${report?.detectedKpis.length ?? 0}',
                    icon: Icons.insights_outlined,
                  ),
                  _MetricCard(
                    label: 'RECOMMENDATIONS',
                    value: '${report?.recommendations.length ?? 0}',
                    icon: Icons.lightbulb_outline,
                  ),
                  _MetricCard(
                    label: 'OUTLIERS',
                    value: '${report?.outliers.length ?? 0}',
                    icon: Icons.query_stats,
                  ),
                ],
              ),
              if (state.reportError?.isNotEmpty == true) ...[
                const SizedBox(height: 12),
                _Notice(message: state.reportError!),
              ],
              const SizedBox(height: 12),
              if (state.reportText?.isNotEmpty == true)
                SelectableText(
                  state.reportText!,
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    height: 1.5,
                  ),
                )
              else
                const _EmptyState(
                  message: 'No report has been generated in this session yet.',
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MonitoringSection extends StatelessWidget {
  final DataScreenState state;

  const _MonitoringSection({required this.state});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        _WorkspacePanel(
          title: 'Live session monitoring',
          subtitle: 'Current operation indicators; this is not a background alerting service.',
          child: Column(
            children: [
              _StatusRow(
                label: 'Report generation',
                value: state.isGeneratingReport ? 'In progress' : 'Idle',
                icon: Icons.assessment_outlined,
                isBusy: state.isGeneratingReport,
              ),
              _StatusRow(
                label: 'AI analyst query',
                value: state.isSearchingChat ? 'In progress' : 'Idle',
                icon: Icons.forum_outlined,
                isBusy: state.isSearchingChat,
              ),
              _StatusRow(
                label: 'File upload',
                value: state.isUploadingFile ? 'In progress' : 'Idle',
                icon: Icons.upload_file_outlined,
                isBusy: state.isUploadingFile,
              ),
              _StatusRow(
                label: 'Pipeline processing',
                value: state.pipelineProcessing ? 'In progress' : 'Idle',
                icon: Icons.account_tree_outlined,
                isBusy: state.pipelineProcessing,
              ),
            ],
          ),
        ),
        if (state.reportError?.isNotEmpty == true) ...[
          const SizedBox(height: 14),
          _WorkspacePanel(
            title: 'Latest report issue',
            subtitle: 'Error details reported by the existing analysis flow.',
            child: _Notice(message: state.reportError!),
          ),
        ],
        if (state.detailAnalysisError?.isNotEmpty == true) ...[
          const SizedBox(height: 14),
          _WorkspacePanel(
            title: 'Detail analysis issue',
            subtitle: 'Error details reported by the existing detail analysis flow.',
            child: _Notice(message: state.detailAnalysisError!),
          ),
        ],
      ],
    );
  }
}

class _GovernanceSection extends StatelessWidget {
  final DataScreenState state;

  const _GovernanceSection({required this.state});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        _WorkspacePanel(
          title: 'Access and dataset context',
          subtitle: 'Session facts exposed by the current application state.',
          child: Column(
            children: [
              _StatusRow(
                label: 'Managed dataset session',
                value: state.isManagedDatasetSession ? 'Active' : 'Not active',
                icon: Icons.dataset_outlined,
              ),
              _StatusRow(
                label: 'Source mode',
                value: state.dataSourceMode == DataSourceMode.uploadedFile
                    ? 'Uploaded file'
                    : state.dataSourceMode == DataSourceMode.excelLive
                        ? 'Live Excel'
                        : 'Excel workbook',
                icon: Icons.storage_outlined,
              ),
              _StatusRow(
                label: 'Upload capability',
                value: state.canUploadDataset ? 'Enabled by resolved capability' : 'Unavailable / fail-closed',
                icon: Icons.upload_file_outlined,
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        const _WorkspacePanel(
          title: 'Authorization boundary',
          subtitle: 'Workspace navigation does not grant dataset access.',
          child: Text(
            'Analysis and data access continue through the application’s existing authenticated services. Dataset permissions must be enforced by the backend for every request. This panel intentionally does not infer a user role, invent a permission grant, or provide controls that bypass the established authorization flow.',
            style: TextStyle(color: TechColors.textMuted, height: 1.5),
          ),
        ),
      ],
    );
  }
}

class _HistorySection extends StatelessWidget {
  final DataScreenState state;

  const _HistorySection({required this.state});

  @override
  Widget build(BuildContext context) {
    final items = state.chatHistory.reversed.toList(growable: false);
    return ListView(
      children: [
        _WorkspacePanel(
          title: 'Recent analyst activity',
          subtitle: 'Conversation entries available in the current in-memory session.',
          child: items.isEmpty
              ? const _EmptyState(
                  message: 'No analyst conversation history is available in this session yet.',
                )
              : Column(
                  children: List<Widget>.generate(items.length, (index) {
                    final entry = items[index];
                    final prompt = (entry['query'] ??
                            entry['question'] ??
                            entry['prompt'] ??
                            entry['message'] ??
                            entry['user'] ??
                            'Conversation item')
                        .toString();
                    final response = (entry['response'] ??
                            entry['answer'] ??
                            entry['result'] ??
                            entry['assistant'])
                        ?.toString();
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.chat_bubble_outline),
                      title: Text(
                        prompt,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: response == null || response.isEmpty
                          ? null
                          : Text(
                              response,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                    );
                  }),
                ),
        ),
        const SizedBox(height: 14),
        _WorkspacePanel(
          title: 'Latest report',
          subtitle: 'Report content retained by the current screen state.',
          child: state.reportText?.isNotEmpty == true
              ? SelectableText(
                  state.reportText!,
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    height: 1.5,
                  ),
                )
              : const _EmptyState(
                  message: 'No report content is available in this session.',
                ),
        ),
        const SizedBox(height: 10),
        const Text(
          'This history reflects in-memory session state only. It is not presented as durable audit history.',
          style: TextStyle(color: TechColors.textMuted, fontSize: 11),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;

  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: TechColors.panelBg.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: TechColors.borderMuted),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: TechColors.borderActive),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final bool isBusy;

  const _StatusRow({
    required this.label,
    required this.value,
    required this.icon,
    this.isBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Icon(icon, size: 18, color: TechColors.borderActive),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: TechColors.textMuted, fontSize: 12),
            ),
          ),
          if (isBusy) ...[
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: const TextStyle(
                color: TechColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;

  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: TechColors.panelBg.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TechColors.borderMuted),
      ),
      child: Text(
        message,
        style: const TextStyle(
          color: TechColors.textMuted,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String message;

  const _Notice({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TechColors.statusRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: TechColors.statusRed.withValues(alpha: 0.4)),
      ),
      child: Text(
        message,
        style: const TextStyle(color: TechColors.textPrimary, fontSize: 12),
      ),
    );
  }
}
