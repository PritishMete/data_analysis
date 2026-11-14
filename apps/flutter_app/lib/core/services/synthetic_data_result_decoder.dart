import 'dart:convert';

/// The synthetic taskpane JS contract is a JSON-like object. This decoder
/// accepts that object directly and only parses JSON when a legacy deployment
/// still returns JSON text. It never passes a Dart Map to jsonDecode.
Map<String, dynamic> decodeSyntheticInteropValue(Object? value) {
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  if (value is String) {
    final decoded = jsonDecode(value);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  throw const FormatException('Synthetic Excel engine returned an unsupported response contract.');
}
