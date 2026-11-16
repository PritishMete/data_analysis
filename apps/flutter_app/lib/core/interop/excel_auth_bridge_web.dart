import 'dart:js_interop';

@JS('window.InsightFlowExcelAuth.openSignInDialog')
external JSPromise<JSString> _openSignInDialog();

@JS('window.InsightFlowExcelAuth.completeDialog')
external void _completeDialog(JSString refreshToken);

class ExcelAuthBridge {
  static Future<String> openSignInDialog() async {
    final token = await _openSignInDialog().toDart;
    return token.toDart;
  }

  static void completeDialog(String refreshToken) {
    _completeDialog(refreshToken.toJS);
  }
}
