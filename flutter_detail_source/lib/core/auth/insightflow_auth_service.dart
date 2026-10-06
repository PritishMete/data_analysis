import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'supabase_auth_service.dart';

/// Compatibility facade retained for non-UI callers while authentication is
/// fully owned by Supabase Auth. No Firebase or external identity provider is
/// used by this service.
class InsightFlowAuthService {
  InsightFlowAuthService._();

  static SupabaseAuthUser? get currentUser =>
      InsightFlowSupabaseAuthService.currentUser;

  static Future<void> signOut() => InsightFlowSupabaseAuthService.signOut();

  static Future<String> getIdToken({bool forceRefresh = false}) async {
    final session = await InsightFlowSupabaseAuthService.ensureSession();
    final token = session?.accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Supabase authentication required.');
    }
    return token;
  }

  static String userFacingAuthError(Object error) {
    if (error is AuthException) {
      final code = error.code?.toLowerCase().trim() ?? '';
      final message = error.message.toLowerCase();
      if (code.contains('email_not_confirmed') ||
          code.contains('email_not_verified') ||
          message.contains('email not confirmed') ||
          message.contains('email not verified') ||
          message.contains('email confirmation')) {
        return 'Please verify your email using the confirmation link before signing in.';
      }
      switch (code) {
        case 'invalid_credentials':
        case 'invalid_login_credentials':
          return 'Email or password is incorrect.';
        case 'email_exists':
        case 'user_already_exists':
          return 'An account already exists for this email.';
        case 'weak_password':
          return 'Choose a stronger password and try again.';
        case 'invalid_email':
          return 'Enter a valid email address.';
        case 'too_many_requests':
          return 'Too many attempts. Please try again later.';
      }
      if (error.message.trim().isNotEmpty) return error.message;
    }
    if (error is StateError) return error.message;
    debugPrint('[supabase-auth] ' + error.runtimeType.toString() + ': ' + error.toString());
    return 'Authentication could not be completed. Please try again.';
  }
}

