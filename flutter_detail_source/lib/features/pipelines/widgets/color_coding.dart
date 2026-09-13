// lib/features/pipelines/widgets/color_coding.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../dashboard/data_screen.dart';
import 'shared/glass_picker_sheet.dart';

/// Preset palette swatches offered for the min / mid / max stops of the
/// colour scale (hex strings, no leading '#').
const List<String> _kSwatches = [
  'F8696B', // red
  'FFC7CE', // light red
  'FFEB84', // yellow
  'FFD966', // amber
  '63BE7B', // green
  'C6EFCE', // light green
  '5B9BD5', // blue
  '9DC3E6', // light blue
  'A9D18E', // sage
  'FFFFFF', // white
];

/// UI for applying an Excel "Color Scale" conditional format to a column,
/// with a header-aware toggle. Restyled as a dark liquid-glass card.
class ColorCoding extends StatelessWidget {
  final DataScreenState state;
  const ColorCoding({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        children: [
          GlassListTile(
            leading: const Icon(CupertinoIcons.paintbrush_fill),
            title: const Text('Conditional colour formatting'),
            subtitle: const Text('Applies a colour scale by value'),
            trailing: GlassSwitch(
              value: state.enableColorCoding,
              onChanged: (v) => state.setState(() => state.enableColorCoding = v),
            ),
            isLast: !state.enableColorCoding,
          ),
          if (state.enableColorCoding)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GlassListTile.standalone(
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    leading: const Icon(CupertinoIcons.list_bullet_below_rectangle),
                    title: const Text('My data has headers', style: TextStyle(fontSize: 13)),
                    subtitle: const Text('Row 1 = headers, row 2+ = data'),
                    trailing: GlassSwitch(
                      value: state.colorCodeHasHeaders,
                      onChanged: (v) => state.setState(() {
                        state.colorCodeHasHeaders = v;
                        if (v && state.colorCodeColumn == null && state.detectedHeaders.isNotEmpty) {
                          state.colorCodeColumn = state.detectedHeaders.first;
                        }
                      }),
                    ),
                  ),
                  const SizedBox(height: 12),

                  if (state.colorCodeHasHeaders) ...[
                    GlassFormField(
                      label: 'Column to colour',
                      child: state.detectedHeaders.isEmpty
                          ? _emptyHint(context, 'No headers detected — pick a source first.')
                          : GlassPicker(
                        value: state.detectedHeaders.contains(state.colorCodeColumn)
                            ? state.colorCodeColumn
                            : state.detectedHeaders.first,
                        placeholder: 'Select column',
                        onTap: () async {
                          final picked = await showGlassPickerSheet<String>(
                            context: context,
                            title: 'Column',
                            items: state.detectedHeaders,
                            itemLabel: (h) => h,
                            initialItem: state.detectedHeaders.contains(state.colorCodeColumn)
                                ? state.colorCodeColumn
                                : state.detectedHeaders.first,
                          );
                          if (picked != null) {
                            state.setState(() => state.colorCodeColumn = picked);
                          }
                        },
                      ),
                    ),
                  ] else ...[
                    GlassFormField(
                      label: 'Column letter',
                      helperText: 'Data starts at row 1',
                      child: GlassTextField(
                        controller: state.colorCodeColumnLetterController,
                        placeholder: 'e.g. C',
                        inputFormatters: [UpperCaseTextFormatter()],
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),

                  Text(
                    'SCALE TYPE',
                    style: TextStyle(
                      color: CupertinoColors.secondaryLabel.resolveFrom(context),
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      GlassChip(
                        label: '2-Color',
                        selected: state.colorCodeScaleType == '2-color',
                        onTap: () => state.setState(() => state.colorCodeScaleType = '2-color'),
                      ),
                      const SizedBox(width: 8),
                      GlassChip(
                        label: '3-Color',
                        selected: state.colorCodeScaleType == '3-color',
                        onTap: () => state.setState(() => state.colorCodeScaleType = '3-color'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  _colorStopRow(
                    context,
                    label: 'Min value colour',
                    currentHex: state.colorCodeMinColor,
                    onPick: (hex) => state.colorCodeMinColor = hex,
                  ),
                  if (state.colorCodeScaleType == '3-color') ...[
                    const SizedBox(height: 14),
                    _colorStopRow(
                      context,
                      label: 'Mid value colour',
                      currentHex: state.colorCodeMidColor,
                      onPick: (hex) => state.colorCodeMidColor = hex,
                    ),
                  ],
                  const SizedBox(height: 14),
                  _colorStopRow(
                    context,
                    label: 'Max value colour',
                    currentHex: state.colorCodeMaxColor,
                    onPick: (hex) => state.colorCodeMaxColor = hex,
                  ),

                  const SizedBox(height: 18),
                  GlassButton(
                    onTap: state.isApplyingColorScale ? () {} : state.runColorCodingPipeline,
                    enabled: !state.isApplyingColorScale,
                    width: double.infinity,
                    height: 46,
                    shape: const LiquidRoundedSuperellipse(borderRadius: 14),
                    icon: state.isApplyingColorScale
                        ? const CupertinoActivityIndicator()
                        : const Icon(CupertinoIcons.paintbrush),
                    label: state.isApplyingColorScale ? 'Applying…' : 'Apply Colour Scale',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyHint(BuildContext context, String text) {
    return Container(
      height: 44,
      alignment: Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _colorStopRow(
      BuildContext context, {
        required String label,
        required String currentHex,
        required void Function(String hex) onPick,
      }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: _hexToColor(currentHex),
                shape: BoxShape.circle,
                border: Border.all(color: CupertinoColors.white.withValues(alpha: 0.2)),
              ),
            ),
            const SizedBox(width: 6),
            Text('#$currentHex', style: const TextStyle(fontSize: 11)),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _kSwatches.map((hex) {
            final selected = hex == currentHex;
            return GestureDetector(
              onTap: () => onPick(hex),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: _hexToColor(hex),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected
                        ? CupertinoColors.white.withValues(alpha: 0.9)
                        : CupertinoColors.white.withValues(alpha: 0.15),
                    width: selected ? 2 : 1,
                  ),
                  boxShadow: selected
                      ? [
                    BoxShadow(
                      color: _hexToColor(hex).withValues(alpha: 0.5),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                      : null,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Color _hexToColor(String hex) {
    final cleaned = hex.replaceAll('#', '');
    return Color(int.parse('FF$cleaned', radix: 16));
  }
}

/// Flutter's `TextCapitalization` only affects the on-screen keyboard hint —
/// it doesn't force the typed characters themselves to uppercase. Since
/// [GlassTextField] doesn't expose a `textCapitalization` param anyway, this
/// formatter does the actual uppercasing of whatever the user types.
class UpperCaseTextFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue,
      TextEditingValue newValue,
      ) {
    return newValue.copyWith(
      text: newValue.text.toUpperCase(),
      selection: newValue.selection,
    );
  }
}