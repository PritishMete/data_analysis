import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';

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
}) async {
  final search = TextEditingController();
  try {
    return showModalBottomSheet<ProfileOption>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setState) {
            final query = search.text.trim().toLowerCase();
            final filtered = options.where((option) {
              return query.isEmpty ||
                  option.label.toLowerCase().contains(query) ||
                  option.value.toLowerCase().contains(query) ||
                  option.subtitle.toLowerCase().contains(query);
            }).toList();

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
                    TextField(
                      controller: search,
                      onChanged: (_) => setState(() {}),
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
                              itemCount: filtered.length,
                              itemBuilder: (_, index) {
                                final option = filtered[index];
                                return ListTile(
                                  dense: true,
                                  title: Text(option.label),
                                  subtitle: option.subtitle.isEmpty
                                      ? null
                                      : Text(option.subtitle),
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
  }
}

class ProfileSelectField extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final selected = value?.trim().isNotEmpty ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: .5,
          ),
        ),
        const SizedBox(height: 6),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
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
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 13),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    selected ? value! : placeholder,
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
      ],
    );
  }
}


/// Liquid Glass text input with an animated floating label.
///
/// The label begins inside the field, floats to the top border on focus or
/// when text is present, and returns inside when the field is empty and
/// unfocused. The widget is shared by profile/onboarding forms so the
/// interaction stays visually consistent without depending on Material's
/// default TextField styling.
class ProfileFloatingLabelField extends StatefulWidget {
  const ProfileFloatingLabelField({
    super.key,
    required this.controller,
    required this.label,
    this.placeholder,
    this.enabled = true,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String? placeholder;
  final bool enabled;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;

  @override
  State<ProfileFloatingLabelField> createState() =>
      _ProfileFloatingLabelFieldState();
}

class _ProfileFloatingLabelFieldState extends State<ProfileFloatingLabelField> {
  late final FocusNode _focusNode;
  bool _focused = false;

  bool get _floated => _focused || widget.controller.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode()..addListener(_handleFocusChange);
    widget.controller.addListener(_handleTextChange);
  }

  @override
  void didUpdateWidget(covariant ProfileFloatingLabelField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_handleTextChange);
      widget.controller.addListener(_handleTextChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleTextChange);
    _focusNode
      ..removeListener(_handleFocusChange)
      ..dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    if (mounted) setState(() => _focused = _focusNode.hasFocus);
  }

  void _handleTextChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final floated = _floated;
    final borderColor = _focused
        ? TechColors.borderActive.withValues(alpha: .72)
        : TechColors.borderActive.withValues(alpha: .28);

    return Semantics(
      textField: true,
      label: widget.label,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(10),
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
              padding: const EdgeInsets.only(
                left: 12,
                right: 12,
                top: 10,
                bottom: 4,
              ),
              child: TextField(
                controller: widget.controller,
                focusNode: _focusNode,
                enabled: widget.enabled,
                keyboardType: widget.keyboardType,
                inputFormatters: widget.inputFormatters,
                onChanged: widget.onChanged,
                style: const TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 11,
                ),
                cursorColor: TechColors.borderActive,
                maxLines: 1,
                decoration: InputDecoration(
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.only(
                    top: floated ? 10 : 2,
                    bottom: 7,
                  ),
                  hintText: floated ? widget.placeholder : null,
                  hintStyle: const TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            left: floated ? 9 : 12,
            top: floated ? -7 : 13,
            child: IgnorePointer(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                curve: Curves.easeOutCubic,
                padding: floated
                    ? const EdgeInsets.symmetric(horizontal: 4)
                    : EdgeInsets.zero,
                color: floated
                    ? const Color(0xFF10121A).withValues(alpha: .94)
                    : Colors.transparent,
                child: AnimatedDefaultTextStyle(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOutCubic,
                  style: TextStyle(
                    color: floated
                        ? (_focused
                            ? TechColors.textPrimary
                            : TechColors.textMuted)
                        : TechColors.textMuted,
                    fontSize: floated ? 9 : 11,
                    fontWeight:
                        floated ? FontWeight.w600 : FontWeight.w400,
                  ),
                  child: Text(widget.label),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
