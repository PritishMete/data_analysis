import 'package:supabase_flutter/supabase_flutter.dart';

/// Performs a local-only sign-out, optionally clearing client-specific state
/// immediately before Supabase removes this installation's session.
Future<void> performInsightFlowLocalSignOut({
  required Future<void> Function(SignOutScope scope) signOut,
  void Function()? beforeSignOut,
}) async {
  beforeSignOut?.call();
  await signOut(SignOutScope.local);
}
