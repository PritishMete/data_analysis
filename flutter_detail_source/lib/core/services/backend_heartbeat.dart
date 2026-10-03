import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../auth/authenticated_http.dart';

const Duration backendHeartbeatInterval = Duration(minutes: 5);
const Duration _heartbeatTimeout = Duration(seconds: 8);
const Duration _resumeDebounce = Duration(seconds: 20);

Future<void> sendBackendHeartbeat({
  http.Client? client,
  String backendBaseUrl = insightFlowBackendBaseUrl,
}) async {
  final uri = Uri.parse('$backendBaseUrl/ping');
  if (client == null) {
    await http.get(uri).timeout(_heartbeatTimeout);
  } else {
    await client.get(uri).timeout(_heartbeatTimeout);
  }
}

/// Low-frequency, best-effort scheduler. It intentionally has no dependency
/// on authentication, session, organization, or authorization state.
class BackendHeartbeatController {
  BackendHeartbeatController({
    required Future<void> Function() send,
    this.interval = backendHeartbeatInterval,
    this.resumeDebounce = _resumeDebounce,
    DateTime Function()? now,
  }) : _sendRequest = send,
       _now = now ?? DateTime.now;

  final Future<void> Function() _sendRequest;
  final Duration interval;
  final Duration resumeDebounce;
  final DateTime Function() _now;

  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _inFlight = false;
  DateTime? _lastAttemptAt;

  bool get isInFlight => _inFlight;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _timer = Timer.periodic(interval, (_) {
      unawaited(_attempt());
    });
    unawaited(_attempt());
  }

  void onResumed() {
    if (!_started || _disposed) return;
    final lastAttempt = _lastAttemptAt;
    if (lastAttempt != null &&
        _now().difference(lastAttempt) < resumeDebounce) {
      return;
    }
    unawaited(_attempt());
  }

  Future<void> _attempt() async {
    if (!_started || _disposed || _inFlight) return;
    _inFlight = true;
    _lastAttemptAt = _now();
    try {
      await _sendRequest();
    } catch (_) {
      // A keep-alive failure must never affect application UX or auth state.
    } finally {
      _inFlight = false;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}

/// Owns the heartbeat for the lifetime of the Flutter application, not an
/// individual screen. Flutter Web lifecycle resume events cover returning to
/// a visible browser tab; browser timer throttling remains best-effort.
class BackendHeartbeatHost extends StatefulWidget {
  const BackendHeartbeatHost({required this.child, super.key});

  final Widget child;

  @override
  State<BackendHeartbeatHost> createState() => _BackendHeartbeatHostState();
}

class _BackendHeartbeatHostState extends State<BackendHeartbeatHost>
    with WidgetsBindingObserver {
  late final BackendHeartbeatController _heartbeat =
      BackendHeartbeatController(send: () => sendBackendHeartbeat());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (kIsWeb) _heartbeat.start();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb && state == AppLifecycleState.resumed) {
      _heartbeat.onResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _heartbeat.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
