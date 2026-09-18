import 'package:flutter/material.dart';
import '../../widgets/interactive/glass_button.dart';
import '../../widgets/overlays/glass_dialog.dart';

class RankingLimitChoice {
  final int? limit;
  final bool all;
  const RankingLimitChoice._({this.limit, this.all = false});
  const RankingLimitChoice.count(int value) : this._(limit: value);
  const RankingLimitChoice.all() : this._(all: true);
}

class RankingLimitDialog {
  static Future<RankingLimitChoice?> show({
    required BuildContext context,
    required bool descending,
    required String groupingColumn,
    required int availableCount,
  }) {
    final direction = descending ? 'Top' : 'Bottom';
    final customController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    void closeWith(BuildContext dialogContext, RankingLimitChoice choice) {
      Navigator.of(dialogContext).pop(choice);
    }

    return GlassDialog.show<RankingLimitChoice>(
      context: context,
      barrierDismissible: false,
      maxWidth: 440,
      title: 'How many ' + groupingColumn + 's would you like to see?',
      message:
          'Choose how many grouped results to display. ' + direction +
          ' results are ranked after aggregation. Equal-value ties use the group label as a deterministic tie-breaker, so the requested count is exact.',
      content: StatefulBuilder(
        builder: (dialogContext, setState) {
          final options = <int>[5, 10, 20];
          return Form(
            key: formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final count in options)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: GlassButton.custom(
                      onTap: () => closeWith(dialogContext, RankingLimitChoice.count(count)),
                      height: 44,
                      child: Text('$direction $count', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 8),
                  child: GlassButton.custom(
                    onTap: () => closeWith(dialogContext, const RankingLimitChoice.all()),
                    height: 44,
                    child: const Text('All', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ),
                TextFormField(
                  controller: customController,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(labelText: 'Custom number', hintText: 'Enter a positive integer'),
                  validator: (value) {
                    final parsed = int.tryParse((value ?? '').trim());
                    if (parsed == null || parsed <= 0) return 'Enter a positive integer.';
                    return null;
                  },
                  onFieldSubmitted: (_) {
                    if (!(formKey.currentState?.validate() ?? false)) return;
                    final parsed = int.parse(customController.text.trim());
                    closeWith(dialogContext, RankingLimitChoice.count(parsed));
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  availableCount == 0
                      ? 'No grouped results are available.'
                      : '$availableCount grouped results are available. Counts larger than this will return all available groups.',
                  style: const TextStyle(fontSize: 11, height: 1.35),
                ),
              ],
            ),
          );
        },
      ),
      actions: [
        GlassDialogAction(label: 'Cancel', onPressed: () => Navigator.of(context).pop()),
      ],
    ).whenComplete(customController.dispose);
  }
}
