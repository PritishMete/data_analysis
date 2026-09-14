double? parseEmbeddedReportScrollDelta(String message, String token) {
  final prefix = 'detail-analysis-scroll|$token|';
  if (!message.startsWith(prefix)) return null;
  final delta = double.tryParse(message.substring(prefix.length));
  if (delta == null || !delta.isFinite || delta == 0) return null;
  return delta;
}
