import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';

/// Shared profile control height so editable fields and selectors use one visual size.
const double kProfileFieldHeight = 46.0;

class ProfileOption {
  const ProfileOption({
    required this.value,
    required this.label,
    this.subtitle = '',
  });

  final String value;
  final String label;
  final String subtitle;
}

Future<ProfileOption?> showProfileOptionPicker(
  BuildContext context, {
  required String title,
  required List<ProfileOption> options,
  String? selectedValue,
  bool showOptionSubtitle = true,
}) async {
  final search = TextEditingController();
  final scrollController = ScrollController();
  try {
    return await showModalBottomSheet<ProfileOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        var highlightedIndex = 0;
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final query = search.text.trim().toLowerCase();
            final filtered = options.where((option) {
              return query.isEmpty ||
                  option.label.toLowerCase().contains(query) ||
                  option.value.toLowerCase().contains(query) ||
                  option.subtitle.toLowerCase().contains(query);
            }).toList();
            if (highlightedIndex >= filtered.length) {
              highlightedIndex = filtered.isEmpty ? 0 : filtered.length - 1;
            }

            void selectHighlighted() {
              if (filtered.isEmpty) return;
              Navigator.of(sheetContext).pop(filtered[highlightedIndex]);
            }

            void moveHighlight(int delta) {
              if (filtered.isEmpty) return;
              setSheetState(() {
                highlightedIndex =
                    (highlightedIndex + delta).clamp(0, filtered.length - 1);
              });
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!scrollController.hasClients) return;
                final position = scrollController.position;
                const itemExtent = 52.0;
                final itemTop = highlightedIndex * itemExtent;
                final itemBottom = itemTop + itemExtent;
                var target = position.pixels;
                if (itemTop < position.pixels) {
                  target = itemTop;
                } else if (itemBottom >
                    position.pixels + position.viewportDimension) {
                  target = itemBottom - position.viewportDimension;
                }
                target = target
                    .clamp(0.0, position.maxScrollExtent)
                    .toDouble();
                scrollController.jumpTo(target);
              });
            }

            return SafeArea(
              child: Container(
                margin: const EdgeInsets.all(12),
                padding: const EdgeInsets.all(16),
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(sheetContext).height * .82,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF10121A).withValues(alpha: .97),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: TechColors.borderActive.withValues(alpha: .28),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: TechColors.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(sheetContext).pop(),
                          icon: const Icon(Icons.close, size: 18),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Focus(
                      onKeyEvent: (_, event) {
                        if (event is! KeyDownEvent) {
                          return KeyEventResult.ignored;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
                          moveHighlight(1);
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          moveHighlight(-1);
                          return KeyEventResult.handled;
                        }
                        if (event.logicalKey == LogicalKeyboardKey.enter ||
                            event.logicalKey ==
                                LogicalKeyboardKey.numpadEnter) {
                          selectHighlighted();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: search,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onChanged: (_) {
                          setSheetState(() {
                            highlightedIndex = 0;
                          });
                          if (scrollController.hasClients) {
                            scrollController.jumpTo(0);
                          }
                        },
                        onSubmitted: (_) => selectHighlighted(),
                        decoration: InputDecoration(
                          hintText: 'Search ' + title,
                          prefixIcon: const Icon(Icons.search, size: 18),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: .06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? const Center(
                              child: Text(
                                'No matching options.',
                                style: TextStyle(color: TechColors.textMuted),
                              ),
                            )
                          : ListView.builder(
                              controller: scrollController,
                              itemExtent: 52,
                              itemCount: filtered.length,
                              itemBuilder: (_, index) {
                                final option = filtered[index];
                                return ListTile(
                                  dense: true,
                                  selected: index == highlightedIndex,
                                  selectedTileColor:
                                      TechColors.borderActive.withValues(
                                    alpha: .16,
                                  ),
                                  title: Text(option.label),
                                  subtitle: showOptionSubtitle &&
                                          option.subtitle.isNotEmpty
                                      ? Text(option.subtitle)
                                      : null,
                                  trailing: option.value == selectedValue
                                      ? const Icon(
                                          Icons.check_circle,
                                          color: TechColors.statusGreen,
                                          size: 18,
                                        )
                                      : null,
                                  onTap: () =>
                                      Navigator.of(sheetContext).pop(option),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  } finally {
    search.dispose();
    scrollController.dispose();
  }
}

class ProfileSelectField extends StatefulWidget {
  const ProfileSelectField({
    super.key,
    required this.label,
    required this.value,
    required this.placeholder,
    required this.onTap,
  });

  final String label;
  final String? value;
  final String placeholder;
  final VoidCallback? onTap;

  @override
  State<ProfileSelectField> createState() => _ProfileSelectFieldState();
}

class _ProfileSelectFieldState extends State<ProfileSelectField> {
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(debugLabel: '${widget.label} selector');
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selected = widget.value?.trim().isNotEmpty ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          widget.label.toUpperCase(),
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: .5,
          ),
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: kProfileFieldHeight,
          child: Focus(
            focusNode: _focusNode,
            canRequestFocus: widget.onTap != null,
            onKeyEvent: (_, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                      event.logicalKey == LogicalKeyboardKey.space)) {
                widget.onTap?.call();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: InkWell(
              canRequestFocus: false,
              onTap: widget.onTap,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: _focusNode.hasFocus
                        ? TechColors.borderActive
                        : Colors.transparent,
                  ),
                ),
                child: GlassContainer(
                  useOwnLayer: true,
                  quality: GlassQuality.minimal,
                  settings: const LiquidGlassSettings(
                    thickness: 10,
                    blur: 4,
                    glassColor: Color(0x14FFFFFF),
                    refractiveIndex: 1.05,
                  ),
                  shape: const LiquidRoundedSuperellipse(borderRadius: 10),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 13,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          selected ? widget.value! : widget.placeholder,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? TechColors.textPrimary
                                : TechColors.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const Icon(
                        Icons.keyboard_arrow_down,
                        size: 18,
                        color: TechColors.textMuted,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
