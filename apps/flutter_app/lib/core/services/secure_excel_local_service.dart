// Platform-neutral entry point. Office worksheet execution is web-only and
// runs directly inside the Excel taskpane; the non-web stub keeps tests and
// other Flutter targets free from dart:js_interop imports.
export 'secure_excel_local_service_stub.dart'
    if (dart.library.js_interop) 'secure_excel_local_service_web.dart';
