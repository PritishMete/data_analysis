/// Attempts server-side cancellation, then always removes this task pane's
/// local handoff capabilities, including when the network request fails.
Future<void> cancelExcelHandoffSafely({
  required Future<void> Function() cancelRemote,
  required void Function() clearLocalCapabilities,
}) async {
  try {
    await cancelRemote();
  } catch (_) {
    // The server transaction remains bounded by its expiry and cannot be
    // claimed after expiry. Never retain the local claim/cancel capabilities.
  }
  clearLocalCapabilities();
}
