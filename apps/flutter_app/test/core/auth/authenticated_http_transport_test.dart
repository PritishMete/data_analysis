import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/core/auth/authenticated_http.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef _ResponseFactory =
    http.Response Function(http.BaseRequest request, List<int> body);

class _RecordedRequest {
  const _RecordedRequest(this.request, this.body);

  final http.BaseRequest request;
  final List<int> body;
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this._responseFactory);

  final _ResponseFactory _responseFactory;
  final requests = <_RecordedRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    requests.add(_RecordedRequest(request, body));
    final response = _responseFactory(request, body);
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(response.body)),
      response.statusCode,
      headers: response.headers,
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

Map<String, dynamic> _activeWorkspaceResponse(String workspaceId) => {
  'membership_status': 'active',
  'workspace_authorized': true,
  'workspace_id': workspaceId,
  'workspaces': [
    {'workspace_id': workspaceId, 'membership_status': 'active'},
  ],
};

CanonicalResource _resource(String workspaceId) =>
    CanonicalResource.fromServerJson({
      'resource_id': 'resource-1',
      'workspace_id': workspaceId,
      'status': 'active',
    })!;

String? _header(http.BaseRequest request, String name) {
  final entry = request.headers.entries
      .cast<MapEntry<String, String>?>()
      .firstWhere(
        (entry) => entry!.key.toLowerCase() == name.toLowerCase(),
        orElse: () => null,
      );
  return entry?.value;
}

