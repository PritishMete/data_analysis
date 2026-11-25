class ExcelAuthBridge {
  static bool get isAuthDialog => false;
  static String? get correlationId => null;

  static Future<String> openSignInDialog(String correlationId) async {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }

  static void completeDialog(String refreshToken) {
    throw UnsupportedError(
      'Excel sign-in is available only in the Office web host.',
    );
  }
}
