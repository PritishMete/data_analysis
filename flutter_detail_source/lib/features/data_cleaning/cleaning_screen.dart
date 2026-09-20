// lib/features/data_cleaning/cleaning_screen.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../core/services/data_cleaning_service.dart';
import '../dashboard/data_screen.dart';

class DataCleaningScreen extends StatefulWidget {
  final DataScreenState state;
  const DataCleaningScreen({super.key, required this.state});

  @override
  State<DataCleaningScreen> createState() => _DataCleaningScreenState();
}

class _DataCleaningScreenState extends State<DataCleaningScreen> {
  late CleaningConfig config;
  bool isProcessing = false;
  CleaningResult? lastResult;
  bool showAdvancedOptions = false;

  @override
  void initState() {
    super.initState();
    config = CleaningConfig();
  }

  Future<void> _performCleaning() async {
    if (widget.state.currentFileBytes == null) {
      _showAlert('No file loaded', 'Please upload a file first.');
      return;
    }

    setState(() => isProcessing = true);

    try {
      final result = await DataCleaningService.cleanData(
        fileBytes: widget.state.currentFileBytes!,
        fileName: widget.state.currentFileName ?? 'data.csv',
        config: config,
      );

      setState(() {
        lastResult = result;
        isProcessing = false;
      });

      if (result.success) {
        _showAlert('✅ Cleaning Complete', result.message);
      } else {
        _showAlert('❌ Cleaning Failed', result.error ?? result.message);
      }
    } catch (e) {
      setState(() => isProcessing = false);
      _showAlert('Error', e.toString());
    }
  }

  Future<void> _writeToSheet() async {
    if (lastResult == null || !lastResult!.success) {
      _showAlert('No cleaned data', 'Please clean your data first.');
      return;
    }

    setState(() => isProcessing = true);

    try {
      final result = await DataCleaningService.writeCleanedDataToSheet(lastResult!);

      setState(() => isProcessing = false);

      if (result['success'] == true) {
        final message = await DataCleaningService.executeCleaningWorkflow(
          fileBytes: widget.state.currentFileBytes!,
          fileName: widget.state.currentFileName ?? 'data.csv',
          config: config,
        );
        _showAlert('Success', message);
      } else {
        _showAlert('Write Failed', result['error'] ?? 'Unknown error');
      }
    } catch (e) {
      setState(() => isProcessing = false);
      _showAlert('Error', e.toString());
    }
  }

