const bool secureLocalOnly = true;
const bool agenticCategorizationEnabled = true;

enum PrivacyOperation { remoteFileUpload, powerBiDetailAnalysis, telemetry }

class PrivacyConsentDenied implements Exception {
  const PrivacyConsentDenied(this.operation);

  final PrivacyOperation operation;

  @override
  String toString() => 'Explicit consent required for ${operation.name}.';
}

/// Process-local, fail-closed consent. Consent is never inferred from login,
/// secureLocalOnly, or a previous operation and can be revoked immediately.
class PrivacyConsent {
  PrivacyConsent._();

  static final Set<PrivacyOperation> _granted = <PrivacyOperation>{};

  static bool has(PrivacyOperation operation) => _granted.contains(operation);

  static void grant(PrivacyOperation operation) => _granted.add(operation);

  static void revoke(PrivacyOperation operation) => _granted.remove(operation);

  static void revokeAll() => _granted.clear();
}
