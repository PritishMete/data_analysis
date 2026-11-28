import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Oracle auth-context design documents canonical sources and decisions', () {
    final source = File('../../docs/ORACLE_AUTH_CONTEXT_DESIGN.md').readAsStringSync();

    for (final marker in const [
      'ensureSession()',
      '/v1/authz/me',
      'X-InsightFlow-Workspace-ID',
      'X-InsightFlow-Resource-ID',
      'dataset_authorization',
      'resource_grants',
      'dataset.upload',
      'Cross-workspace',
      'Product decisions required',
    ]) {
      expect(source, contains(marker), reason: 'missing contract marker: $marker');
    }
  });

  test('named services remain explicitly covered by the design contract', () {
    final source = File('../../docs/ORACLE_AUTH_CONTEXT_DESIGN.md').readAsStringSync();
    for (final service in const [
      'chat_reasoning_service.dart',
      'conversation_state_service.dart',
      'powerbi_detail_analysis_service.dart',
      'system_diagnostics_service.dart',
    ]) {
      expect(source, contains(service));
    }
  });
}
