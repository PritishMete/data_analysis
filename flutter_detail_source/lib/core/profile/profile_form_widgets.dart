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
  bool showOptionSubtitle = true,
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
                                  subtitle: showOptionSubtitle && option.subtitle.isNotEmpty
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
        SizedBox(
          height: 46,
          child: InkWell(
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
        ),
      ],
    );
  }
}
