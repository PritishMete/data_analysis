import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Best-effort, privacy-filtered diagnostics delivery. Failures here never
/// interrupt sign-in, data access, or a user's requested operation.
class InsightFlowDiagnosticTelemetry {
  InsightFlowDiagnosticTelemetry._();

  static const String _apiOrigin = String.fromEnvironment(
    'INSIGHTFLOW_DIAGNOSTICS_API_ORIGIN',
    defaultValue: 'https://data-analysis-oajs.onrender.com',
  );
  static final http.Client _client = http.Client();
  static final List<Map<String, dynamic>> _pending = [];
  static String? _sessionId;
  static String? _claimSecret;
  static bool _claimed = false;
  static String? _claimedSubject;
  static bool _creatingSession = false;
  static DateTime? _expiresAt;
  static Future<void> _serial = Future<void>.value();
  static String? _correlationId;

  static String correlationId(String prefix) {
    final value = '$prefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
    _correlationId = value;
    return value;
  }

  static void record({
    required String category,
    required String status,
    required String stage,
    required String component,
    String? operation,
    String? code,
    String? correlation,
    Map<String, Object?> metadata = const {},
  }) {
    // Only fixed labels, status codes and explicitly allowlisted metadata
    // should be passed here. Never pass response bodies, tokens, user content,
    // workbook data, cookies, or request headers.
    final event = <String, dynamic>{
      'category': category,
      'status': status,
      'correlation_id': correlation ?? correlationId('diag'),
      'payload': <String, Object?>{
        'stage': stage,
        'component': component,
        if (operation != null) 'operation': operation,
        if (code != null) 'code': code,
        if (metadata.isNotEmpty) 'metadata': metadata,
      },
      'sanitized_error': code,
    };
    if (_pending.length >= 100) _pending.removeAt(0);
    _pending.add(event);
    _enqueue(_flush);
  }

  static void _enqueue(Future<void> Function() task) {
    _serial = _serial.then((_) => task()).catchError((_) {});
  }

  static Future<void> _ensureSession() async {
    if (_sessionId != null &&
        _expiresAt != null &&
        DateTime.now().isBefore(_expiresAt!.subtract(const Duration(seconds: 20)))) {
      return;
    }
    if (_creatingSession) return;
    _sessionId = null;
    _claimSecret = null;
    _claimed = false;
    _expiresAt = null;
    _creatingSession = true;
    try {
      final response = await _client
          .post(Uri.parse('$_apiOrigin/v1/diagnostics/sessions'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode < 200 || response.statusCode >= 300) return;
      final decoded = jsonDecode(response.body);
      if (decoded is Map) {
        _sessionId = decoded['support_reference']?.toString();
        _claimSecret = decoded['claim_secret']?.toString();
        _expiresAt = DateTime.tryParse(decoded['expires_at']?.toString() ?? '');
      }
    } catch (_) {
      // Telemetry is best-effort only.
    } finally {
      _creatingSession = false;
    }
  }

  static Future<void> _tryClaim() async {
    if (_claimed || _sessionId == null || _claimSecret == null) return;
    if (!Supabase.instance.isInitialized) return;
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    if (token == null || token.isEmpty) return;
    try {
      final response = await _client
          .post(
            Uri.parse('$_apiOrigin/v1/diagnostics/sessions/claim'),
            headers: {
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'session_id': _sessionId,
              'claim_secret': _claimSecret,
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode >= 200 && response.statusCode < 300) {
        _claimed = true;
        _claimedSubject = Supabase.instance.client.auth.currentUser?.id;
        _claimSecret = null;
      }
    } catch (_) {
      // Retry on the next event.
    }
  }

  static Future<void> _flush() async {
    final currentSubject = Supabase.instance.isInitialized
        ? Supabase.instance.client.auth.currentUser?.id
        : null;
    if (_claimedSubject != null &&
        currentSubject != null &&
        currentSubject != _claimedSubject) {
      // Never attach one customer's queued events to another account on a
      // shared device. Drop the old in-memory batch and start a fresh session.
      _pending.clear();
      _sessionId = null;
      _claimSecret = null;
      _claimed = false;
      _claimedSubject = null;
      _expiresAt = null;
    }
    await _ensureSession();
    if (_sessionId == null) return;
    await _tryClaim();

    while (_pending.isNotEmpty) {
      final event = _pending.first;
      final token = _claimed && Supabase.instance.isInitialized
          ? Supabase.instance.client.auth.currentSession?.accessToken
          : null;
      final authenticated = token != null && token.isNotEmpty;
      if (_claimed && !authenticated) return;
      final uri = Uri.parse('$_apiOrigin/v1/diagnostics/events');
      final body = <String, dynamic>{
        'session_id': _sessionId,
        'correlation_id': event['correlation_id'],
        'category': event['category'],
        'status': event['status'],
        'sanitized_error': event['sanitized_error'],
        'payload': event['payload'],
        if (!authenticated) 'claim_secret': _claimSecret,
      };
      try {
        final response = await _client
            .post(
              uri,
              headers: {
                'Content-Type': 'application/json',
                if (authenticated) 'Authorization': 'Bearer $token',
              },
              body: jsonEncode(body),
            )
            .timeout(const Duration(seconds: 8));
        if (response.statusCode == 429 || response.statusCode >= 500) return;
        if (response.statusCode < 200 || response.statusCode >= 300) {
          // Keep events queued if the anonymous claim has already been
          // consumed; a subsequent auth event may allow the authenticated path.
          if (response.statusCode == 403 && !_claimed) {
            await _tryClaim();
            if (_claimed) continue;
          }
          return;
        }
        _pending.removeAt(0);
      } catch (_) {
        return;
      }
    }
  }
}
