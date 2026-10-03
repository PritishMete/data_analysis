import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../lib/core/services/backend_heartbeat.dart';

void main() {
  group('sendBackendHeartbeat', () {
    test('uses the configured public ping endpoint without auth headers', () async {
      var requested = false;
      final client = MockClient((request) async {
        requested = true;
        expect(request.method, 'GET');
        expect(request.url.toString(), 'https://backend.example/ping');
        expect(
          request.headers.keys.any(
            (key) => key.toLowerCase() == 'authorization',
          ),
          isFalse,
        );
        return http.Response('{"status":"awake"}', 200);
      });

      await sendBackendHeartbeat(
        client: client,
        backendBaseUrl: 'https://backend.example',
      );

      expect(requested, isTrue);
      client.close();
    });
  });

  group('BackendHeartbeatController', () {
    test('starts immediately and schedules low-frequency attempts', () async {
      var calls = 0;
      final controller = BackendHeartbeatController(
        send: () async {
          calls++;
        },
        interval: const Duration(milliseconds: 20),
      );

      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 65));
      expect(calls, greaterThanOrEqualTo(2));

      controller.dispose();
      final stoppedAt = calls;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(calls, stoppedAt);
    });

    test('does not overlap an in-flight request', () async {
      final firstRequest = Completer<void>();
      var calls = 0;
      var activeRequests = 0;
      var maxConcurrentRequests = 0;
      final controller = BackendHeartbeatController(
        send: () async {
          calls++;
          activeRequests++;
          if (activeRequests > maxConcurrentRequests) {
            maxConcurrentRequests = activeRequests;
          }
          try {
            if (calls == 1) await firstRequest.future;
          } finally {
            activeRequests--;
          }
        },
        interval: const Duration(milliseconds: 15),
      );

      controller.start();
      await Future<void>.delayed(const Duration(milliseconds: 55));
      expect(calls, 1);
      expect(controller.isInFlight, isTrue);

      firstRequest.complete();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(calls, greaterThanOrEqualTo(2));
      expect(maxConcurrentRequests, 1);
      controller.dispose();
    });

    test('silently absorbs request failures', () async {
      final controller = BackendHeartbeatController(
        send: () async => throw StateError('offline'),
        interval: const Duration(hours: 1),
      );

      controller.start();
      await Future<void>.delayed(Duration.zero);
      expect(controller.isInFlight, isFalse);
      controller.dispose();
    });

    test('resume triggers an attempt but debounces duplicate lifecycle events',
        () async {
      var now = DateTime.utc(2026, 1, 1);
      var calls = 0;
      final controller = BackendHeartbeatController(
        send: () async {
          calls++;
        },
        interval: const Duration(hours: 1),
        now: () => now,
      );

      controller.start();
      await Future<void>.delayed(Duration.zero);
      controller.onResumed();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);

      now = now.add(const Duration(seconds: 21));
      controller.onResumed();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      controller.dispose();
    });

    test('dispose prevents further attempts and resume work', () async {
      var calls = 0;
      final controller = BackendHeartbeatController(
        send: () async {
          calls++;
        },
        interval: const Duration(milliseconds: 10),
      );

      controller.start();
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      final disposedCount = calls;
      controller.onResumed();
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(calls, disposedCount);
    });
  });
}
