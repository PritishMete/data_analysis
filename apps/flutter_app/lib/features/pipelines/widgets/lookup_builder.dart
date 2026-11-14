// lib/features/pipelines/widgets/lookup_builder.dart
import 'package:flutter/material.dart';
import '../../../app_colors.dart';
import '../../dashboard/data_screen.dart';

class LookupBuilder extends StatelessWidget {
  final DataScreenState state;
  const LookupBuilder({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: TechColors.panelBg,
        border: Border.all(color: TechColors.borderMuted),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildItemLabel("LOOKUP ARCHITECTURE ENGINE STYLE"),
          const SizedBox(height: 6),
          Row(
            children: [
              _buildRadioOption("VLOOKUP", "vlookup"),
              _buildRadioOption("HLOOKUP", "hlookup"),
              _buildRadioOption("XLOOKUP", "xlookup"),
            ],
          ),
          const SizedBox(height: 12),

          // ── 1. lookup_value : SOURCE SHEET KEY COLUMN ──
          _buildItemLabel("YOUR SHEET — KEY COLUMN (lookup_value, e.g., product_name)"),
          const SizedBox(height: 6),
          _styledDropdown<String>(
            value: state.lookupSourceColumn,
            hint: "Select key column from your data",
            items: state.detectedHeaders
                .map((h) => DropdownMenuItem(value: h, child: Text(h, style: const TextStyle(fontSize: 12, color: Colors.white))))
                .toList(),
            onChanged: (v) {
              state.setState(() {
                state.lookupSourceColumn = v;
                state.lookupSelectedSourceValue = null;
                state.lookupSourceColumnValues = [];
              });
              if (v != null && state.lookupUseStaticSearch) {
                state.fetchLookupSourceColumnValues();
              }
            },
          ),
          const SizedBox(height: 12),

          // ── 2. RESTORED STATIC SEARCH TOGGLE & DROPDOWN VALUE SELECTOR ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildItemLabel("LOOK UP ONE SPECIFIC VALUE (OPTIONAL)"),
              Switch(
                value: state.lookupUseStaticSearch,
                activeColor: TechColors.borderActive,
                onChanged: (v) {
                  state.setState(() => state.lookupUseStaticSearch = v);
                  if (v && state.lookupSourceColumn != null && state.lookupSourceColumnValues.isEmpty) {
                    state.fetchLookupSourceColumnValues();
                  }
                },
              ),
            ],
          ),
          if (state.lookupUseStaticSearch) ...[
            const SizedBox(height: 6),
            _buildRowValueDropdown(),
            const SizedBox(height: 4),
            const Text(
              "ON: Extracts a single item row. OFF: Matches every row automatically.",
              style: TextStyle(color: TechColors.textMuted, fontSize: 10),
            ),
            const SizedBox(height: 12),
          ],

