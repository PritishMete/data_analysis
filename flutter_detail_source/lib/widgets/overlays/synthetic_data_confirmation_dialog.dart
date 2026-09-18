import 'package:flutter/cupertino.dart';
import 'glass_dialog.dart';

enum SyntheticNumberFormat { integer, decimal }

class SyntheticDataConfirmation {
  const SyntheticDataConfirmation({required this.columnName, required this.min, required this.max, required this.format, required this.seed, required this.outputWorksheet});
  final String columnName; final double min; final double max; final SyntheticNumberFormat format; final int? seed; final String outputWorksheet;
}

class SyntheticDataConfirmationDialog {
  static Future<SyntheticDataConfirmation?> show({
    required BuildContext context, required String sourceWorksheet, required String proposedColumn,
    required double defaultMin, required double defaultMax, required SyntheticNumberFormat defaultFormat,
    required String proposedOutputWorksheet, required bool existingColumn,
  }) async {
    final column = TextEditingController(text: proposedColumn), min = TextEditingController(text: _number(defaultMin)), max = TextEditingController(text: _number(defaultMax)), seed = TextEditingController();
    final key = GlobalKey<FormState>(); var format = defaultFormat;
    final result = await GlassDialog.show<SyntheticDataConfirmation>(
      context: context, barrierDismissible: false, maxWidth: 440,
      title: 'Create hypothetical data',
      message: 'These values are synthetic hypotheses for analysis. They are not actual revenue or business data.',
      content: StatefulBuilder(builder: (context, setState) => Form(
        key: key,
        child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _summary('Target worksheet', sourceWorksheet), _summary('Output worksheet', '$proposedOutputWorksheet (new)'),
          _summary('Existing values', existingColumn ? 'Protected — original values will not be overwritten.' : 'Protected — no existing values will be overwritten.'),
          const SizedBox(height: 10),
          _field(column, 'Generated column name', (v) => (v ?? '').trim().isEmpty ? 'Enter a column name' : null),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: _field(min, 'Minimum', _numberValidator, const TextInputType.numberWithOptions(decimal: true, signed: true))),
            const SizedBox(width: 8),
            Expanded(child: _field(max, 'Maximum', _numberValidator, const TextInputType.numberWithOptions(decimal: true, signed: true))),
          ]),
          const SizedBox(height: 8), const Text('Number format', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)), const SizedBox(height: 6),
          CupertinoSlidingSegmentedControl<SyntheticNumberFormat>(
            groupValue: format,
            children: const {
              SyntheticNumberFormat.integer: Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7), child: Text('Integer')),
              SyntheticNumberFormat.decimal: Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7), child: Text('Decimal')),
            },
            onValueChanged: (v) { if (v != null) setState(() => format = v); },
          ),
          const SizedBox(height: 8),
          _field(seed, 'Random seed (optional)', (v) => (v ?? '').trim().isEmpty || int.tryParse(v!.trim()) != null ? null : 'Use a whole-number seed', TextInputType.number),
          const SizedBox(height: 8),
          const Text('A new worksheet will always be created. The original worksheet remains unchanged.', style: TextStyle(fontSize: 11, height: 1.35)),
        ])),
      )),
      actions: [
        GlassDialogAction(label: 'Cancel', onPressed: () => Navigator.pop(context)),
        GlassDialogAction(label: 'Create', isPrimary: true, onPressed: () {
          if (!(key.currentState?.validate() ?? false)) return;
          final lo = double.tryParse(min.text.trim()), hi = double.tryParse(max.text.trim());
          if (lo == null || hi == null || hi < lo) return;
          Navigator.pop(context, SyntheticDataConfirmation(columnName: column.text.trim(), min: lo, max: hi, format: format, seed: seed.text.trim().isEmpty ? null : int.parse(seed.text.trim()), outputWorksheet: proposedOutputWorksheet));
        }),
      ],
    );
    column.dispose(); min.dispose(); max.dispose(); seed.dispose(); return result;
  }
  static String _number(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  static String? _numberValidator(String? v) => double.tryParse((v ?? '').trim()) == null ? 'Enter a number' : null;
  static Widget _summary(String label, String value) => Padding(padding: const EdgeInsets.only(bottom: 5), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 112, child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))), Expanded(child: Text(value, style: const TextStyle(fontSize: 11)))]));
  static Widget _field(TextEditingController c, String label, String? Function(String?) validator, TextInputType? type) => CupertinoTextFormFieldRow(controller: c, keyboardType: type, validator: validator, padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 4), placeholder: label, decoration: BoxDecoration(color: CupertinoColors.systemFill, borderRadius: BorderRadius.circular(9)));
}