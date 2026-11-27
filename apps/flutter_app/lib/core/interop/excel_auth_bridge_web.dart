import 'dart:js_interop';

@JS('window.__isInsightFlowExcelAuthDialog')
external JSBoolean? get _isExcelAuthDialog;
@JS('window.__insightFlowExcelAuthCorrelation')
external JSString? get _excelAuthCorrelation;

@JS('window.InsightFlowExcelAuth.openSignInDialog')
external JSPromise<JSString> _openSignInDialog(
  JSString correlationId,
  JSString backendOrigin,
);

@JS('window.InsightFlowExcelAuth.waitForHandoffContext')
external JSPromise<JSString> _waitForHandoffContext();

@JS('window.InsightFlowExcelAuth.completeDialog')
external JSPromise<JSBoolean> _completeDialog(
  JSString accessToken,
  JSString refreshToken,
  JSString backendOrigin,
);
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

  static Future<String> openSignInDialog(
    String correlationId,
    String backendOrigin,
  ) async {
    final token = await _openSignInDialog(
      correlationId.toJS,
      backendOrigin.toJS,
    ).toDart;
    return token.toDart;
  }

  static Future<void> prepareDialogHandoff() async {
    await _waitForHandoffContext().toDart;
  }

  static Future<void> completeDialog(
    String accessToken,
    String refreshToken,
    String backendOrigin,
  ) async {
    final completed = await _completeDialog(
      accessToken.toJS,
      refreshToken.toJS,
      backendOrigin.toJS,
    ).toDart;
    if (!completed.toDart) throw StateError('excel_handoff_unavailable');
  }

  static void setDiagnosticsEnabled(bool enabled) {
    _setDiagnosticsEnabled(enabled.toJS);
  }

  static bool get diagnosticsActive => _diagnosticsActive?.toDart ?? false;
  static String bridgeDiagnosticsJson() => _exportDiagnostics().toDart;
  static void resetDiagnostics() => _resetDiagnostics();
}
