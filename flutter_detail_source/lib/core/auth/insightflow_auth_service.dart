import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_auth_service.dart';

/// Compatibility facade for legacy call sites. InsightFlow authentication is
/// Supabase-only; this class does not initialize or depend on Firebase.
class InsightFlowAuthService {
  InsightFlowAuthService._();

  static Future<bool> initialize() => InsightFlowSupabaseAuthService.initialize();

  static Future<bool> initializeGoogleSignIn() async => true;
  static Future<void> initializeFirebasePersistence() async {}
  static Future<void> initializeRedirectResult() async {}

  static Future<bool> signInWithMicrosoft() {
    return InsightFlowSupabaseAuthService.signInWithOAuth(
      OAuthProvider.azure,
      redirectTo: 'https://pritishmete.github.io/data_analysis/',
    );
  }

  static Future<String> getIdToken({bool forceRefresh = false}) async {
    final session = await InsightFlowSupabaseAuthService.ensureSession(
      timeout: const Duration(seconds: 8),
    );
    final token = session?.accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Supabase authentication token unavailable.');
    }
    return token;
  }

  static _SupabaseCompatUser? get currentUser {
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    return user == null ? null : _SupabaseCompatUser(user.id);
  }

  static String userFacingAuthError(Object error) {
    if (error is AuthException) {
      final code = error.code?.toLowerCase() ?? '';
      switch (code) {
        case 'invalid_credentials':
        case 'invalid_grant':
          return 'Email or password is incorrect.';
        case 'email_not_confirmed':
        case 'email_not_verified':
          return 'Email not verified. Please verify your email first.';
        case 'user_not_found':
          return 'The account could not be found. Please sign in again.';
        case 'too_many_requests':
          return 'Too many attempts. Please try again later.';
        default:
          return error.message.isNotEmpty
              ? error.message
              : 'Authentication could not be completed. Please try again.';
      }
    }
    if (error is StateError) return error.message.toString();
    return 'Authentication could not be completed. Please try again.';
  }
}

class _SupabaseCompatUser {
  const _SupabaseCompatUser(this.uid);
  final String uid;
}
