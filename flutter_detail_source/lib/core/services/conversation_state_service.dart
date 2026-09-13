import 'dart:convert';

import 'package:http/http.dart' as http;

/// Local-only client for InsightFlow's structured conversation-state APIs.
///
/// These endpoints never need dataset values and are deliberately separate
/// from Gemini-backed reasoning. The backend stores only bounded analytical
/// context (scope, filters, selected entity, history and report metadata).
class ConversationStateService {
  ConversationStateService({http.Client? client, Uri? baseUri})
      : _client = client ?? http.Client(),
        _baseUri = baseUri ?? Uri.parse('http://127.0.0.1:8000');

  final http.Client _client;
  final Uri _baseUri;

  Uri _uri(String path) => _baseUri.resolve(path);

  Future<Map<String, dynamic>> suggestions({
    required String sessionId,
    Map<String, dynamic> context = const <String, dynamic>{},
    int limit = 5,
  }) async {
    final response = await _client
        .post(
          _uri('/v1/conversation/suggestions'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'session_id': sessionId,
            'context': context,
            'limit': limit,
          }),
        )
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not load suggested next questions.');
  }

  Future<Map<String, dynamic>> summary(String sessionId) async {
    final response = await _client
        .get(_uri('/v1/conversation/summary/${Uri.encodeComponent(sessionId)}'))
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not summarize this analysis session.');
  }

  Future<Map<String, dynamic>> state(String sessionId) async {
    final response = await _client
        .get(_uri('/v1/conversation/state/${Uri.encodeComponent(sessionId)}'))
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not read this analysis session.');
  }

  Future<Map<String, dynamic>> update({
    required String sessionId,
    required Map<String, dynamic> update,
  }) async {
    final response = await _client
        .post(
          _uri('/v1/conversation/state/update'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'session_id': sessionId, 'update': update}),
        )
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not update this analysis session.');
  }

  Future<Map<String, dynamic>> reset(String sessionId) async {
    final response = await _client
        .post(_uri('/v1/conversation/reset/${Uri.encodeComponent(sessionId)}'))
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not reset this analysis session.');
  }

  Future<Map<String, dynamic>> snapshot(String sessionId) async {
    final response = await _client
        .post(
          _uri(
            '/v1/conversation/transaction/${Uri.encodeComponent(sessionId)}/snapshot',
          ),
        )
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not snapshot this analysis session.');
  }

  Future<Map<String, dynamic>> restore({
    required String sessionId,
    required Map<String, dynamic> snapshot,
  }) async {
    final response = await _client
        .post(
          _uri(
            '/v1/conversation/transaction/${Uri.encodeComponent(sessionId)}/restore',
          ),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'snapshot': snapshot}),
        )
        .timeout(const Duration(seconds: 15));
    return _decode(response, 'Could not restore the last good analysis state.');
  }

  Map<String, dynamic> _decode(http.Response response, String fallback) {
    dynamic decoded;
    try {
      decoded = jsonDecode(response.body);
    } catch (_) {
      throw FormatException(fallback);
    }
    if (decoded is! Map) throw FormatException(fallback);
    final map = Map<String, dynamic>.from(decoded);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(map['error']?.toString() ?? fallback);
    }
    if (map['success'] == false) {
      throw FormatException(map['error']?.toString() ?? fallback);
    }
    return map;
  }

  void dispose() => _client.close();
}
