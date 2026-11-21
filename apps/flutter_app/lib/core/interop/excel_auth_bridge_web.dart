import 'dart:convert';

import 'dart:js_interop';

@JS('window.__isInsightFlowExcelAuthDialog')
external JSBoolean? get _isExcelAuthDialog;

@JS('window.InsightFlowExcelAuth.openSignInDialog')
external JSPromise<JSString> _openSignInDialog();

@JS('window.InsightFlowExcelAuth.setCorrelationId')
external void _setCorrelationId(JSString correlationId);

@JS('window.InsightFlowExcelAuth.currentCorrelationId')
external JSString? _currentCorrelationId();

@JS('window.InsightFlowExcelAuth.completeDialog')
external void _completeDialog(JSString refreshToken);

class ExcelAuthBridge {
  static bool get isAuthDialog => _isExcelAuthDialog?.toDart ?? false;

  static Future<({String refreshToken, String correlationId})>
  openSignInDialog() async {
    final payload =
        jsonDecode((await _openSignInDialog().toDart).toDart)
            as Map<String, dynamic>;
    return (
      refreshToken: payload['refreshToken'] as String,
      correlationId: payload['correlationId'] as String,
    );
  }

  static void setCorrelationId(String correlationId) =>
      _setCorrelationId(correlationId.toJS);

  static String? currentCorrelationId() => _currentCorrelationId()?.toDart;

  static void completeDialog(String refreshToken) {
    _completeDialog(refreshToken.toJS);
  }
}