          // ── 3. table_array : REFERENCE SHEET ──
          _buildItemLabel("REFERENCE SHEET (table_array — whole sheet)"),
          const SizedBox(height: 6),
          _styledDropdown<String>(
            value: state.lookupTargetSheet,
            hint: "Select reference / master data sheet",
            items: state.availableSheets
                .map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 12, color: Colors.white))))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                state.setState(() {
                  state.lookupTargetSheet = v;
                  state.lookupRefMatchColumn = null;
                  state.lookupReturnColumnHeader = null;
                  state.lookupSelectedReturnColumns = [];
                });
                state.fetchLookupReferenceHeaders(v);
              }
            },
          ),
          const SizedBox(height: 8),

          // table_array header toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: TechColors.bgBlack,
              border: Border.all(color: TechColors.borderMuted),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Text(
                    "REFERENCE SHEET'S ROW 1 IS A HEADER ROW",
                    style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
                Switch(
                  value: state.lookupTableHasHeaders,
                  activeColor: TechColors.borderActive,
                  onChanged: (v) => state.setState(() => state.lookupTableHasHeaders = v),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── REFERENCE SHEET MATCH COLUMN ──
          if (state.lookupReferenceHeaders.isNotEmpty) ...[
            _buildItemLabel("REFERENCE SHEET — MATCH COLUMN (column to search in)"),
            const SizedBox(height: 6),
            _styledDropdown<String>(
              value: state.lookupRefMatchColumn,
              hint: "e.g. ID column in reference sheet",
              items: state.lookupReferenceHeaders
                  .map((h) => DropdownMenuItem(value: h, child: Text(h, style: const TextStyle(fontSize: 12, color: Colors.white))))
                  .toList(),
              onChanged: (v) => state.setState(() => state.lookupRefMatchColumn = v),
            ),
            const SizedBox(height: 12),
          ],

          // ── MATCH MODE (range_lookup) ──
          _buildItemLabel("MATCH MODE (range_lookup)"),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _buildMatchModeOption(
                  label: "EXACT (FALSE)",
                  subLabel: "Recommended",
                  isSelected: state.lookupExactMatch,
                  onTap: () => state.setState(() => state.lookupExactMatch = true),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildMatchModeOption(
                  label: "APPROXIMATE (TRUE)",
                  subLabel: "Requires sorted data",
                  isSelected: !state.lookupExactMatch,
                  onTap: () => state.setState(() => state.lookupExactMatch = false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          if (!state.lookupShowAllColumns && state.lookupReferenceHeaders.isNotEmpty) ...[
            _buildIndexNumSelector(),
          ],
        ],
      ),
    );
  }

  Widget _buildRowValueDropdown() {
    if (state.isFetchingLookupSourceValues) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: TechColors.bgBlack, border: Border.all(color: TechColors.borderMuted)),
        child: const Text("Scanning column text entries...", style: TextStyle(color: TechColors.textMuted, fontSize: 11)),
      );
    }

    if (state.lookupSourceColumn == null) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: TechColors.bgBlack, border: Border.all(color: TechColors.borderMuted)),
        child: const Text("Choose a key column first", style: TextStyle(color: TechColors.textMuted, fontSize: 11)),
      );
    }

    if (state.lookupSourceColumnValues.isEmpty) {
      return Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(color: TechColors.bgBlack, border: Border.all(color: TechColors.borderMuted)),
        child: const Text("No rows discovered in this column", style: TextStyle(color: TechColors.statusAmber, fontSize: 11)),
      );
    }

    return _styledDropdown<String>(
      value: state.lookupSelectedSourceValue,
      hint: "Choose specific row item value...",
      items: state.lookupSourceColumnValues
          .map((val) => DropdownMenuItem(value: val, child: Text(val, style: const TextStyle(fontSize: 12, color: Colors.white), overflow: TextOverflow.ellipsis)))
          .toList(),
      onChanged: (v) => state.setState(() => state.lookupSelectedSourceValue = v),
    );
  }

  Widget _buildIndexNumSelector() {
    final bool isHlookup = state.selectedLookupType == "hlookup";
    final bool isXlookup = state.selectedLookupType == "xlookup";
    final String title = isHlookup ? "RETURN ROW (row_index_num)" : isXlookup ? "RETURN COLUMN (return_array)" : "RETURN COLUMN (col_index_num)";

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildItemLabel(title),
        const SizedBox(height: 6),
        if (isHlookup) ...[
          SizedBox(
            height: 38,
            child: TextField(
              controller: state.lookupRowIndexController,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: Colors.white, fontSize: 12),
              decoration: const InputDecoration(
                hintText: "e.g. 2",
                filled: true,
                fillColor: TechColors.bgBlack,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderMuted)),
                focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: TechColors.borderActive)),
              ),
            ),
          ),
        ] else ...[
          _styledDropdown<String>(
            value: state.lookupReturnColumnHeader,
            hint: "Select the column you want returned",
            items: state.lookupReferenceHeaders
                .map((h) => DropdownMenuItem(value: h, child: Text(h, style: const TextStyle(fontSize: 12, color: Colors.white))))
                .toList(),
            onChanged: (v) => state.setState(() => state.lookupReturnColumnHeader = v),
          ),
          const SizedBox(height: 6),
          if (state.resolvedLookupColIndexNum != null)
            Text(
              "→ resolved index position: ${state.resolvedLookupColIndexNum} (Column ${String.fromCharCode(64 + state.resolvedLookupColIndexNum!)})",
              style: const TextStyle(color: TechColors.borderActive, fontSize: 10, fontWeight: FontWeight.bold),
            ),
        ],
      ],
    );
  }

  Widget _buildMatchModeOption({required String label, required String subLabel, required bool isSelected, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
        decoration: BoxDecoration(
          color: isSelected ? TechColors.borderActive.withOpacity(0.12) : TechColors.bgBlack,
          border: Border.all(color: isSelected ? TechColors.borderActive : TechColors.borderMuted),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: isSelected ? TechColors.borderActive : TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(subLabel, style: const TextStyle(color: TechColors.textMuted, fontSize: 9)),
          ],
        ),
      ),
    );
  }

  Widget _buildRadioOption(String label, String value) {
    final isSelected = state.selectedLookupType == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => state.setState(() => state.selectedLookupType = value),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: isSelected ? TechColors.borderActive.withOpacity(0.12) : TechColors.bgBlack,
            border: Border.all(color: isSelected ? TechColors.borderActive : TechColors.borderMuted),
          ),
          child: Text(label, style: TextStyle(color: isSelected ? TechColors.borderActive : TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  Widget _buildItemLabel(String label) => Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.bold));

  Widget _styledDropdown<T>({required T? value, required String hint, required List<DropdownMenuItem<T>> items, required ValueChanged<T?> onChanged}) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(color: TechColors.bgBlack, border: Border.all(color: TechColors.borderMuted)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
            value: value,
            hint: Text(hint, style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
            dropdownColor: TechColors.panelBg,
            isExpanded: true,
            items: items,
            onChanged: onChanged
        ),
      ),
    );
  }
}