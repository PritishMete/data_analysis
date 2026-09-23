import 'dart:js_interop';

@JS('getInsightFlowSourceWorksheetName')
external JSPromise<JSString?> _getSourceWorksheetName();

@JS('setInsightFlowSourceWorksheetName')
external JSPromise<JSBoolean> _setSourceWorksheetName(JSString sheetName);

Future<String?> getInsightFlowSourceWorksheetName() async {
  try {
    final result = await _getSourceWorksheetName().toDart;
    return result?.toDart;
  } catch (_) {
    return null;
  }
}

Future<bool> setInsightFlowSourceWorksheetName(String sheetName) async {
  try {
    return (await _setSourceWorksheetName(sheetName.toJS).toDart).toDart;
  } catch (_) {
    return false;
  }
}
