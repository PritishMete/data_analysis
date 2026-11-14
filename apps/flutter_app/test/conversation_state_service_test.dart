import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/core/services/conversation_state_service.dart';

void main() {
  test('meta questions use local assistant endpoint without dataset state', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'success': true,
          'handled': true,
          'response_type': 'assistant_meta',
          'intent': 'creator',
          'summary': 'InsightFlow was created by Pritish Mete.',
        }),
        200,
      );
    });
    final service = ConversationStateService(client: client);

    final result = await service.meta('Who made you?');

    expect(captured.url.path, '/v1/assistant/meta');
    expect(captured.bodyFields['surface'], 'detail_analysis');
    expect(captured.bodyFields['text'], 'Who made you?');
    expect(result['handled'], isTrue);
    expect(result['summary'], contains('Pritish Mete'));
  });

  test('suggestions call local structured endpoint', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response(
        jsonEncode({
          'success': true,
          'response_type': 'suggested_next_questions',
          'suggestions': [
            {
              'id': 'region-year',
              'label': 'How did North perform in 2025?',
              'query': 'How did North perform in 2025?',
            }
          ],
        }),
        200,
      );
    });
    final service = ConversationStateService(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:8000'),
    );

    final result = await service.suggestions(
      sessionId: 'session-1',
      context: const {'selected_entity': 'North'},
    );

    expect(captured.url.path, '/v1/conversation/suggestions');
    final body = jsonDecode(captured.body) as Map<String, dynamic>;
    expect(body['session_id'], 'session-1');
    expect((body['context'] as Map)['selected_entity'], 'North');
    expect((result['suggestions'] as List).single['query'], contains('North'));
  });

  test('summary uses encoded session id and preserves structured response', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/conversation/summary/session%20one');
      return http.Response(
        jsonEncode({
          'success': true,
          'response_type': 'session_summary',
          'current_scope': 'North',
          'active_filters': {'year': 2025},
        }),
        200,
      );
    });
    final service = ConversationStateService(
      client: client,
      baseUri: Uri.parse('http://127.0.0.1:8000'),
    );

    final result = await service.summary('session one');
    expect(result['current_scope'], 'North');
    expect((result['active_filters'] as Map)['year'], 2025);
  });

  test('failed state request throws readable FormatException', () async {
    final client = MockClient((request) async => http.Response(
          jsonEncode({'success': false, 'error': 'state unavailable'}),
          500,
        ));
    final service = ConversationStateService(client: client);

    expect(
      () => service.state('broken'),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'state unavailable',
        ),
      ),
    );
  });

  test('snapshot and restore call recovery endpoints', () async {
    final seen = <String>[];
    final client = MockClient((request) async {
      seen.add(request.url.path);
      if (request.url.path.endsWith('/snapshot')) {
        return http.Response(
          jsonEncode({
            'success': true,
            'snapshot': {'current_scope': 'North'},
          }),
          200,
        );
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      expect((body['snapshot'] as Map)['current_scope'], 'North');
      return http.Response(
        jsonEncode({
          'success': true,
          'state': {'current_scope': 'North'},
        }),
        200,
      );
    });
    final service = ConversationStateService(client: client);

    final snapshot = await service.snapshot('s1');
    await service.restore(
      sessionId: 's1',
      snapshot: Map<String, dynamic>.from(snapshot['snapshot'] as Map),
    );

    expect(
      seen,
      containsAll([
        '/v1/conversation/transaction/s1/snapshot',
        '/v1/conversation/transaction/s1/restore',
      ]),
    );
  });
}
