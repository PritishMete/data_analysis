// lib/features/pipelines/widgets/shared/glass_picker_sheet.dart
import 'package:flutter/cupertino.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Shows a liquid-glass wheel picker sheet and resolves with the selected
/// item, or `null` if the user cancels.
///
/// Two ways to select an item, both fully wired this time:
///  1. Scroll/drag the wheel so the item you want is centered, then tap
///     **Done**. `onSelectedItemChanged` keeps a local index in sync as you
///     scroll, and Done pops with `items[index]` — this is the part that
///     was previously missing entirely (the wheel scrolled visually but
///     nothing ever called `Navigator.pop` with a value).
///  2. Click directly on any row — the wheel animates to center that row
///     and immediately confirms the selection, so a single click applies
///     it without a separate scroll-then-confirm step.
Future<T?> showGlassPickerSheet<T>({
  required BuildContext context,
  required List<T> items,
  required String Function(T item) itemLabel,
  String? title,
  T? initialItem,
}) {
  if (items.isEmpty) return Future.value(null);

  final initialIndex = initialItem != null ? items.indexOf(initialItem) : -1;

  return showCupertinoModalPopup<T>(
    context: context,
    builder: (sheetContext) => _GlassPickerSheetContent<T>(
      title: title,
      items: items,
      itemLabel: itemLabel,
      initialIndex: initialIndex >= 0 ? initialIndex : 0,
    ),
  );
}

class _GlassPickerSheetContent<T> extends StatefulWidget {
  const _GlassPickerSheetContent({
    required this.items,
    required this.itemLabel,
    required this.initialIndex,
    this.title,
  });

  final List<T> items;
  final String Function(T item) itemLabel;
  final int initialIndex;
  final String? title;

  @override
  State<_GlassPickerSheetContent<T>> createState() =>
      _GlassPickerSheetContentState<T>();
}

class _GlassPickerSheetContentState<T>
    extends State<_GlassPickerSheetContent<T>> {
  late int _index = widget.initialIndex;
  late final FixedExtentScrollController _scrollController =
  FixedExtentScrollController(initialItem: widget.initialIndex);

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Handles a direct click on a row: animates the wheel so that row is
  /// centered, then confirms the selection once the animation settles.
  Future<void> _selectByTap(int index) async {
    if (index == _index) {
      // Already centered — a click here just confirms it, no need to wait
      // on an animation that wouldn't move anything anyway.
      Navigator.of(context).pop(widget.items[index]);
      return;
    }
    setState(() => _index = index);
    await _scrollController.animateToItem(
      index,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (mounted) Navigator.of(context).pop(widget.items[index]);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        height: 320,
        decoration: BoxDecoration(
          color: CupertinoColors.systemBackground.resolveFrom(context),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            _buildToolbar(context),
            GlassDivider(color: CupertinoColors.separator.resolveFrom(context)),
            Expanded(
              child: CupertinoPicker(
                itemExtent: 40,
                scrollController: _scrollController,
                // Keeps the tracked index in sync while the user drags the
                // wheel — this is what Done reads from.
                onSelectedItemChanged: (i) => setState(() => _index = i),
                children: List.generate(widget.items.length, (index) {
                  return GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => _selectByTap(index),
                    child: Center(
                      child: Text(
                        widget.itemLabel(widget.items[index]),
                        style: TextStyle(
                          color: CupertinoColors.label.resolveFrom(context),
                          fontWeight:
                          index == _index ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          Expanded(
            child: Text(
              widget.title ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            // Reads whatever _index currently is — kept correct by both the
            // scroll handler above and _selectByTap.
            onPressed: () => Navigator.of(context).pop(widget.items[_index]),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}