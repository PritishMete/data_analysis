// lib/core/interop/office_host_web.dart
@JS()
library office_host_interop;

import 'dart:js_interop';

// window.__isOfficeHost is set in web/index.html's Office.onReady callback,
// and is only ever true when Office.js has actually attached to a real
// Office host (Excel, Word, etc.) rather than a plain browser tab. Reading
// it directly (instead of e.g. sniffing the user agent) is what lets us
// tell "real Excel Add-in task pane" apart from "flutter run -d chrome" —
// both of which load the exact same index.html / Office.js script tag.
@JS('window.__isOfficeHost')
external JSBoolean? get _isOfficeHostFlag;

/// Whether the app is currently running inside an Office host's task pane
/// (Excel, in practice), as opposed to a plain browser tab.
///
/// Read once at startup (see main.dart) to decide whether to force
/// shader-free [GlassQuality.minimal] rendering — Office Add-in task panes
/// run inside a WebView2 instance that, on some machines, doesn't reliably
/// support the fragment shaders the `standard`/`premium` glass tiers depend
/// on, causing GlassContainer/GlassCard surfaces to paint as solid blocks
/// with no visible content instead of throwing a catchable error.
bool get isRunningInsideOffice => _isOfficeHostFlag?.toDart ?? false;
