import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/core/auth/authenticated_http.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _CaptureClient extends http.BaseClient {
  http.BaseRequest? request;
  List<int>? body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request;
    body = await request.finalize().toBytes();
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode('{}')),
      200,
    );
  }
}

Session? _session() => Session.fromJson({
  'access_token': 'access-token',
  'refresh_token': 'refresh-token',
  'token_type': 'bearer',
  'expires_in': 3600,
  'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
  'user': {
    'id': 'user-1',
    'aud': 'authenticated',
    'role': 'authenticated',
    'email': 'user@example.com',
  },
});

void main() {
  test(
    'captures authenticated JSON request with authoritative context',
    () async {
      final client = _CaptureClient();
      await AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceProvider: () => 'workspace-1',
      ).postJson(
        Uri.parse('https://example.test/v1/resource'),
        resourceId: 'dataset-1',
        body: {'name': 'sample'},
      );

      expect(client.request!.headers['authorization'], 'Bearer access-token');
      expect(
        client.request!.headers['x-insightflow-workspace-id'],
        'workspace-1',
      );
      expect(client.request!.headers['x-insightflow-resource-id'], 'dataset-1');
      expect(jsonDecode(utf8.decode(client.body!)), {'name': 'sample'});
    },
  );

  test('fails closed when session restoration or refresh fails', () async {
    final client = _CaptureClient();
    expect(
      () =>
          AuthenticatedHttpTransport(
            client: client,
            sessionProvider: () async => null,
            workspaceProvider: () => 'workspace-1',
          ).postJson(
            Uri.parse('https://example.test/v1/resource'),
            resourceId: 'dataset-1',
          ),
      throwsA(isA<StateError>()),
    );
    expect(client.request, isNull);
  });

  test(
    'fails closed when workspace or canonical resource is missing',
    () async {
      final client = _CaptureClient();
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceProvider: () => null,
      );
      expect(
        () => transport.postJson(
          Uri.parse('https://example.test/v1/resource'),
          resourceId: 'dataset-1',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () =>
            AuthenticatedHttpTransport(
              client: client,
              sessionProvider: () async => _session(),
              workspaceProvider: () => 'workspace-1',
            ).postJson(
              Uri.parse('https://example.test/v1/resource'),
              resourceId: '',
            ),
        throwsA(isA<StateError>()),
      );
    },
  );

  test(
    'captures multipart request without changing canonical resource',
    () async {
      final client = _CaptureClient();
      await AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceProvider: () => 'workspace-1',
      ).postMultipart(
        Uri.parse('https://example.test/v1/upload'),
        resourceId: 'dataset:canonical/1',
        fields: {'kind': 'csv'},
        files: [
          http.MultipartFile.fromBytes('file', [1, 2, 3], filename: 'data.csv'),
        ],
      );

      expect(
        client.request!.headers['x-insightflow-resource-id'],
        'dataset:canonical/1',
      );
      expect(utf8.decode(client.body!), contains('name="kind"'));
      expect(utf8.decode(client.body!), contains('data.csv'));
    },
  );
}
