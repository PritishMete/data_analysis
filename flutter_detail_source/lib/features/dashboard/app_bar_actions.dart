// lib/features/dashboard/app_bar_actions.dart
import 'package:flutter/cupertino.dart';

import '../../core/services/system_diagnostics_service.dart';
import 'data_screen.dart';

/// Compact status line shown under the title bar — reports what data
/// source is currently active. The EXCEL / UPLOAD FILE toggle buttons that
/// used to live in this widget have been removed: [SourceRouter] inside the
/// Pipelines tab is now the single place source selection happens, so
/// duplicating it at the app-bar level was redundant.
///
/// Kept the original class name (`DataSourceToggle`) since `data_screen.dart`
/// calls it directly by that name — only the internal content changed.
class DataSourceToggle extends StatelessWidget {
  final DataScreenState state;
  const DataSourceToggle({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final uploaded = state.uploadedFile;
    final hasSource = state.dataSourceMode == DataSourceMode.uploadedFile
        ? uploaded != null
        : (state.useActiveSelection || state.selectedSourceSheet != null);

    if (!hasSource) return const SizedBox.shrink();

    final String label = state.dataSourceMode == DataSourceMode.uploadedFile && uploaded != null
        ? '${uploaded.fileName} · ${uploaded.dataRowCount} rows'
        : (state.selectedSourceSheet ?? 'Active Selection');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          Icon(
            state.dataSourceMode == DataSourceMode.uploadedFile
                ? CupertinoIcons.doc_text_fill
                : CupertinoIcons.square_stack_3d_up_fill,
            size: 13,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          const SystemStatusButton(),
        ],
      ),
    );
  }
}

class SystemStatusButton extends StatefulWidget {
  const SystemStatusButton({super.key});

  @override
  State<SystemStatusButton> createState() => _SystemStatusButtonState();
}

class _SystemStatusButtonState extends State<SystemStatusButton> {
  bool _busy = false;
  final SystemDiagnosticsService _service = SystemDiagnosticsService();

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  Future<void> _openDiagnostics() async {
    if (_busy) return;
    setState(() => _busy = true);
    Map<String, dynamic>? diagnostics;
    try {
      diagnostics = await _service.check();
    } catch (_) {
      diagnostics = null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    await showCupertinoDialog<void>(
      context: context,
      builder: (_) => _DiagnosticsDialog(diagnostics: diagnostics),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: const EdgeInsets.all(4),
      minimumSize: Size.zero,
      onPressed: _openDiagnostics,
      child: Icon(
        _busy ? CupertinoIcons.refresh : CupertinoIcons.checkmark_seal,
        size: 16,
        color: CupertinoColors.secondaryLabel.resolveFrom(context),
      ),
    );
  }
}

class _DiagnosticsDialog extends StatelessWidget {
  final Map<String, dynamic>? diagnostics;
  const _DiagnosticsDialog({required this.diagnostics});

  @override
  Widget build(BuildContext context) {
    final d = diagnostics;
    final offline = d == null;
    final services = d?['services'] is Map
        ? Map<String, dynamic>.from(d!['services'] as Map)
        : const <String, dynamic>{};
    final privacy = d?['privacy'] is Map
        ? Map<String, dynamic>.from(d!['privacy'] as Map)
        : const <String, dynamic>{};
    final frontend = d?['frontend'] is Map
        ? Map<String, dynamic>.from(d!['frontend'] as Map)
        : const <String, dynamic>{};
    final recovery = d?['recovery'] is List ? List<dynamic>.from(d!['recovery'] as List) : const <dynamic>[];

    return CupertinoAlertDialog(
      title: const Text('INSIGHTFLOW SYSTEM STATUS'),
      content: SingleChildScrollView(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: offline
              ? const [
                  _StatusLine(label: 'Backend', value: 'Offline'),
                  SizedBox(height: 10),
                  Text('Recovery: Start the local InsightFlow backend.'),
                ]
              : [
                  _StatusLine(label: 'Backend', value: d['backend']?['status']?.toString() ?? 'Unavailable'),
                  _StatusLine(label: 'Backend version', value: d['backend']?['version']?.toString() ?? 'Unknown'),
                  _StatusLine(label: 'Detail Analysis', value: frontend['status']?.toString() ?? 'Unavailable'),
                  _StatusLine(label: 'Build', value: frontend['detail_analysis_build_id']?.toString() ?? 'Unknown'),
                  _StatusLine(label: 'Analysis engine', value: services['analysis_engine']?.toString() ?? 'Unavailable'),
                  _StatusLine(label: 'Conversation state', value: services['conversation_state']?.toString() ?? 'Unavailable'),
                  _StatusLine(label: 'Report engine', value: services['report_generation']?.toString() ?? 'Unavailable'),
                  _StatusLine(label: 'Local dataset processing', value: privacy['local_dataset_processing'] == true ? 'Active' : 'Disabled'),
                  _StatusLine(label: 'External raw dataset transmission', value: privacy['raw_dataset_external_transmission'] == false ? 'Disabled' : 'Enabled'),
                  const SizedBox(height: 10),
                  if (recovery.isEmpty)
                    const Text('All local services are healthy.')
                  else
                    ...recovery.map((item) {
                      final action = item is Map ? Map<String, dynamic>.from(item) : const <String, dynamic>{};
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('${action['title'] ?? 'Recovery'}: ${action['action'] ?? 'Check local services.'}'),
                      );
                    }),
                ],
        ),
      ),
      actions: [
        CupertinoDialogAction(
          child: const Text('Close'),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}

class _StatusLine extends StatelessWidget {
  final String label;
  final String value;
  const _StatusLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label)),
          const SizedBox(width: 8),
          Flexible(child: Text(value, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