void main() {
  test('missing session prevents every network request', () async {
    final client = _RecordingClient((request, body) {
      throw StateError('unexpected network request');
    });
    final transport = AuthenticatedHttpTransport(
      client: client,
      sessionProvider: () async => null,
      workspaceHintProvider: () => null,
    );

    await expectLater(
      transport.getJson(
        Uri.parse('https://example.test/v1/protected'),
        resource: _resource('workspace-1'),
      ),
      throwsA(isA<AuthenticatedTransportException>()),
    );

    expect(client.requests, isEmpty);
  });

  test(
    'session restoration or refresh failure prevents every network request',
    () async {
      final client = _RecordingClient((request, body) {
        throw StateError('unexpected network request');
      });
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => throw StateError('refresh failed'),
        workspaceHintProvider: () => 'cached-workspace',
      );

      await expectLater(
        transport.postJson(
          Uri.parse('https://example.test/v1/protected'),
          resource: _resource('workspace-1'),
          body: {'value': 'private'},
        ),
        throwsA(isA<AuthenticatedTransportException>()),
      );

      expect(client.requests, isEmpty);
    },
  );

  test('missing canonical resource prevents every network request', () async {
    final client = _RecordingClient((request, body) {
      throw StateError('unexpected network request');
    });
    final transport = AuthenticatedHttpTransport(
      client: client,
      sessionProvider: () async => _session(),
      workspaceHintProvider: () => 'cached-workspace',
    );

    await expectLater(
      transport.getJson(Uri.parse('https://example.test/v1/protected')),
      throwsA(isA<AuthenticatedTransportException>()),
    );

    expect(client.requests, isEmpty);
  });

  test(
    'missing server workspace prevents the protected network request',
    () async {
      final client = _RecordingClient((request, body) {
        expect(request.url.path, '/v1/authz/me');
        return http.Response(
          jsonEncode({
            'membership_status': 'active',
            'workspace_authorized': false,
            'workspace_id': null,
            'workspaces': [],
          }),
          200,
        );
      });
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceHintProvider: () => null,
      );

      await expectLater(
        transport.getJson(
          Uri.parse('https://example.test/v1/protected'),
          resource: _resource('workspace-1'),
        ),
        throwsA(isA<AuthenticatedTransportException>()),
      );

      expect(client.requests, hasLength(1));
      expect(client.requests.single.request.url.path, '/v1/authz/me');
    },
  );

  test('inactive membership prevents the protected network request', () async {
    final client = _RecordingClient((request, body) {
      expect(request.url.path, '/v1/authz/me');
      return http.Response(
        jsonEncode({
          'membership_status': 'suspended',
          'workspace_authorized': false,
          'workspace_id': 'workspace-1',
          'workspaces': [],
        }),
        200,
      );
    });
    final transport = AuthenticatedHttpTransport(
      client: client,
      sessionProvider: () async => _session(),
      workspaceHintProvider: () => null,
    );

    await expectLater(
      transport.postJson(
        Uri.parse('https://example.test/v1/protected'),
        resource: _resource('workspace-1'),
      ),
      throwsA(isA<AuthenticatedTransportException>()),
    );

    expect(client.requests, hasLength(1));
    expect(client.requests.single.request.url.path, '/v1/authz/me');
  });

  test(
    'cached workspace is only a hint and server workspace is used',
    () async {
      final client = _RecordingClient((request, body) {
        if (request.url.path == '/v1/authz/me') {
          if (_header(request, 'X-InsightFlow-Workspace-ID') ==
              'cached-workspace') {
            return http.Response(
              jsonEncode({
                'membership_status': 'none',
                'workspace_authorized': false,
                'workspace_id': 'cached-workspace',
                'workspaces': [],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(_activeWorkspaceResponse('server-workspace')),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      String? persistedWorkspace;
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceHintProvider: () => 'cached-workspace',
        workspaceHintWriter: (workspaceId) async {
          persistedWorkspace = workspaceId;
        },
      );

      final response = await transport.postJson(
        Uri.parse('https://example.test/v1/protected'),
        resource: _resource('server-workspace'),
        body: {'value': 'private'},
      );

      final protectedRequest = client.requests.last;
      expect(response.statusCode, 200);
      expect(client.requests, hasLength(3));
      expect(
        _header(client.requests[0].request, 'X-InsightFlow-Workspace-ID'),
        'cached-workspace',
      );
      expect(client.requests[1].request.url.path, '/v1/authz/me');
      expect(
        _header(protectedRequest.request, 'Authorization'),
        'Bearer access-token',
      );
      expect(
        _header(protectedRequest.request, 'X-InsightFlow-Workspace-ID'),
        'server-workspace',
      );
      expect(
        _header(protectedRequest.request, 'X-InsightFlow-Resource-ID'),
        'resource-1',
      );
      expect(persistedWorkspace, 'server-workspace');
      expect(jsonDecode(utf8.decode(protectedRequest.body)), {
        'value': 'private',
      });
    },
  );

  test(
    'valid GET requests carry bearer, workspace, and resource headers',
    () async {
      final client = _RecordingClient((request, body) {
        if (request.url.path == '/v1/authz/me') {
          return http.Response(
            jsonEncode(_activeWorkspaceResponse('workspace-1')),
            200,
          );
        }
        return http.Response('{"ok":true}', 200);
      });
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceHintProvider: () => null,
      );

      final response = await transport.getJson(
        Uri.parse('https://example.test/v1/protected'),
        resource: _resource('workspace-1'),
      );

      final protectedRequest = client.requests.last.request;
      expect(response.statusCode, 200);
      expect(protectedRequest.method, 'GET');
      expect(_header(protectedRequest, 'Authorization'), 'Bearer access-token');
      expect(
        _header(protectedRequest, 'X-InsightFlow-Workspace-ID'),
        'workspace-1',
      );
      expect(
        _header(protectedRequest, 'X-InsightFlow-Resource-ID'),
        'resource-1',
      );
    },
  );

  test(
    'valid multipart requests and Dio headers share the same context',
    () async {
      final client = _RecordingClient((request, body) {
        if (request.url.path == '/v1/authz/me') {
          return http.Response(
            jsonEncode(_activeWorkspaceResponse('workspace-1')),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceHintProvider: () => null,
      );
      final resource = _resource('workspace-1');

      final dioHeaders = await transport.dioHeaders(resource: resource);
      await transport.postMultipart(
        Uri.parse('https://example.test/v1/upload'),
        resource: resource,
        fields: {'kind': 'csv'},
        files: [
          http.MultipartFile.fromBytes('file', [1, 2, 3], filename: 'data.csv'),
        ],
      );

      final protectedRequest = client.requests.last;
      expect(dioHeaders, {
        'Authorization': 'Bearer access-token',
        'X-InsightFlow-Workspace-ID': 'workspace-1',
        'X-InsightFlow-Resource-ID': 'resource-1',
      });
      expect(protectedRequest.request, isA<http.MultipartRequest>());
      expect(
        _header(protectedRequest.request, 'Authorization'),
        'Bearer access-token',
      );
      expect(
        _header(protectedRequest.request, 'X-InsightFlow-Workspace-ID'),
        'workspace-1',
      );
      expect(
        _header(protectedRequest.request, 'X-InsightFlow-Resource-ID'),
        'resource-1',
      );
      expect(utf8.decode(protectedRequest.body), contains('name="kind"'));
      expect(utf8.decode(protectedRequest.body), contains('data.csv'));
    },
  );

  test('resource factory rejects non-canonical or inactive server records', () {
    expect(
      CanonicalResource.fromServerJson({
        'workspace_id': 'workspace-1',
        'status': 'active',
      }),
      isNull,
    );
    expect(
      CanonicalResource.fromServerJson({
        'resource_id': 'resource-1',
        'workspace_id': 'workspace-1',
        'status': 'deleted',
      }),
      isNull,
    );
  });

  test(
    'resource from another server workspace prevents protected I/O',
    () async {
      final client = _RecordingClient((request, body) {
        if (request.url.path == '/v1/authz/me') {
          return http.Response(
            jsonEncode(_activeWorkspaceResponse('workspace-1')),
            200,
          );
        }
        throw StateError('unexpected protected request');
      });
      final transport = AuthenticatedHttpTransport(
        client: client,
        sessionProvider: () async => _session(),
        workspaceHintProvider: () => null,
      );

      await expectLater(
        transport.getJson(
          Uri.parse('https://example.test/v1/protected'),
          resource: _resource('workspace-2'),
        ),
        throwsA(isA<AuthenticatedTransportException>()),
      );

      expect(client.requests, hasLength(1));
      expect(client.requests.single.request.url.path, '/v1/authz/me');
    },
  );
}