  void _showAlert(String title, String message) {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _SectionHeader('Data Cleaning'),
        const SizedBox(height: 12),

        // Main cleaning options
        _buildBasicOptionsCard(),
        const SizedBox(height: 16),

        // Advanced options
        _buildAdvancedToggle(),
        if (showAdvancedOptions) ...[
          const SizedBox(height: 12),
          _buildAdvancedOptionsCard(),
        ],
        const SizedBox(height: 20),

        // Action buttons
        _buildActionButtons(),
        const SizedBox(height: 20),

        // Results display
        if (lastResult != null) ...[
          _buildResultsDisplay(),
        ],
      ],
    );
  }

  Widget _buildBasicOptionsCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        children: [
          _buildToggleTile(
            'Standardize Column Names',
            'Convert to lowercase, remove special characters',
            config.standardizeCols,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: v,
              removeDuplicates: config.removeDuplicates,
              removeEmptyRows: config.removeEmptyRows,
              handleMissingValues: config.handleMissingValues,
              nullStrategy: config.nullStrategy,
              normalizeText: config.normalizeText,
              inferTypes: config.inferTypes,
              handleOutliers: config.handleOutliers,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: false,
          ),
          _buildToggleTile(
            'Remove Duplicates',
            'Delete rows that are completely identical',
            config.removeDuplicates,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: config.standardizeCols,
              removeDuplicates: v,
              removeEmptyRows: config.removeEmptyRows,
              handleMissingValues: config.handleMissingValues,
              nullStrategy: config.nullStrategy,
              normalizeText: config.normalizeText,
              inferTypes: config.inferTypes,
              handleOutliers: config.handleOutliers,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: false,
          ),
          _buildToggleTile(
            'Remove Empty Rows',
            'Delete rows with all null/missing values',
            config.removeEmptyRows,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: config.standardizeCols,
              removeDuplicates: config.removeDuplicates,
              removeEmptyRows: v,
              handleMissingValues: config.handleMissingValues,
              nullStrategy: config.nullStrategy,
              normalizeText: config.normalizeText,
              inferTypes: config.inferTypes,
              handleOutliers: config.handleOutliers,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: false,
          ),
          _buildToggleTile(
            'Handle Missing Values',
            'Fill null/empty cells using intelligent strategies',
            config.handleMissingValues,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: config.standardizeCols,
              removeDuplicates: config.removeDuplicates,
              removeEmptyRows: config.removeEmptyRows,
              handleMissingValues: v,
              nullStrategy: config.nullStrategy,
              normalizeText: config.normalizeText,
              inferTypes: config.inferTypes,
              handleOutliers: config.handleOutliers,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: false,
          ),
          if (config.handleMissingValues)
            _buildNullStrategySelector(),
          _buildToggleTile(
            'Normalize Text',
            'Strip whitespace, fix Unicode issues',
            config.normalizeText,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: config.standardizeCols,
              removeDuplicates: config.removeDuplicates,
              removeEmptyRows: config.removeEmptyRows,
              handleMissingValues: config.handleMissingValues,
              nullStrategy: config.nullStrategy,
              normalizeText: v,
              inferTypes: config.inferTypes,
              handleOutliers: config.handleOutliers,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: true,
          ),
        ],
      ),
    );
  }

  Widget _buildNullStrategySelector() {
    final strategies = ['smart', 'mean', 'median', 'mode', 'forward_fill', 'drop'];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Missing Value Strategy',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            DataCleaningService.describeNullStrategy(config.nullStrategy),
            style: TextStyle(
              fontSize: 11,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: strategies.map((strategy) {
              final isSelected = config.nullStrategy == strategy;
              return GestureDetector(
                onTap: () => setState(() => config = CleaningConfig(
                  standardizeCols: config.standardizeCols,
                  removeDuplicates: config.removeDuplicates,
                  removeEmptyRows: config.removeEmptyRows,
                  handleMissingValues: config.handleMissingValues,
                  nullStrategy: strategy,
                  normalizeText: config.normalizeText,
                  inferTypes: config.inferTypes,
                  handleOutliers: config.handleOutliers,
                  outlierMethod: config.outlierMethod,
                  outputSheetName: config.outputSheetName,
                )),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? CupertinoColors.activeBlue
                        : CupertinoColors.systemGrey5,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    strategy,
                    style: TextStyle(
                      fontSize: 12,
                      color: isSelected ? CupertinoColors.white : CupertinoColors.label.resolveFrom(context),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedToggle() {
    return GestureDetector(
      onTap: () => setState(() => showAdvancedOptions = !showAdvancedOptions),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            Icon(
              showAdvancedOptions
                  ? CupertinoIcons.chevron_down
                  : CupertinoIcons.chevron_right,
              size: 18,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(width: 8),
            Text(
              'Advanced Options',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdvancedOptionsCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        children: [
          _buildToggleTile(
            'Infer Column Types',
            'Auto-detect numeric, datetime, categorical columns',
            config.inferTypes,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: config.standardizeCols,
              removeDuplicates: config.removeDuplicates,
              removeEmptyRows: config.removeEmptyRows,
              handleMissingValues: config.handleMissingValues,
              nullStrategy: config.nullStrategy,
              normalizeText: config.normalizeText,
              inferTypes: v,
              handleOutliers: config.handleOutliers,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: false,
          ),
          _buildToggleTile(
            'Handle Outliers',
            'Detect and manage extreme values in numeric columns',
            config.handleOutliers,
                (v) => setState(() => config = CleaningConfig(
              standardizeCols: config.standardizeCols,
              removeDuplicates: config.removeDuplicates,
              removeEmptyRows: config.removeEmptyRows,
              handleMissingValues: config.handleMissingValues,
              nullStrategy: config.nullStrategy,
              normalizeText: config.normalizeText,
              inferTypes: config.inferTypes,
              handleOutliers: v,
              outlierMethod: config.outlierMethod,
              outputSheetName: config.outputSheetName,
            )),
            isLast: !config.handleOutliers,
          ),
          if (config.handleOutliers)
            _buildOutlierMethodSelector(),
        ],
      ),
    );
  }

  Widget _buildOutlierMethodSelector() {
    final methods = ['cap', 'remove', 'mark'];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Outlier Handling Method',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            DataCleaningService.describeOutlierMethod(config.outlierMethod),
            style: TextStyle(
              fontSize: 11,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: methods.map((method) {
              final isSelected = config.outlierMethod == method;
              return GestureDetector(
                onTap: () => setState(() => config = CleaningConfig(
                  standardizeCols: config.standardizeCols,
                  removeDuplicates: config.removeDuplicates,
                  removeEmptyRows: config.removeEmptyRows,
                  handleMissingValues: config.handleMissingValues,
                  nullStrategy: config.nullStrategy,
                  normalizeText: config.normalizeText,
                  inferTypes: config.inferTypes,
                  handleOutliers: config.handleOutliers,
                  outlierMethod: method,
                  outputSheetName: config.outputSheetName,
                )),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? CupertinoColors.activeBlue
                        : CupertinoColors.systemGrey5,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    method,
                    style: TextStyle(
                      fontSize: 12,
                      color: isSelected ? CupertinoColors.white : CupertinoColors.label.resolveFrom(context),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleTile(
      String title,
      String subtitle,
      bool value,
      ValueChanged<bool> onChanged,
      {required bool isLast}
      ) {
    return GlassListTile(
      leading: Icon(
        value ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
        color: value ? CupertinoColors.activeBlue : CupertinoColors.inactiveGray,
      ),
      title: Text(title),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: GlassSwitch(
        value: value,
        onChanged: onChanged,
      ),
      isLast: isLast,
    );
  }

  Widget _buildActionButtons() {
    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          child: CupertinoButton.filled(
            onPressed: isProcessing ? null : _performCleaning,
            child: isProcessing
                ? const CupertinoActivityIndicator()
                : const Text('🧹 Clean Data'),
          ),
        ),
        if (lastResult?.success == true) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              onPressed: isProcessing ? null : _writeToSheet,
              child: const Text('💾 Write to Excel Sheet'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildResultsDisplay() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('Cleaning Results'),
        const SizedBox(height: 12),

        if (lastResult!.success)
          _buildSuccessResults()
        else
          _buildErrorResults(),
      ],
    );
  }

  Widget _buildSuccessResults() {
    final comparison = lastResult!.comparison;
    final report = lastResult!.cleaningReport;

    return Column(
      children: [
        GlassCard(
          padding: const EdgeInsets.all(16),
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '📊 Before vs After',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 12),
              _buildComparisonRow('Rows', lastResult!.before['rows'], lastResult!.after['rows']),
              _buildComparisonRow('Columns', lastResult!.before['columns'], lastResult!.after['columns']),
              _buildComparisonRow('Missing Values', comparison['total_missing_before'], comparison['total_missing_after']),
              _buildComparisonRow('Duplicates', comparison['total_duplicates_before'], comparison['total_duplicates_after']),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.all(16),
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '✅ Summary',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                lastResult!.message,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildComparisonRow(String label, dynamic before, dynamic after) {
    final change = after - before;
    final changeStr = change > 0 ? '+$change' : '$change';
    final changeColor = change < 0 ? CupertinoColors.systemGreen : CupertinoColors.systemRed;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    '$before',
                    style: TextStyle(
                      fontSize: 12,
                      color: CupertinoColors.secondaryLabel.resolveFrom(context),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Icon(
                    change < 0 ? CupertinoIcons.arrow_down : CupertinoIcons.arrow_up,
                    size: 14,
                    color: changeColor,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    changeStr,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: changeColor,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Text(
            '$after',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorResults() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '❌ Cleaning Failed',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.systemRed,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            lastResult!.error ?? lastResult!.message,
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
