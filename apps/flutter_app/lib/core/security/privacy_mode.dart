/// Local-only remains the safe default, but can be explicitly changed at
/// build time for a deployment that also uses the consent flow.
const bool secureLocalOnly = bool.fromEnvironment(
  'INSIGHTFLOW_SECURE_LOCAL_ONLY',
  defaultValue: true,
);
const bool agenticCategorizationEnabled = true;

enum PrivacyOperation {
  remoteFileUpload,
  powerBiDetailAnalysis,
  datasetCleaning,
  chatPlanning,
  telemetry,
}

class PrivacyConsentRequest {
  const PrivacyConsentRequest({
    required this.operation,
    required this.destination,
    required this.explanation,
  });

  final PrivacyOperation operation;
  final String destination;
  final String explanation;
}

class PrivacyConsentDenied implements Exception {
  const PrivacyConsentDenied(this.operation, {this.destination});

  final PrivacyOperation operation;
  final String? destination;

  @override
  String toString() =>
      'Explicit consent required for ${operation.name}'
      '${destination == null ? '' : ' to $destination'}.';
}

/// Process-local, fail-closed consent. Consent is never inferred from login,
/// secureLocalOnly, or a previous operation and can be revoked immediately.
class PrivacyConsent {
  PrivacyConsent._();

  static final Set<String> _granted = <String>{};

  static String _key(PrivacyOperation operation, String destination) =>
      '${operation.name}|$destination';

  static bool has(PrivacyOperation operation, String destination) =>
      _granted.contains(_key(operation, destination));

  static void grant(PrivacyConsentRequest request) =>
      _granted.add(_key(request.operation, request.destination));

  static void revoke(PrivacyConsentRequest request) =>
      _granted.remove(_key(request.operation, request.destination));

  static PrivacyConsentRequest request({
    required PrivacyOperation operation,
    required String destination,
    required String explanation,
  }) => PrivacyConsentRequest(
    operation: operation,
    destination: destination,
    explanation: explanation,
  );

  static void revokeAll() => _granted.clear();
}
