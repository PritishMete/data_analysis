import 'dart:js_interop';

@JS('window.__isInsightFlowExcelAuthDialog')
external JSBoolean? get _isExcelAuthDialog;

@JS('window.InsightFlowExcelAuth.getTransactionId')
external JSString _getTransactionId();

@JS('window.InsightFlowExcelAuth.isDialog')
external JSBoolean _isDialog();

@JS('window.InsightFlowExcelAuth.saveExcelTransaction')
external void _saveExcelTransaction(JSString value);

@JS('window.InsightFlowExcelAuth.loadExcelTransaction')
external JSString _loadExcelTransaction();

@JS('window.InsightFlowExcelAuth.clearExcelTransaction')
external void _clearExcelTransaction();

@JS('window.InsightFlowExcelAuth.copyText')
external JSPromise<JSBoolean> _copyText(JSString value);

@JS('window.InsightFlowExcelAuth.prepareBrowser')
external JSAny? _prepareBrowser(JSString value);

@JS('window.InsightFlowExcelAuth.startGoogle')
external JSPromise<JSAny?> _startGoogle();

@JS('window.InsightFlowExcelAuth.passwordSignIn')
external JSPromise<JSString> _passwordSignIn(JSString value);

@JS('window.InsightFlowExcelAuth.resumeOAuth')
external JSPromise<JSBoolean> _resumeOAuth();

@JS('window.InsightFlowExcelAuth.openOfficeDialog')
external JSPromise<JSString> _openOfficeDialog(JSString url);

class ExcelAuthBridge {
  static bool get isAuthDialog => _isExcelAuthDialog?.toDart ?? false;
  static bool get isDialog => _isDialog().toDart;
  static String get browserHandoffId => _getTransactionId().toDart;

  static void saveExcelTransaction(String json) => _saveExcelTransaction(json.toJS);
  static String loadExcelTransaction() => _loadExcelTransaction().toDart;
  static void clearExcelTransaction() => _clearExcelTransaction();

  static Future<void> copyText(String value) async {
    await _copyText(value.toJS).toDart;
  }

  static void prepareBrowser(String json) {
    _prepareBrowser(json.toJS);
  }

  static Future<void> startGoogle() async {
    await _startGoogle().toDart;
  }

  static Future<String> passwordSignIn(String json) async {
    return (await _passwordSignIn(json.toJS).toDart).toDart;
  }

  static Future<bool> resumeOAuth() async {
    return (await _resumeOAuth().toDart).toDart;
  }

  static Future<void> openOfficeDialog(String url) async {
    await _openOfficeDialog(url.toJS).toDart;
  }
}
