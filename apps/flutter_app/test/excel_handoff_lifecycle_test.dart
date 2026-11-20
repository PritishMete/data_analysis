import 'package:flutter_test/flutter_test.dart';

import '../lib/core/auth/excel_handoff_lifecycle.dart';

void main() {
  test('clears local handoff capabilities after successful server cancellation', () async {
    var remoteCancelCalled = false;
    var localCapabilitiesCleared = false;

    await cancelExcelHandoffSafely(
      cancelRemote: () async {
        remoteCancelCalled = true;
      },
      clearLocalCapabilities: () => localCapabilitiesCleared = true,
    );

    expect(remoteCancelCalled, isTrue);
    expect(localCapabilitiesCleared, isTrue);
  });

  test('clears local handoff capabilities even when server cancellation fails', () async {
    var localCapabilitiesCleared = false;

    await expectLater(
      cancelExcelHandoffSafely(
        cancelRemote: () async => throw StateError('network unavailable'),
        clearLocalCapabilities: () => localCapabilitiesCleared = true,
      ),
      completes,
    );

    expect(localCapabilitiesCleared, isTrue);
  });
}
