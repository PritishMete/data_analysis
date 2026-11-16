import 'dart:js_interop';

@JS('window.__isInsightFlowExcelAuthDialog')
external JSBoolean? get _isExcelAuthDialog;

@JS('window.InsightFlowExcelAuth.openSignInDialog')
external JSPromise<JSString> _openSignInDialog();

@JS('window.InsightFlowExcelAuth.completeDialog')
external void _completeDialog(JSString refreshToken);

class ExcelAuthBridge {
  static bool get isAuthDialog => _isExcelAuthDialog?.toDart ?? false;

  static Future<String> openSignInDialog() async {
    final token = await _openSignInDialog().toDart;
    return token.toDart;
  }

  static void completeDialog(String refreshToken) {
    _completeDialog(refreshToken.toJS);
  }
}
