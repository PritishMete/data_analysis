import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Privacy-safe diagnostics. Callers must not pass tokens, headers, URLs,
/// OAuth values, response bodies, or personal data.
class AuthDiagnostics {
  AuthDiagnostics._();

  static final Random _random = Random.secure();

  static String newCorrelationId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return 'auth-${bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join()}';
  }

  static void event(
    String operation, {
    required String correlationId,
    required bool success,
    int? status,
    String? exceptionClass,
    String? category,
    int? durationMs,
  }) {
    final fields = <String, Object?>{
      'correlation_id': correlationId,
      'operation': operation,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'success': success,
      if (status case final value?) 'status': value,
      if (exceptionClass case final value?) 'exception_class': value,
      if (category case final value?) 'category': value,
      if (durationMs case final value?) 'duration_ms': value,
    };
    debugPrint('[auth-diagnostic] ${jsonEncode(fields)}');
  }
}
