import 'package:web/web.dart' as web;

import 'oauth_callback_cleanup_logic.dart';

/// Removes only Supabase callback parameters after the authenticated gate has
/// observed a valid session. Unrelated routing and Excel handoff parameters
/// remain intact, and no token or callback value is logged.
void cleanOAuthCallbackUrl() {
  cleanOAuthCallbackUrlFromUri(
    Uri.base,
    (relativeUrl) => web.window.history.replaceState(null, '', relativeUrl),
  );
}
