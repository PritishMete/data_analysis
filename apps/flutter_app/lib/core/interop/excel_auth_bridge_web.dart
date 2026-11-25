import 'dart:js_interop';

@JS('window.__isInsightFlowExcelAuthDialog')
external JSBoolean? get _isExcelAuthDialog;
@JS('window.__insightFlowExcelAuthCorrelation')
external JSString? get _excelAuthCorrelation;

@JS('window.InsightFlowExcelAuth.openSignInDialog')
external JSPromise<JSString> _openSignInDialog(JSString correlationId);

@JS('window.InsightFlowExcelAuth.completeDialog')
external void _completeDialog(JSString refreshToken);
@JS('window.InsightFlowExcelAuth.setDiagnosticsEnabled')
external void _setDiagnosticsEnabled(JSBoolean enabled);
@JS('window.__INSIGHTFLOW_EXCEL_AUTH_DIAGNOSTICS__')
external JSBoolean? get _diagnosticsActive;
@JS('window.InsightFlowExcelAuth.exportDiagnostics')
external JSString _exportDiagnostics();
@JS('window.InsightFlowExcelAuth.resetDiagnostics')
external void _resetDiagnostics();

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

  static void setDiagnosticsEnabled(bool enabled) {
    _setDiagnosticsEnabled(enabled.toJS);
  }

  static bool get diagnosticsActive => _diagnosticsActive?.toDart ?? false;
  static String bridgeDiagnosticsJson() => _exportDiagnostics().toDart;
  static void resetDiagnostics() => _resetDiagnostics();
}
