class ExcelAuthBridge {
  static bool get isAuthDialog => false;
  static String? get correlationId => null;

  static Future<String> openSignInDialog(String correlationId, String backendOrigin) async {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }

  static Future<void> prepareDialogHandoff() async {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }

  static Future<void> completeDialog(String accessToken, String refreshToken, String backendOrigin) async {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }

  static void setDiagnosticsEnabled(bool enabled) {}
  static bool get diagnosticsActive => false;
  static String bridgeDiagnosticsJson() => '[]';
  static void resetDiagnostics() {}
}
