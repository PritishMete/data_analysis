import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../src/renderer/liquid_glass_renderer.dart';
import '../../widgets/interactive/glass_button.dart';
import '../../widgets/overlays/glass_dialog.dart';
import '../../theme/glow_design_system.dart';

class RankingLimitChoice {
  final int? limit;
  final bool all;
  const RankingLimitChoice._({this.limit, this.all = false});
  const RankingLimitChoice.count(int value) : this._(limit: value);
  const RankingLimitChoice.all() : this._(all: true);
}

class RankingLimitOptionGrid extends StatelessWidget {
  const RankingLimitOptionGrid({
    required this.direction,
    required this.onSelected,
    super.key,
  });

  final String direction;
  final ValueChanged<RankingLimitChoice> onSelected;

  static const _gap = 8.0;
  static const _buttonHeight = 44.0;
  static const _buttonShape = LiquidRoundedSuperellipse(borderRadius: 12);

  @override
  Widget build(BuildContext context) {
    final labels = <({String label, RankingLimitChoice choice, bool primary})>[
      (
        label: '${direction} 5',
        choice: const RankingLimitChoice.count(5),
        primary: false,
      ),
      (
        label: '${direction} 10',
        choice: const RankingLimitChoice.count(10),
        primary: false,
      ),
      (
        label: '${direction} 20',
        choice: const RankingLimitChoice.count(20),
        primary: false,
      ),
      (
        label: 'All',
        choice: const RankingLimitChoice.all(),
        primary: true,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final columnWidth = (constraints.maxWidth - _gap) / 2;
        return GridView.builder(
          primary: false,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            crossAxisSpacing: _gap,
            mainAxisSpacing: _gap,
            mainAxisExtent: _buttonHeight,
          ),
          itemCount: labels.length,
          itemBuilder: (context, index) {
            final option = labels[index];
            return SizedBox(
              width: columnWidth,
              height: _buttonHeight,
              child: _RankingOptionButton(
                label: option.label,
                primary: option.primary,
                shape: _buttonShape,
                glowColor: option.primary ? GlowDesignSystem.activeColor(context) : GlowDesignSystem.activeColor(context).withValues(alpha: 0.55),
                onTap: () => onSelected(option.choice),
              ),
            );
          },
        );
      },
    );
  }
}

class _RankingOptionButton extends StatefulWidget {
  const _RankingOptionButton({
    required this.label,
    required this.primary,
    required this.shape,
    required this.glowColor,
    required this.onTap,
  });

  final String label;
  final bool primary;
  final LiquidShape shape;
  final Color glowColor;
  final VoidCallback onTap;

  @override
  State<_RankingOptionButton> createState() => _RankingOptionButtonState();
}

class _RankingOptionButtonState extends State<_RankingOptionButton> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final emphasized = widget.primary || _hovered || _focused;
    final glow = emphasized ? GlowDesignSystem.activeColor(context) : widget.glowColor;

    return FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? const Color(0x99007AFF) : Colors.transparent,
            width: _focused ? 1.2 : 1,
          ),
        ),
        child: GlassButton.custom(
          onTap: widget.onTap,
          width: double.infinity,
          height: 42,
          shape: widget.shape,
          glowColor: glow,
          glowOpacity: emphasized ? GlowDesignSystem.activeOpacity : 0.55,
          interactionScale: 0.985,
          stretch: 0.0,
          label: widget.label,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                fontWeight: widget.primary ? FontWeight.w700 : FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class RankingCustomNumberSection extends StatefulWidget {
  const RankingCustomNumberSection({
    required this.onSelected,
    super.key,
  });

  final ValueChanged<int> onSelected;

  @override
  State<RankingCustomNumberSection> createState() =>
      _RankingCustomNumberSectionState();
}

class _RankingCustomNumberSectionState
    extends State<RankingCustomNumberSection> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    widget.onSelected(int.parse(_controller.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _controller,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              labelText: 'Custom number',
              hintText: 'Enter a positive integer',
              isDense: true,
              filled: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 11,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            validator: (value) {
              final parsed = RankingLimitDialog.parseCustomCount(value);
              return parsed == null ? 'Enter a positive integer.' : null;
            },
            onFieldSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          _RankingOptionButton(
            label: 'Use Custom',
            primary: true,
            shape: const LiquidRoundedSuperellipse(borderRadius: 12),
            glowColor: GlowDesignSystem.activeColor(context),
            onTap: _submit,
          ),
        ],
      ),
    );
  }
}

class RankingLimitDialog {
  static int? parseCustomCount(String? value) {
    final parsed = int.tryParse((value ?? '').trim());
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static Future<RankingLimitChoice?> show({
    required BuildContext context,
    required bool descending,
    required String groupingColumn,
    required int availableCount,
  }) {
    final direction = descending ? 'Top' : 'Bottom';

    void closeWith(BuildContext dialogContext, RankingLimitChoice choice) {
      Navigator.of(dialogContext).pop(choice);
    }

    return GlassDialog.show<RankingLimitChoice>(
      context: context,
      barrierDismissible: false,
      maxWidth: 440,
      title: 'How many $groupingColumn${groupingColumn.endsWith('s') ? '' : 's'} would you like to see?',
      message:
          'Choose how many grouped results to display. $direction results are ranked after aggregation. '
          'Equal-value ties use the group label as a deterministic tie-breaker, so the requested count is exact.',
      content: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.52,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(top: 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                RankingLimitOptionGrid(
                  direction: direction,
                  onSelected: (choice) => closeWith(context, choice),
                ),
                const SizedBox(height: 10),
                RankingCustomNumberSection(
                  onSelected: (value) =>
                      closeWith(context, RankingLimitChoice.count(value)),
                ),
                const SizedBox(height: 8),
                Text(
                  availableCount == 0
                      ? 'No grouped results are available.'
                      : '$availableCount grouped results are available. Counts larger than this will return all available groups.',
                  style: const TextStyle(fontSize: 11, height: 1.3),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }
}
