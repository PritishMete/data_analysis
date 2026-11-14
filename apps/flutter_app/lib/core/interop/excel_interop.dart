// lib/core/interop/excel_interop.dart
// Conditional export — routes to correct implementation based on target compilation context.
export 'excel_interop_stub.dart'
if (dart.library.js_interop) 'excel_interop_web.dart';