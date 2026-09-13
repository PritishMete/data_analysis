// lib/core/interop/office_host.dart
// Conditional export — routes to correct implementation based on target compilation context.
export 'office_host_stub.dart'
if (dart.library.js_interop) 'office_host_web.dart';
