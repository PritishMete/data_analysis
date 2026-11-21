class ExcelAuthBridge {
  static bool get isAuthDialog => false;

  static Future<({String refreshToken, String correlationId})>
  openSignInDialog() async {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }

  static void setCorrelationId(String correlationId) {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }

  static String? currentCorrelationId() => null;

  static void completeDialog(String refreshToken) {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }
}
