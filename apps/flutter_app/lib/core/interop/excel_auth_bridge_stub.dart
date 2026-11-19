class ExcelAuthBridge {
  static bool get isAuthDialog => false;
  static bool get isDialog => false;
  static String get browserHandoffId => '';
  static void saveExcelTransaction(String json) {}
  static String loadExcelTransaction() => '';
  static void clearExcelTransaction() {}
  static Future<void> copyText(String value) async =>
      throw UnsupportedError('Clipboard is unavailable on this host.');
  static void prepareBrowser(String json) =>
      throw UnsupportedError('Excel browser authentication is available only on web.');
  static Future<void> startGoogle() async =>
      throw UnsupportedError('Excel browser authentication is available only on web.');
  static Future<String> passwordSignIn(String json) async =>
      throw UnsupportedError('Excel browser authentication is available only on web.');
  static Future<bool> resumeOAuth() async =>
      throw UnsupportedError('Excel browser authentication is available only on web.');
  static Future<void> openOfficeDialog(String url) async =>
      throw UnsupportedError('Office dialog authentication is available only on web.');
}
