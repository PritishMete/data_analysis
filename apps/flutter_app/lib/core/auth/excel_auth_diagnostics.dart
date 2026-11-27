import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interop/excel_auth_bridge.dart';
import '../services/diagnostic_telemetry_service.dart';

/// Privacy-filtered Excel authentication diagnostics with optional local inspection.
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
  static bool _sessionActive = false;
  static String? _correlationId;
  static final Set<String> _uploadedBridgeEvents = <String>{};

  static String? get correlationId => _correlationId;
  static bool get isEnabled => (enabled && _sessionActive) || _testEnabled;
  // Bridge events are collected in every customer build; the local overlay
  // remains separately controlled by the developer-only flag.
  static bool get buildSupported => true;

  static void activateSession(bool active) {
    _sessionActive = active;
  }

  static void start(String correlationId) {
    try {
      _correlationId = correlationId;
      for (final event in _events) {
        event['correlation_id'] ??= correlationId;
      }
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
      _flushBridgeEvents();
      InsightFlowDiagnosticTelemetry.record(
        category: 'excel_google_auth',
        status: errorCode != null
            ? 'failed'
            : (completed == true || result == 'validated' ? 'success' : 'info'),
        stage: event,
        component: 'excel_auth',
        operation: operation,
        code: errorCode,
        correlation: _correlationId,
        metadata: <String, Object?>{
          if (authEvent != null) 'auth_event': authEvent,
          if (sessionAvailable != null) 'session_available': sessionAvailable,
          if (completed != null) 'completed': completed,
          if (handoffStarted != null) 'handoff_started': handoffStarted,
        },
      );
      if (!isEnabled) return;
      _events.add(fields);
      if (_events.length > 200) _events.removeAt(0);
      // Keep the existing searchable prefix for WebView2 console collection.
      debugPrint('[excel-auth-diagnostic] ${jsonEncode(fields)}');
    } catch (_) {
      // Diagnostics must never affect authentication.
    }
  }

  static void _flushBridgeEvents() {
    try {
      final decoded = jsonDecode(ExcelAuthBridge.bridgeDiagnosticsJson());
      if (decoded is! List) return;
      for (final raw in decoded.whereType<Map>()) {
        final event = Map<String, dynamic>.from(raw);
        final name = event['event']?.toString() ?? 'bridge_event';
        final timestamp = event['timestamp']?.toString() ?? '';
        final fingerprint = '$timestamp|$name';
        if (!_uploadedBridgeEvents.add(fingerprint)) continue;
        final code = event['error_code']?.toString();
        final result = event['result']?.toString();
        InsightFlowDiagnosticTelemetry.record(
          category: 'excel_google_auth',
          status: code != null
              ? 'failed'
              : (result == 'failed' ? 'failed' : (result == 'validated' ? 'success' : 'info')),
          stage: name,
          component: 'excel_auth_popup',
          operation: event['operation']?.toString(),
          code: code,
          correlation: event['correlation_id']?.toString() ?? _correlationId,
        );
      }
    } catch (_) {
      // Bridge diagnostics are optional and never affect authentication.
    }
  }

  static String exportJson() {
    if (!isEnabled) return '[]';
    try {
      final local = List<Map<String, Object?>>.from(_events);
      final bridge =
          (jsonDecode(ExcelAuthBridge.bridgeDiagnosticsJson()) as List)
              .whereType<Map>()
              .map((event) => Map<String, Object?>.from(event))
              .toList();
      final all = <Map<String, Object?>>[...local, ...bridge]
        ..sort(
          (a, b) =>
              (a['timestamp'] as String).compareTo(b['timestamp'] as String),
        );
      return jsonEncode(all.length > 300 ? all.sublist(all.length - 300) : all);
    } catch (_) {
      return jsonEncode(_events);
    }
  }

  static Future<bool> copyDiagnosticsToClipboard() async {
    if (!isEnabled) return false;
    await Clipboard.setData(ClipboardData(text: exportJson()));
    return true;
  }

  static void resetForTest() {
    _events.clear();
    _correlationId = null;
    _uploadedBridgeEvents.clear();
    _sessionActive = false;
    ExcelAuthBridge.resetDiagnostics();
  }

  static void enableForTest() => _testEnabled = true;
}

class ExcelDiagnosticsOverlay extends StatefulWidget {
  const ExcelDiagnosticsOverlay({super.key, required this.child});
  final Widget child;
  @override
  State<ExcelDiagnosticsOverlay> createState() =>
      _ExcelDiagnosticsOverlayState();
}

class _ExcelDiagnosticsOverlayState extends State<ExcelDiagnosticsOverlay> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ExcelAuthDiagnostics.isEnabled) return widget.child;
    return Stack(
      children: [
        widget.child,
        Positioned(
          right: 12,
          bottom: 12,
          child: Material(
            color: Colors.black87,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: () {
                    ExcelAuthDiagnostics.copyDiagnosticsToClipboard();
                  },
                  child: const Text('Copy diagnostics'),
                ),
                TextButton(
                  onPressed: () {
                    ExcelAuthDiagnostics.resetForTest();
                    setState(() {});
                  },
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
