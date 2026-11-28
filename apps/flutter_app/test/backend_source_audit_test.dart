import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final libRoot = Directory('lib');

  test('maintained Flutter runtime has no Render API origin', () {
    final offenders = <String>[];
    for (final entity in libRoot.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('data-analysis-oajs.onrender.com') ||
          source.contains('.onrender.com')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });

  test('public API services compose paths from the shared backend origin', () {
    final expected = <String, List<String>>{
      'lib/core/services/chat_reasoning_service.dart': [
        'insightFlowBackendOrigin',
        '/v1/chat/plan',
      ],
      'lib/core/services/conversation_state_service.dart': [
        'insightFlowBackendOrigin',
        '/v1/conversation/',
      ],
      'lib/core/services/powerbi_detail_analysis_service.dart': [
        'insightFlowBackendOrigin',
        '/powerbi/detail-analysis',
      ],
    };

    for (final entry in expected.entries) {
      final source = File(entry.key).readAsStringSync();
      for (final marker in entry.value) {
        expect(source, contains(marker), reason: '${entry.key} missing $marker');
      }
    }
  });

  test('auth and upload contracts remain in place', () {
    final auth = File('lib/core/auth/authenticated_http.dart').readAsStringSync();
    final upload = File('lib/core/services/file_upload_handler_fixed.dart').readAsStringSync();
    expect(auth, contains("'Authorization': 'Bearer "));
    expect(auth, contains('/v1/authz/'));
    expect(upload, contains('FormData()'));
    expect(upload, contains('MultipartFile.fromFile'));
    expect(upload, contains('/upload'));
  });
}
