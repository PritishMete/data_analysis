// Conditional export for the Office dialog authentication bridge.
export 'excel_auth_bridge_stub.dart'
    if (dart.library.js_interop) 'excel_auth_bridge_web.dart';
