import 'dart:convert';

import 'package:http/http.dart' as http;

const String _defaultLocalLlmEndpoint = String.fromEnvironment(
  'INSIGHTFLOW_LOCAL_LLM_ENDPOINT',
  defaultValue: 'http://127.0.0.1:8787',
);

String _normalizeLocalHost(String host) => host.toLowerCase().trim();

bool _isLoopbackHost(String host) {
  final normalized = _normalizeLocalHost(host);
  return normalized == 'localhost' || normalized == '127.0.0.1' || normalized == '::1';
}

abstract class LocalLlmProvider {
  Future<List<LocalLlmMapping>> categorizeValues({
    required String semanticType,
    required List<String> values,
    required String instruction,
  });

  Future<List<LocalSentimentLabel>> analyzeSentiment({
    required List<String> reviews,
    required String instruction,
  });
}

class LocalLlmMapping {
  final String source;
  final String canonical;
  final double confidence;

  const LocalLlmMapping({
    required this.source,
    required this.canonical,
    required this.confidence,
  });

  factory LocalLlmMapping.fromJson(Map<String, dynamic> json) {
    return LocalLlmMapping(
      source: json['source']?.toString() ?? '',
      canonical: json['canonical']?.toString() ?? '',
      confidence: (json['confidence'] is num)
          ? (json['confidence'] as num).toDouble()
          : double.tryParse(json['confidence']?.toString() ?? '') ?? 0.0,
    );
  }
}

class LocalSentimentLabel {
  final int index;
  final String sentiment;
  final double score;

  const LocalSentimentLabel({
    required this.index,
    required this.sentiment,
    required this.score,
  });

  factory LocalSentimentLabel.fromJson(Map<String, dynamic> json) {
    return LocalSentimentLabel(
      index: json['index'] is num ? (json['index'] as num).toInt() : int.tryParse(json['index']?.toString() ?? '') ?? -1,
      sentiment: json['sentiment']?.toString() ?? 'Neutral',
      score: (json['score'] is num)
          ? (json['score'] as num).toDouble()
          : double.tryParse(json['score']?.toString() ?? '') ?? 0.0,
    );
  }
}

class HttpLocalLlmProvider implements LocalLlmProvider {
  final Uri endpoint;
  final String provider;
  final String model;

  HttpLocalLlmProvider({
    required this.endpoint,
    required this.provider,
    required this.model,
  });

  factory HttpLocalLlmProvider.fromEnvironment() {
    final endpoint = Uri.parse(_defaultLocalLlmEndpoint);
    if (!_isLoopbackHost(endpoint.host)) {
      throw StateError('Local LLM endpoint must default to localhost.');
    }
    return HttpLocalLlmProvider(
      endpoint: endpoint,
      provider: const String.fromEnvironment('INSIGHTFLOW_LOCAL_LLM_PROVIDER', defaultValue: 'local'),
      model: const String.fromEnvironment('INSIGHTFLOW_LOCAL_LLM_MODEL', defaultValue: 'local-default'),
    );
  }

  Future<Map<String, dynamic>?> _postJson(String path, Map<String, dynamic> body) async {
    final uri = endpoint.resolve(path.startsWith('/') ? path.substring(1) : path);
    if (!_isLoopbackHost(uri.host)) {
      throw StateError('Refusing to call non-local LLM endpoint: ${uri.host}');
    }
    final response = await http
        .post(
          uri,
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode({
            ...body,
            'provider': provider,
            'model': model,
          }),
        )
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300 || response.body.trim().isEmpty) {
      return null;
    }
    final decoded = jsonDecode(response.body);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  }

  @override
  Future<List<LocalLlmMapping>> categorizeValues({
    required String semanticType,
    required List<String> values,
    required String instruction,
  }) async {
    final decoded = await _postJson('/categorize', {
      'semantic_type': semanticType,
      'values': values,
      'instruction': instruction,
    });
    if (decoded == null) return const <LocalLlmMapping>[];
    final mappings = decoded['mappings'];
    if (mappings is! List) return const <LocalLlmMapping>[];
    return mappings
        .whereType<Map>()
        .map((m) => LocalLlmMapping.fromJson(Map<String, dynamic>.from(m)))
        .where((m) => m.source.isNotEmpty && m.canonical.isNotEmpty)
        .toList();
  }

  @override
  Future<List<LocalSentimentLabel>> analyzeSentiment({
    required List<String> reviews,
    required String instruction,
  }) async {
    final decoded = await _postJson('/sentiment', {
      'reviews': reviews,
      'instruction': instruction,
    });
    if (decoded == null) return const <LocalSentimentLabel>[];
    final labels = decoded['labels'];
    if (labels is! List) return const <LocalSentimentLabel>[];
    return labels
        .whereType<Map>()
        .map((m) => LocalSentimentLabel.fromJson(Map<String, dynamic>.from(m)))
        .where((l) => l.index >= 0)
        .toList();
  }
}

LocalLlmProvider? createLocalLlmProvider() {
  try {
    return HttpLocalLlmProvider.fromEnvironment();
  } catch (_) {
    return null;
  }
}
