import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class InsightFlowSupabaseConfig {
  static const url = String.fromEnvironment('INSIGHTFLOW_SUPABASE_URL');
  static const publishableKey = String.fromEnvironment(
    'INSIGHTFLOW_SUPABASE_PUBLISHABLE_KEY',
  );

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;
}

class InsightFlowSupabaseAuthService {
  static String? _sessionOnlyEmail;
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
      // Publish the locally restored session immediately. Waiting for
      // Supabase's browser-storage restoration event here can make the entire
      // Auth page appear frozen after a device wakes from sleep.
      final initialSession = currentSession;
      yield AuthState(AuthChangeEvent.initialSession, initialSession);
      await for (final state in client.auth.onAuthStateChange) {
        final sameSession = state.session?.accessToken != null &&
            state.session?.accessToken == initialSession?.accessToken;
        if (state.event == AuthChangeEvent.initialSession && sameSession) {
          continue;
        }
        yield state;
      }
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
  static Future<User?> fetchAuthoritativeUser({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // This is an authoritative check, but it must never freeze AuthGate when
    // the browser/network is temporarily unavailable.
    final response = await client.auth.getUser().timeout(timeout);
    return response.user;
  }

  static bool isEmailVerificationError(Object error) {
    // Supabase documents email_not_confirmed as the server error returned
    // when Confirm Email is enabled and an unverified user attempts password
    // sign-in. Keep the code check authoritative, while also handling older
    // client/server combinations that expose only a human-readable message.
    if (error is AuthException) {
      final code = error.code?.toLowerCase().trim() ?? '';
      final message = error.message.toLowerCase().trim();
      return code == 'email_not_confirmed' ||
          code == 'email_not_verified' ||
          message.contains('email_not_confirmed') ||
          message.contains('email_not_verified') ||
          message.contains('email not confirmed') ||
          message.contains('email not verified') ||
          message.contains('email confirmation') ||
          (message.contains('confirm') && message.contains('email')) ||
          (message.contains('verif') && message.contains('email'));
    }

    // Do not let an SDK wrapper turn a known verification failure into the
    // generic "Authentication could not be completed" message.
    final text = error.toString().toLowerCase();
    return text.contains('email_not_confirmed') ||
        text.contains('email_not_verified') ||
        text.contains('email not confirmed') ||
        text.contains('email not verified') ||
        text.contains('email confirmation');
  }

  static SupabaseAuthUser? get currentUser {
    final user = currentSupabaseUser;
    return user == null ? null : SupabaseAuthUser(
      user.id,
      user.email,
      emailVerified: user.emailConfirmedAt != null,
    );
  }

  static Future<void> setRememberDevice(String identity, bool remember) async {
    final normalized = identity.trim().toLowerCase();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('insightflow.remember.$normalized', remember);
    if (remember) {
      if (_sessionOnlyEmail == normalized) _sessionOnlyEmail = null;
    } else {
      _sessionOnlyEmail = normalized.isEmpty ? null : normalized;
    }
  }

  static Future<bool> rememberDevice(String identity) async {
    final normalized = identity.trim().toLowerCase();
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('insightflow.remember.$normalized') ?? true;
  }

  static void markSessionOnlyLogin(String identity) {
    final normalized = identity.trim().toLowerCase();
    _sessionOnlyEmail = normalized.isEmpty ? null : normalized;
  }

  static bool allowsCurrentSession(String identity) =>
      _sessionOnlyEmail == identity.trim().toLowerCase();

  static Future<AuthResponse> signInWithPassword({
    required String email,
    required String password,
  }) {
    return client.auth.signInWithPassword(email: email, password: password);
  }

  static Future<void> setPassword(
    String password, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    await client.auth
        .updateUser(UserAttributes(password: password))
        .timeout(timeout);
  }

  static Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? displayName,
  }) async {
    // Signup must remain a Supabase-only operation. Retry provider
    // initialization here so a startup race cannot turn a valid signup into
    // an unhelpful generic authentication failure.
    if (!InsightFlowSupabaseConfig.isConfigured) {
      throw StateError('Supabase authentication is not configured for this build.');
    }
    if (!isInitialized) {
      await initialize();
    }
    if (!isInitialized) {
      throw StateError('Supabase authentication could not be initialized.');
    }
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

  static Future<void> beginPhoneVerification(String phone) async {
    await client.auth.updateUser(
      UserAttributes(phone: phone.trim()),
    );
  }

  static Future<AuthResponse> verifyPhoneChangeOtp({
    required String phone,
    required String token,
  }) {
    return client.auth.verifyOTP(
      type: OtpType.phoneChange,
      phone: phone.trim(),
      token: token.trim(),
    );
  }

  static Future<void> resendPhoneChangeOtp(String phone) async {
    await client.auth.resend(
      type: OtpType.phoneChange,
      phone: phone.trim(),
    );
  }

  static Future<void> signOut() => client.auth.signOut();

  static Future<Session?>? _ensureSessionFuture;

  static Future<Session?> ensureSession({
    Duration timeout = const Duration(seconds: 3),
  }) {
    final active = _ensureSessionFuture;
    if (active != null) {
      return active;
    }

    final future = _ensureSession(timeout);
    _ensureSessionFuture = future;
    return future.whenComplete(() {
      if (identical(_ensureSessionFuture, future)) {
        _ensureSessionFuture = null;
      }
    });
  }

  static Future<Session?> _ensureSession(Duration timeout) async {
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
        final refreshed = await client.auth
            .refreshSession()
            .timeout(timeout);
        session = refreshed.session ?? currentSession;
      } on TimeoutException {
        debugPrint('[supabase-auth] session refresh timed out');
        return null;
      } catch (error, stackTrace) {
        debugPrint('[supabase-auth] session refresh failed: ${error.runtimeType}');
        debugPrintStack(stackTrace: stackTrace);
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
