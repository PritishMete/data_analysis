import 'dart:js_interop';

@JS('window.__isInsightFlowExcelAuthDialog')
external JSBoolean? get _isExcelAuthDialog;
@JS('window.__insightFlowExcelAuthCorrelation')
external JSString? get _excelAuthCorrelation;

@JS('window.InsightFlowExcelAuth.openSignInDialog')
external JSPromise<JSString> _openSignInDialog(JSString correlationId);

@JS('window.InsightFlowExcelAuth.completeDialog')
external void _completeDialog(JSString refreshToken);

class ExcelAuthBridge {
  static bool get isAuthDialog => _isExcelAuthDialog?.toDart ?? false;
  static String? get correlationId => _excelAuthCorrelation?.toDart;

  static Future<String> openSignInDialog(String correlationId) async {
    final token = await _openSignInDialog(correlationId.toJS).toDart;
    return token.toDart;
  }

  static void completeDialog(String refreshToken) {
    _completeDialog(refreshToken.toJS);
  }
}
