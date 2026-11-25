import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Development-only, in-memory diagnostics for one Excel authentication run.
///
/// The allowlist is intentional: no tokens, state/nonce values, credentials,
/// cookies, headers, user data, or workbook data may enter this buffer.
class ExcelAuthDiagnostics {
  ExcelAuthDiagnostics._();

  static const enabled = bool.fromEnvironment(
    'INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS',
    defaultValue: false,
  );
  static final List<Map<String, Object?>> _events = <Map<String, Object?>>[];
  static bool _testEnabled = false;
  static String? _correlationId;

  static String? get correlationId => _correlationId;
  static bool get isEnabled => enabled || _testEnabled;

  static void start(String correlationId) {
    if (!isEnabled) return;
    try {
      _events.clear();
      _correlationId = correlationId;
      record('attempt_started');
    } catch (_) {
      // Diagnostics must never affect authentication.
    }
  }

  static void record(
    String event, {
    String? operation,
    String? result,
    String? authEvent,
    String? errorCode,
    bool? sessionAvailable,
    bool? completed,
    bool? handoffStarted,
  }) {
    if (!isEnabled) return;
    try {
      final fields = <String, Object?>{
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'correlation_id': _correlationId,
      'event': event,
      if (operation != null) 'operation': operation,
      if (result != null) 'result': result,
      if (authEvent != null) 'auth_event': authEvent,
      if (errorCode != null) 'error_code': errorCode,
      if (sessionAvailable != null) 'session_available': sessionAvailable,
      if (completed != null) 'completed': completed,
      if (handoffStarted != null) 'handoff_started': handoffStarted,
    };
      _events.add(fields);
      if (_events.length > 200) _events.removeAt(0);
      // Keep the existing searchable prefix for WebView2 console collection.
      debugPrint('[excel-auth-diagnostic] ${jsonEncode(fields)}');
    } catch (_) {
      // Diagnostics must never affect authentication.
    }
  }

  static String exportJson() => isEnabled ? jsonEncode(_events) : '[]';

  static Future<bool> copyDiagnosticsToClipboard() async {
    if (!isEnabled) return false;
    await Clipboard.setData(ClipboardData(text: exportJson()));
    return true;
  }

  static void resetForTest() {
    _events.clear();
    _correlationId = null;
  }

  static void enableForTest() => _testEnabled = true;
}
