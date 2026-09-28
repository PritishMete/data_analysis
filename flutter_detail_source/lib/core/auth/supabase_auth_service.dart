import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class InsightFlowSupabaseConfig {
  static const url = String.fromEnvironment('INSIGHTFLOW_SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}

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
        authOptions: FlutterAuthClientOptions(
          authFlowType: kIsWeb ? AuthFlowType.implicit : AuthFlowType.pkce,
          detectSessionInUri: true,
        ),
        debug: false,
      );
    }
    return true;
  }

  static Session? get currentSession =>
      isInitialized ? client.auth.currentSession : null;

  /// Keeps AuthGate alive when Supabase reports a callback/deep-link parsing
  /// error. If no session exists, emit an initial-session state so AuthGate
  /// can render the signed-out screen instead of remaining in loading forever.
  static Stream<AuthState> get authStateChanges async* {
    if (!isInitialized) {
      // The Supabase provider is optional for builds that intentionally do not
      // ship its public runtime configuration. AuthGate must render the
      // signed-out state rather than exposing the provider initialization
      // exception as an authentication error.
      yield AuthState(AuthChangeEvent.initialSession, null);
      return;
    }
    try {
      yield* client.auth.onAuthStateChange;
    } catch (error, stackTrace) {
      debugPrint('[supabase-auth] auth-state stream error: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      yield AuthState(AuthChangeEvent.initialSession, currentSession);
    }
  }

  static String? get accessToken => currentSession?.accessToken;
  static User? get currentSupabaseUser => currentSession?.user;

  static bool get isCurrentUserEmailVerified =>
      currentSupabaseUser?.emailConfirmedAt != null;

  /// Fetch the user from Supabase Auth instead of trusting a possibly stale
  /// locally-restored session object. This is used at the authorization
  /// boundary before organization/workspace access is allowed.
  static Future<User?> fetchAuthoritativeUser() async {
    final response = await client.auth.getUser();
    return response.user;
  }

  static bool isEmailVerificationError(Object error) {
    if (error is AuthException) {
      final code = error.code.toLowerCase();
      final message = error.message.toLowerCase();
      return code == 'email_not_confirmed' ||
          code == 'email_not_verified' ||
          message.contains('email not confirmed') ||
          message.contains('email not verified') ||
          message.contains('email confirmation');
    }
    return false;
  }

  static SupabaseAuthUser? get currentUser {
    final user = currentSupabaseUser;
    return user == null ? null : SupabaseAuthUser(
      user.id,
      user.email,
      emailVerified: user.emailConfirmedAt != null,
    );
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
      emailRedirectTo: 'https://pritishmete.github.io/data_analysis/',
      data: displayName == null ? null : {'display_name': displayName},
    );
  }

  static Future<void> resendSignupVerification(String email) {
    return client.auth.resend(
      type: OtpType.signup,
      email: email.trim(),
      emailRedirectTo: 'https://pritishmete.github.io/data_analysis/',
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
      } catch (error, stackTrace) {
        debugPrint('[supabase-auth] session restoration error: ${error.runtimeType}');
        debugPrintStack(stackTrace: stackTrace);
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
    if (session?.accessToken.isEmpty ?? true) return null;
    return session;
  }

  static void logSafeStatus() {
    debugPrint(
      '[supabase-auth] configured: ${InsightFlowSupabaseConfig.isConfigured}',
    );
  }
}

class SupabaseAuthUser {
  const SupabaseAuthUser(
    this.uid,
    this.email, {
    required this.emailVerified,
  });
  final String uid;
  final String? email;
  final bool emailVerified;
}
