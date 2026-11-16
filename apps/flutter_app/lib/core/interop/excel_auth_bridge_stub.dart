class ExcelAuthBridge {
  static bool get isAuthDialog => false;

  static Future<String> openSignInDialog() async {
    throw UnsupportedError('Excel sign-in is available only in the Office web host.');
  }

  static void completeDialog(String refreshToken) {
    throw UnsupportedError('Excel sign-in is available only in the Office web host.');
  }
}
