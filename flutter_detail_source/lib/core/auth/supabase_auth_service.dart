import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

class InsightFlowSupabaseConfig {
  static const url = String.fromEnvironment('INSIGHTFLOW_SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}

/// Additive Supabase Auth provider. Firebase Auth remains the active UI
/// provider until the application-wide cutover phase.
class InsightFlowSupabaseAuthService {
  InsightFlowSupabaseAuthService._();

  static SupabaseClient get client => Supabase.instance.client;
  static bool get isInitialized => Supabase.instance.isInitialized;

  static Future<bool> initialize() async {
    if (!InsightFlowSupabaseConfig.isConfigured) return false;
    if (!isInitialized) {
      await Supabase.initialize(
        url: InsightFlowSupabaseConfig.url,
        publishableKey: InsightFlowSupabaseConfig.publishableKey,
        debug: false,
      );
    }
    return true;
  }

  static Session? get currentSession =>
      isInitialized ? client.auth.currentSession : null;
  static Stream<AuthState> get authStateChanges =>
      client.auth.onAuthStateChange;
  static String? get accessToken => currentSession?.accessToken;
  static SupabaseAuthUser? get currentUser {
    final user = currentSession?.user;
    return user == null ? null : SupabaseAuthUser(user.id, user.email);
  }

  static Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) {
    return client.auth.signInWithPassword(email: email, password: password);
  }

  static Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? displayName,
  }) {
    return client.auth.signUp(
      email: email,
      password: password,
      data: displayName == null ? null : {'display_name': displayName},
    );
  }

  static Future<void> resetPassword(String email, {String? redirectTo}) {
    return client.auth.resetPasswordForEmail(email, redirectTo: redirectTo);
  }

  static Future<bool> signInWithOAuth(
    OAuthProvider provider, {
    String? redirectTo,
  }) async {
    return client.auth.signInWithOAuth(provider, redirectTo: redirectTo);
  }

  static Future<void> signOut() => client.auth.signOut();

  /// Returns a usable session after OAuth callback restoration, refreshing a
  /// session that is expired or close to expiry.
  static Future<Session?> ensureSession({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    var session = currentSession;
    if (session == null) {
      try {
        await client.auth.onAuthStateChange
            .firstWhere((state) => state.session != null)
            .timeout(timeout);
      } on TimeoutException {
        return null;
      }
      session = currentSession;
    }
    if (session == null) return null;

    final expiresAt = session.expiresAt;
    final needsRefresh = expiresAt != null &&
        expiresAt <= DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30;
    if (needsRefresh) {
      try {
        final refreshed = await client.auth.refreshSession();
        session = refreshed.session ?? currentSession;
      } catch (_) {
        return null;
      }
    }
    if (session.accessToken.isEmpty) return null;
    return session;
  }

  static void logSafeStatus() {
    debugPrint(
      '[supabase-auth] configured: ${InsightFlowSupabaseConfig.isConfigured}',
    );
  }
}

class SupabaseAuthUser {
  const SupabaseAuthUser(this.uid, this.email);
  final String uid;
  final String? email;
}
