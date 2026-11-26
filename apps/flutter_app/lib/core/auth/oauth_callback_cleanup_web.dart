import 'package:web/web.dart' as web;

const _oauthCallbackKeys = <String>{
  'code',
  'error',
  'error_code',
  'error_description',
  'error_uri',
};

/// Removes only Supabase callback parameters after the authenticated gate has
/// observed a valid session. Unrelated routing and Excel handoff parameters
/// remain intact, and no token or callback value is logged.
void cleanOAuthCallbackUrl() {
  final current = Uri.base;
  final retained = <String, List<String>>{};
  for (final entry in current.queryParametersAll.entries) {
    if (!_oauthCallbackKeys.contains(entry.key)) {
      retained[entry.key] = List<String>.from(entry.value);
    }
  }
  if (retained.length == current.queryParametersAll.length) return;

  final cleaned = current.replace(queryParameters: retained);
  final path = '${cleaned.path}${cleaned.hasQuery ? '?${cleaned.query}' : ''}${cleaned.hasFragment ? '#${cleaned.fragment}' : ''}';
  web.window.history.replaceState(null, '', path);
}
