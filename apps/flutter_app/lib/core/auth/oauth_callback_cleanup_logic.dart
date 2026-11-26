const oauthCallbackKeys = <String>{
  'code',
  'error',
  'error_code',
  'error_description',
  'error_uri',
};

/// Applies callback cleanup and invokes [replaceState] only when an OAuth
/// callback parameter was present. This is platform-neutral so it can be
/// behaviorally tested without a browser.
bool cleanOAuthCallbackUrlFromUri(
  Uri current,
  void Function(String relativeUrl) replaceState,
) {
  final retained = <String, List<String>>{};
  for (final entry in current.queryParametersAll.entries) {
    if (!oauthCallbackKeys.contains(entry.key)) {
      retained[entry.key] = List<String>.from(entry.value);
    }
  }
  if (retained.length == current.queryParametersAll.length) return false;

  final cleaned = current.replace(queryParameters: retained);
  final relativeUrl =
      '${cleaned.path}${cleaned.hasQuery ? '?\${cleaned.query}' : ''}'
      '${cleaned.hasFragment ? '#\${cleaned.fragment}' : ''}';
  replaceState(relativeUrl);
  return true;
}
