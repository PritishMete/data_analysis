import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/core/security/outbound_privacy_guard.dart';
import 'package:liquid_glass_widgets/core/security/privacy_mode.dart';

void main() {
  setUp(() => PrivacyConsent.revokeAll());

  test('remote file upload is blocked without explicit consent', () {
    expect(
      () => OutboundPrivacyGuard.requireFileUploadConsent(
        destination: 'https://oracle.example/upload',
      ),
      throwsA(isA<PrivacyConsentDenied>()),
    );
  });

  test('revocation blocks future remote file uploads', () {
    final request = PrivacyConsent.request(
      operation: PrivacyOperation.remoteFileUpload,
      destination: 'https://oracle.example/upload',
      explanation: 'Upload this selected file for analysis.',
    );
    expect(request.explanation, contains('selected file'));
    PrivacyConsent.grant(request);
    expect(
      () => OutboundPrivacyGuard.requireFileUploadConsent(
        destination: request.destination,
      ),
      returnsNormally,
    );

    PrivacyConsent.revoke(request);
    expect(
      () => OutboundPrivacyGuard.requireFileUploadConsent(
        destination: request.destination,
      ),
      throwsA(isA<PrivacyConsentDenied>()),
    );
  });

  test('Power BI and telemetry consent are independent operations', () {
    PrivacyConsent.grant(
      PrivacyConsent.request(
        operation: PrivacyOperation.powerBiDetailAnalysis,
        destination: 'https://oracle.example/powerbi',
        explanation: 'Send selected datasets to Power BI analysis.',
      ),
    );

    expect(
      () => OutboundPrivacyGuard.requirePowerBiConsent(
        destination: 'https://oracle.example/powerbi',
      ),
      returnsNormally,
    );
    expect(
      () => OutboundPrivacyGuard.requireTelemetryConsent(
        destination: 'https://oracle.example',
      ),
      throwsA(isA<PrivacyConsentDenied>()),
    );
  });
}
