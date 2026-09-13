import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/core/services/system_diagnostics_service.dart';

void main() {
  test('decodes healthy diagnostics response', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/system/diagnostics');
      expect(request.url.queryParameters['detail_analysis_build_id'], 'build123');
      return http.Response(
        jsonEncode({
          'success': true,
          'response_type': 'system_diagnostics',
          'overall_status': 'healthy',
          'frontend': {'status': 'healthy', 'detail_analysis_build_id': 'build123'},
        }),
        200,
      );
    });

    final service = SystemDiagnosticsService(client: client);
    final result = await service.check(servedBuildId: 'build123');
    expect(result['overall_status'], 'healthy');
    service.dispose();
  });

  test('backend failure becomes a clean diagnostics error', () async {
    final client = MockClient((_) async => http.Response('offline', 503));
    final service = SystemDiagnosticsService(client: client);
    await expectLater(service.check(), throwsException);
    service.dispose();
  });
}
