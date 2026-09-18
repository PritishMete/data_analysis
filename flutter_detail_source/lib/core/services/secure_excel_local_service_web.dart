import 'dart:convert';
import 'dart:js_interop';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../../core/interop/excel_interop_web.dart';
import '../../widgets/overlays/synthetic_data_confirmation_dialog.dart';

@JS('executeSecureExcelQuery')
external JSPromise<JSString> _executeSecureExcelQuery(JSString optionsJson);

@JS('executeSyntheticData')
external JSPromise<JSString> _executeSyntheticData(JSString optionsJson);

/// Secure Excel operations that execute entirely in the Office taskpane.
/// No worksheet rows are sent to the Python backend or any remote service.
class SecureExcelLocalService {
  static const String baseUrl = 'office-local';

  static bool supportsQuery(String text) {
    final lower = text.trim().toLowerCase();
    final hasCheckVerb = RegExp(r'\b(?:check|inspect|find|show|report|identify)\b').hasMatch(lower);
    final hasMissing = RegExp(r'\b(?:missing|null|blank|empty)\b').hasMatch(lower);
    final hasDuplicate = RegExp(r'\b(?:duplicate|duplicates|duplicated)\b').hasMatch(lower);
    final hasIdentifierReference = RegExp(r'\b(?:restaurant\s*ids?|restaurant[_ ]?identifier|duplicates?\s+[a-z0-9_]+\s+(?:values?|ids?))\b').hasMatch(lower);
    if (hasCheckVerb && (hasMissing || hasDuplicate) && (hasMissing || hasIdentifierReference)) return true;
    final hasCount = RegExp(r'\b(?:count|how many|number of)\b').hasMatch(lower);
    final hasGrouping = RegExp(r'\b(?:each|per|by|group(?:ed)?\s+by)\b').hasMatch(lower);
    if (hasCount && hasGrouping) return true;

    // Explicit synthetic/hypothetical worksheet requests are local write
    // operations, not analytical queries. Keep them on the taskpane before
    // the generic aggregation/remote rejection path.
    final hasCreateVerb = RegExp(r'\b(?:create|add|generate|make|fill|populate)\b').hasMatch(lower);
    final hasSyntheticIntent = RegExp(r'\b(?:hypothetical|hypothesis|synthetic|simulated|simulation|fake|sample)\b').hasMatch(lower) || RegExp(r'\bjust\s+fill\b').hasMatch(lower);
    final hasColumnOrNumericTarget = RegExp(r'\b(?:column|field|numbers?|numeric|values?|amounts?)\b').hasMatch(lower);
    final hasSyntheticDomain = RegExp(r'\b(?:revenue|sales?|amount|price|quantity|score|rating)\b').hasMatch(lower);
    if (hasCreateVerb && hasSyntheticIntent && (hasColumnOrNumericTarget || hasSyntheticDomain)) return true;

    // Generic grouped analytics are handled by the same taskpane-local JS
    // engine. No data-dependent or restaurant-specific wording is required.
    final hasAggregation = RegExp(r'\b(?:average|avg|mean|sum|total|count|minimum|min|maximum|max|highest|lowest|top|bottom)\b').hasMatch(lower);
    final hasAnalyticGrouping = RegExp(r'\b(?:by|per|each|group(?:ed)?\s+by|which|what)\b').hasMatch(lower);
    return hasAggregation && hasAnalyticGrouping;
  }

  static Future<Map<String, dynamic>> execute({
    required List<List<dynamic>> sourceRows,
    required String query,
  }) async {
    if (!kIsWeb) return {'success': false, 'route': 'operation', 'error': 'Secure Excel worksheet operations require the Office web host.'};
    if (sourceRows.length < 2 || sourceRows.first.isEmpty) return {'success': false, 'route': 'operation', 'error': 'Dataset is empty or has no header row.'};
    try {
      final lower = query.trim().toLowerCase();
      final synthetic = RegExp(r'\b(?:create|add|generate|make|fill|populate)\b').hasMatch(lower) &&
          (RegExp(r'\b(?:hypothetical|hypothesis|synthetic|simulated|simulation|fake|sample)\b').hasMatch(lower) || RegExp(r'\bjust\s+fill\b').hasMatch(lower)) &&
          RegExp(r'\b(?:column|field|numbers?|numeric|values?|amounts?|revenue|sales?|amount|price|quantity|score|rating)\b').hasMatch(lower);
      if (synthetic) return _executeSyntheticWithConfirmation(sourceRows: sourceRows, query: query);
      final response = await _executeSecureExcelQuery(jsonEncode({'rows': sourceRows, 'query': query}).toJS).toDart;
      final decoded = jsonDecode(response.toDart);
      return decoded is Map<String, dynamic> ? decoded : {'success': false, 'route': 'operation', 'error': 'Local Excel engine returned an unexpected response.'};
    } catch (error) {
      return {'success': false, 'route': 'operation', 'error': 'Local Excel operation failed: $error'};
    }
  }

  static Future<Map<String, dynamic>> _executeSyntheticWithConfirmation({
    required List<List<dynamic>> sourceRows,
    required String query,
  }) async {
    final sourceSheet = await getActiveWorksheetName();
    final normalized = query.toLowerCase();
    final revenue = RegExp(r'\brevenue\b|\bsales?\s+(?:amount|revenue)\b').hasMatch(normalized);
    final proposed = revenue ? 'Revenue' : (RegExp(r'\bsales?\b').hasMatch(normalized) ? 'Sales Amount' : 'Synthetic Value');
    final result = await SyntheticDataConfirmationDialog.show(
      context: _currentContext(),
      sourceWorksheet: sourceSheet ?? 'Active worksheet',
      proposedColumn: proposed,
      defaultMin: 0,
      defaultMax: revenue ? 100000 : 100,
      defaultFormat: SyntheticNumberFormat.decimal,
      proposedOutputWorksheet: revenue ? 'Hypothetical_Revenue' : 'Synthetic_Data',
      existingColumn: sourceRows.first.any((v) => v?.toString().trim().toLowerCase() == proposed.toLowerCase()),
    );
    if (result == null) return {'success': false, 'route': 'operation', 'error': 'Synthetic data generation was cancelled before writing.', 'local_secure': true, 'source_mutated': false, 'cancelled': true};
    final response = await _executeSyntheticData(jsonEncode({
      'rows': sourceRows, 'query': query, 'sourceSheetName': sourceSheet,
      'columnName': result.columnName, 'min': result.min, 'max': result.max,
      'format': result.format == SyntheticNumberFormat.integer ? 'integer' : 'decimal',
      'seed': result.seed, 'outputSheetName': result.outputWorksheet, 'revenue': revenue,
    }).toJS).toDart;
    final decoded = jsonDecode(response.toDart);
    return decoded is Map<String, dynamic> ? decoded : {'success': false, 'route': 'operation', 'error': 'Synthetic Excel engine returned an unexpected response.'};
  }

  static BuildContext Function() _currentContext = () => throw StateError('SecureExcelLocalService dialog context has not been registered.');
  static void registerDialogContext(BuildContext Function() contextProvider) => _currentContext = contextProvider;
}
