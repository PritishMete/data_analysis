import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/core/security/outbound_privacy_guard.dart';
import 'package:liquid_glass_widgets/core/security/privacy_mode.dart';

void main() {
  setUp(() => PrivacyConsent.revokeAll());

  test('remote file upload is blocked without explicit consent', () {
    expect(
      () => OutboundPrivacyGuard.requireFileUploadConsent(),
      throwsA(isA<PrivacyConsentDenied>()),
    );
  });

  test('revocation blocks future remote file uploads', () {
    PrivacyConsent.grant(PrivacyOperation.remoteFileUpload);
    expect(
      () => OutboundPrivacyGuard.requireFileUploadConsent(),
      returnsNormally,
    );

    PrivacyConsent.revoke(PrivacyOperation.remoteFileUpload);
    expect(
      () => OutboundPrivacyGuard.requireFileUploadConsent(),
      throwsA(isA<PrivacyConsentDenied>()),
    );
  });

  test('Power BI and telemetry consent are independent operations', () {
    PrivacyConsent.grant(PrivacyOperation.powerBiDetailAnalysis);

    expect(() => OutboundPrivacyGuard.requirePowerBiConsent(), returnsNormally);
    expect(
      () => OutboundPrivacyGuard.requireTelemetryConsent(),
      throwsA(isA<PrivacyConsentDenied>()),
    );
  });
}
