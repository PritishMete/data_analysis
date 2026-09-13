// lib/features/dashboard/app_bar_actions.dart
import 'package:flutter/cupertino.dart';

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
        ],
      ),
    );
  }
}