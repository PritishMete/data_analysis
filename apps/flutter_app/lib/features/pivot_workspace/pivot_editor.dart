// lib/features/pivot_workspace/pivot_editor.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../dashboard/data_screen.dart';
import '../pipelines/widgets/shared/glass_picker_sheet.dart';

const List<Map<String, String>> _kPivotOps = [
  {'id': 'sum', 'label': 'Sum'},
  {'id': 'average', 'label': 'Average'},
  {'id': 'count', 'label': 'Count'},
  {'id': 'max', 'label': 'Max'},
  {'id': 'min', 'label': 'Min'},
];

class PivotEditor extends StatefulWidget {
  final DataScreenState state;
  const PivotEditor({super.key, required this.state});

  @override
  State<PivotEditor> createState() => _PivotEditorState();
}

class _PivotEditorState extends State<PivotEditor> {
  @override
  Widget build(BuildContext context) {
    final headers = widget.state.pivotSourceHeaders.isNotEmpty
        ? widget.state.pivotSourceHeaders
        : widget.state.detectedHeaders;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        GlassCard(
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: CupertinoColors.white.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  CupertinoIcons.square_grid_2x2_fill,
                  size: 16,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.state.activePivotSheetName ?? 'Pivot Sheet',
                      style: TextStyle(
                        color: CupertinoColors.label.resolveFrom(context),
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Live pivot workspace — edits apply in place',
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(context),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const _ActiveBadge(),
            ],
          ),
        ),
        const SizedBox(height: 16),

        GlassCard(
          padding: const EdgeInsets.all(16),
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionHeader(
                context,
                'Row fields',
                onAdd: () => setState(() => widget.state.pivotEditorRowFields.add(headers.first)),
              ),
              const SizedBox(height: 8),
              ...List.generate(widget.state.pivotEditorRowFields.length, (idx) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: GlassPicker(
                          value: widget.state.pivotEditorRowFields[idx],
                          placeholder: 'Select dimension',
                          onTap: () async {
                            final picked = await showGlassPickerSheet<String>(
                              context: context,
                              title: 'Row field',
                              items: headers,
                              itemLabel: (h) => h,
                              initialItem: widget.state.pivotEditorRowFields[idx],
                            );
                            if (picked != null) {
                              setState(() => widget.state.pivotEditorRowFields[idx] = picked);
                            }
                          },
                        ),
                      ),
                      if (widget.state.pivotEditorRowFields.length > 1)
                        GlassIconButton(
                          size: 36,
                          icon: const Icon(CupertinoIcons.xmark),
                          onPressed: () =>
                              setState(() => widget.state.pivotEditorRowFields.removeAt(idx)),
                        ),
                    ],
                  ),
                );
              }),

              const SizedBox(height: 16),
              _sectionHeader(
                context,
                'Value fields',
                onAdd: () => setState(() => widget.state.pivotEditorValueFields
                    .add({'field': headers.last, 'op': 'sum'})),
              ),
              const SizedBox(height: 8),
              ...List.generate(widget.state.pivotEditorValueFields.length, (idx) {
                final entry = widget.state.pivotEditorValueFields[idx];
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: GlassPicker(
                          value: entry['field'],
                          placeholder: 'Field',
                          onTap: () async {
                            final picked = await showGlassPickerSheet<String>(
                              context: context,
                              title: 'Field',
                              items: headers,
                              itemLabel: (h) => h,
                              initialItem: entry['field'],
                            );
                            if (picked != null) {
                              setState(() => widget.state.pivotEditorValueFields[idx]['field'] = picked);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 2,
                        child: GlassPicker(
                          value: _opLabel(entry['op']),
                          placeholder: 'Op',
                          onTap: () async {
                            final picked = await showGlassPickerSheet<Map<String, String>>(
                              context: context,
                              title: 'Function',
                              items: _kPivotOps,
                              itemLabel: (o) => o['label']!,
                              initialItem: _kPivotOps.firstWhere(
                                    (o) => o['id'] == entry['op'],
                                orElse: () => _kPivotOps.first,
                              ),
                            );
                            if (picked != null) {
                              setState(() => widget.state.pivotEditorValueFields[idx]['op'] = picked['id']!);
                            }
                          },
                        ),
                      ),
                      if (widget.state.pivotEditorValueFields.length > 1)
                        GlassIconButton(
                          size: 36,
                          icon: const Icon(CupertinoIcons.xmark),
                          onPressed: () =>
                              setState(() => widget.state.pivotEditorValueFields.removeAt(idx)),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
        const SizedBox(height: 20),

        GlassButton(
          onTap: (widget.state.pivotEditorRefreshing ||
              widget.state.pivotEditorRowFields.isEmpty ||
              widget.state.pivotEditorValueFields.isEmpty)
              ? () {}
              : widget.state.rerunPivot,
          enabled: !(widget.state.pivotEditorRefreshing ||
              widget.state.pivotEditorRowFields.isEmpty ||
              widget.state.pivotEditorValueFields.isEmpty),
          width: double.infinity,
          height: 48,
          style: GlassButtonStyle.prominent,
          shape: const LiquidRoundedSuperellipse(borderRadius: 16),
          icon: widget.state.pivotEditorRefreshing
              ? const CupertinoActivityIndicator(color: CupertinoColors.white)
              : const Icon(CupertinoIcons.refresh),
          label: widget.state.pivotEditorRefreshing ? 'Updating…' : 'Re-apply Changes',
        ),
        const SizedBox(height: 10),

        GlassButton(
          onTap: () => widget.state.setState(() => widget.state.selectedView = 'PIPELINES'),
          width: double.infinity,
          height: 40,
          style: GlassButtonStyle.transparent,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          icon: const Icon(CupertinoIcons.back, size: 16),
          label: 'Back to pipeline controls',
        ),
      ],
    );
  }

  String? _opLabel(String? id) {
    if (id == null) return null;
    for (final op in _kPivotOps) {
      if (op['id'] == id) return op['label'];
    }
    return id;
  }

  Widget _sectionHeader(BuildContext context, String title, {required VoidCallback onAdd}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          title.toUpperCase(),
          style: TextStyle(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
        ),
        GlassIconButton(
          size: 28,
          iconSize: 16,
          icon: const Icon(CupertinoIcons.add),
          onPressed: onAdd,
        ),
      ],
    );
  }
}

class _ActiveBadge extends StatelessWidget {
  const _ActiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: CupertinoColors.activeGreen.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: CupertinoColors.activeGreen.withValues(alpha: 0.5)),
      ),
      child: const Text(
        'ACTIVE',
        style: TextStyle(
          color: CupertinoColors.activeGreen,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}