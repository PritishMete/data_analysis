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
    if (user == null) return null;
    final metadata = user.userMetadata;
    return _SupabaseCompatUser(
      uid: user.id,
      email: user.email,
      displayName: (metadata['display_name'] ?? metadata['full_name'] ?? metadata['name'])?.toString(),
    );
  }

  static bool hasProvider(String providerId) {
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    if (user == null) return false;
    final normalized = providerId.trim().toLowerCase();
    final expected = normalized == 'password' ? 'email' : normalized == 'google.com' ? 'google' : normalized;
    return user.identities?.any((identity) =>
            identity.provider.toLowerCase() == expected) ??
        false;
  }

  static Future<void> reauthenticateWithPassword(String password) async {
    final email = currentUser?.email;
    if (email == null || email.isEmpty) {
      throw StateError('Email/password reauthentication is unavailable.');
    }
    await InsightFlowSupabaseAuthService.signInWithPassword(
      email: email,
      password: password,
    );
  }

  static Future<void> reauthenticateWithGoogle() async {
    await InsightFlowSupabaseAuthService.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'https://pritishmete.github.io/data_analysis/',
    );
  }

  static Future<void> updateProfile({
    String? displayName,
    String? photoUrl,
  }) async {
    await InsightFlowSupabaseAuthService.client.auth.updateUser(
      UserAttributes(
        data: {
          if (displayName != null) 'display_name': displayName,
          if (photoUrl != null) 'avatar_url': photoUrl,
        },
      ),
    );
  }

  static Future<void> verifyBeforeUpdateEmail(String email) async {
    await InsightFlowSupabaseAuthService.client.auth.updateUser(
      UserAttributes(email: email.trim()),
    );
  }

  static Future<void> changePassword(String newPassword) async {
    await InsightFlowSupabaseAuthService.setPassword(newPassword);
  }

  static Future<void> deleteAccount() async {
    // The protected /account/cleanup endpoint performs the server-side
    // Supabase account deletion before this client-side session is cleared.
    await InsightFlowSupabaseAuthService.signOut();
  }

  static Future<void> signOut() => InsightFlowSupabaseAuthService.signOut();

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
  const _SupabaseCompatUser({
    required this.uid,
    this.email,
    this.displayName,
  });

  final String uid;
  final String? email;
  final String? displayName;
}
