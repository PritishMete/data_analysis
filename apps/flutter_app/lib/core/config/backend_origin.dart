// The public Flutter web app must use the Cloudflare API gateway backed by Oracle.
// Keep this origin configurable for controlled non-production builds.
const String insightFlowDefaultBackendOrigin =
    'https://insightflow-api.jaiphotoshoot.workers.dev';

const String _configuredBackendOrigin = String.fromEnvironment(
  'INSIGHTFLOW_BACKEND_URL',
);

String get insightFlowBackendOrigin {
  return normalizeInsightFlowBackendOrigin(_configuredBackendOrigin);
}

String normalizeInsightFlowBackendOrigin(String configured) {
  final raw = configured.trim();
  if (raw.isEmpty) return insightFlowDefaultBackendOrigin;
  final parsed = Uri.tryParse(raw);
  if (parsed == null ||
      (parsed.scheme != 'https' && parsed.scheme != 'http') ||
      parsed.host.isEmpty ||
      parsed.userInfo.isNotEmpty ||
      parsed.path.replaceAll('/', '').isNotEmpty ||
      parsed.query.isNotEmpty ||
      parsed.fragment.isNotEmpty) {
    return insightFlowDefaultBackendOrigin;
  }
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
  ).toString().replaceFirst(RegExp(r'/$'), '');
}
