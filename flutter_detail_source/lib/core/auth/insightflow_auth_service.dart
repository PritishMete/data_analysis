import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../firebase_options.dart';
import 'auth_diagnostic.dart';

class InsightFlowAuthService {
  InsightFlowAuthService._();

  static FirebaseAuth get auth => FirebaseAuth.instance;

  static bool _googleSignInInitialized = false;
  static Object? _googleSignInInitializationError;
  static const String _googleWebClientId = String.fromEnvironment('INSIGHTFLOW_GOOGLE_WEB_CLIENT_ID');

  /// Resolves the build-provided Firebase configuration without initializing
  /// Firebase or logging any configuration values.
  static FirebaseOptions validateFirebaseConfiguration() {
    return DefaultFirebaseOptions.currentPlatform;
  }

  /// Initializes Firebase Core only. This is the only startup stage that
  /// makes the app eligible for the Firebase-configuration error screen.
  static Future<void> initializeFirebaseCore(FirebaseOptions options) async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(options: options);
    }
  }

  /// Configures Firebase Auth persistence independently of Firebase Core.
  static Future<void> initializeFirebasePersistence() async {
    if (!kIsWeb) return;
    await auth.setPersistence(Persistence.LOCAL);
  }

  /// Processes a pending Firebase OAuth redirect independently of Firebase
  /// configuration and provider SDK initialization.
  static Future<void> initializeRedirectResult() async {
    if (!kIsWeb) return;
    try {
      await auth.getRedirectResult();
    } on FirebaseAuthException catch (error, stackTrace) {
      debugPrint('Firebase redirect sign-in failed: ${error.code}');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Initializes the Google SDK independently. A failure here does not block
  /// Firebase Auth, email/password, or Microsoft authentication.
  static Future<void> initializeGoogleSignIn() async {
    try {
      await GoogleSignIn.instance.initialize(
        clientId: kIsWeb && _googleWebClientId.isNotEmpty ? _googleWebClientId : null,
      );
      _googleSignInInitialized = true;
      _googleSignInInitializationError = null;
    } catch (error, stackTrace) {
      _googleSignInInitialized = false;
      _googleSignInInitializationError = error;
      debugPrint('Google SDK initialization failed: ${error.runtimeType}');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }

  /// Compatibility entry point for callers that still initialize the whole
  /// auth service. Each stage remains independently diagnosable.
  static Future<void> initialize() async {
    final options = validateFirebaseConfiguration();
    await initializeFirebaseCore(options);
    await initializeFirebasePersistence();
    try {
      await initializeGoogleSignIn();
    } catch (_) {
      // Google is optional for Firebase Auth startup.
    }
    try {
      await initializeRedirectResult();
    } catch (_) {
      // A failed redirect result is not a Firebase configuration failure.
    }
  }

  static Stream<User?> get authStateChanges => auth.authStateChanges();
  static Stream<User?> get userChanges => auth.userChanges();
  static User? get currentUser => Firebase.apps.isEmpty ? null : auth.currentUser;

  static Future<UserCredential> signInWithEmailAndPassword(
    String email,
    String password,
  ) {
    return auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<UserCredential?> signInWithMicrosoft() async {
    final provider = OAuthProvider('microsoft.com')
      ..addScope('openid')
      ..addScope('profile')
      ..addScope('email');

    if (!kIsWeb) {
      return auth.signInWithProvider(provider);
    }

    try {
      debugPrint('[microsoft-popup] opening Firebase Microsoft provider');
      return await auth.signInWithPopup(provider);
    } on FirebaseAuthException catch (error, stackTrace) {
      debugPrint('[microsoft-popup] FirebaseAuthException: ${error.code}');
      debugPrintStack(stackTrace: stackTrace);
      if (error.code == 'popup-blocked' ||
          error.code == 'operation-not-supported-in-this-environment') {
        debugPrint('[microsoft-redirect] initiating Firebase OAuth redirect');
        await auth.signInWithRedirect(provider);
        // Redirect initiation is a successful hand-off, not an auth failure.
        // The browser will leave this page and initialize() will process the
        // result when Firebase returns to InsightFlow.
        return null;
      }
      rethrow;
    }
  }

  static Future<UserCredential> signInWithGoogle() async {
    if (!_googleSignInInitialized) {
      final cause = _googleSignInInitializationError;
      debugPrint('[google-authenticate] initialization unavailable: ${cause?.runtimeType ?? 'unknown'}');
      throw FirebaseAuthException(
        code: 'google-sign-in-initialization-failed',
        message: 'Google sign-in is unavailable because its provider initialization failed.',
      );
    }
    if (kIsWeb) {
      debugPrint('[google-authenticate] web authenticate is unsupported; use renderButton');
      throw FirebaseAuthException(
        code: 'google-web-ui-required',
        message: 'Google Web sign-in must be started by the Google provider button.',
      );
    }
    try {
      debugPrint('[google-authenticate] native authenticate');
      final GoogleSignInAccount googleUser = await GoogleSignIn.instance.authenticate();
      return await signInWithGoogleAccount(googleUser);
    } on GoogleSignInException catch (error, stackTrace) {
      _logGoogleException('google-authenticate', error, stackTrace);
      throw _mapGoogleSignInException(error);
    }
  }

  /// Completes Firebase authentication from an already-authenticated Google
  /// account. On Web this is called from the GIS rendered-button event, so it
  /// must not start another interactive Google authorization request.
  static Future<UserCredential> signInWithGoogleAccount(
    GoogleSignInAccount googleUser,
    {AuthDiagnosticAttempt? diagnostic},
  ) async {
    try {
      final idToken = googleUser.authentication.idToken;
      if (idToken == null || idToken.isEmpty) {
        debugPrint('[firebase-google-credential] missing Google ID token');
        throw FirebaseAuthException(
          code: 'google-id-token-missing',
          message: 'Google authentication did not provide an ID token.',
        );
      }
      diagnostic?.record('GOOGLE_ID_TOKEN_PRESENT');
      debugPrint('[firebase-google-credential] creating Firebase credential');
      final credential = GoogleAuthProvider.credential(idToken: idToken);
      diagnostic?.record('FIREBASE_CREDENTIAL_CREATED');
      final before = auth.currentUser != null ? 'PRESENT' : 'ABSENT';
      diagnostic?.currentUserBefore = before;
      debugPrint('[auth-diagnostic] currentUserBefore=$before');
      diagnostic?.record('FIREBASE_SIGN_IN_STARTED');
      try {
        final result = await auth.signInWithCredential(credential);
        diagnostic?.record('FIREBASE_SIGN_IN_SUCCESS');
        final after = auth.currentUser != null ? 'PRESENT' : 'ABSENT';
        diagnostic?.currentUserAfter = after;
        debugPrint('[auth-diagnostic] currentUserAfter=$after');
        diagnostic?.record('FIREBASE_CURRENT_USER_PRESENT');
        final user = auth.currentUser;
        if (user != null) {
          diagnostic?.record('FIREBASE_ID_TOKEN_REFRESH_STARTED');
          try {
            await user.getIdToken(true);
          } on FirebaseAuthException catch (error) {
            diagnostic?.record('FIREBASE_TOKEN_REFRESH_FAILED', code: error.code);
            rethrow;
          }
          diagnostic?.record('FIREBASE_ID_TOKEN_REFRESH_SUCCESS');
        }
        return result;
      } on FirebaseAuthException catch (error) {
        diagnostic?.record('FIREBASE_SIGN_IN_FAILED', code: error.code);
        if (_isStaleFirebaseSessionError(error.code) && before == 'PRESENT') {
          diagnostic?.record('FIREBASE_STALE_SESSION_DETECTED', code: error.code);
          await auth.signOut();
          diagnostic?.record('FIREBASE_STALE_SESSION_CLEARED');
          diagnostic?.record('FIREBASE_SIGN_IN_RETRY_STARTED');
          try {
            final retry = await auth.signInWithCredential(credential);
            diagnostic?.record('FIREBASE_SIGN_IN_SUCCESS');
            final retryAfter = auth.currentUser != null ? 'PRESENT' : 'ABSENT';
            diagnostic?.currentUserAfter = retryAfter;
            diagnostic?.record('FIREBASE_CURRENT_USER_PRESENT');
            return retry;
          } on FirebaseAuthException catch (retryError) {
            diagnostic?.record('FIREBASE_SIGN_IN_RETRY_FAILED', code: retryError.code);
            rethrow;
          }
        }
        rethrow;
      }
    } on GoogleSignInException catch (error, stackTrace) {
      _logGoogleException('google-authentication', error, stackTrace);
      throw _mapGoogleSignInException(error);
    } on FirebaseAuthException catch (error, stackTrace) {
      debugPrint('[firebase-google-credential] FirebaseAuthException: ${error.code}');
      debugPrintStack(stackTrace: stackTrace);
      rethrow;
    }
  }
  static bool _isStaleFirebaseSessionError(String code) {
    return <String>{
      'user-not-found',
      'user-token-expired',
      'invalid-user-token',
    }.contains(code);
  }

$marker(String stage, GoogleSignInException error, StackTrace stackTrace) {
    debugPrint('[$stage] GoogleSignInExceptionCode=${error.code.name} type=${error.runtimeType}');
    debugPrintStack(stackTrace: stackTrace);
  }

  static FirebaseAuthException _mapGoogleSignInException(GoogleSignInException error) {
    if (error.code == GoogleSignInExceptionCode.canceled) {
      return FirebaseAuthException(code: 'popup-closed-by-user', message: 'Google sign-in was cancelled.');
    }
    if (error.code == GoogleSignInExceptionCode.uiUnavailable) {
      return FirebaseAuthException(code: 'popup-blocked', message: 'The Google sign-in window could not be opened.');
    }
    if (error.code == GoogleSignInExceptionCode.clientConfigurationError ||
        error.code == GoogleSignInExceptionCode.providerConfigurationError) {
      return FirebaseAuthException(code: 'invalid-configuration', message: 'Google sign-in is not configured for this application.');
    }
    return FirebaseAuthException(code: 'google-provider-error', message: 'Google sign-in could not be completed.');
  }

  static Future<UserCredential> createUserWithEmailAndPassword(
    String email,
    String password,
  ) {
    return auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<void> sendEmailVerification() async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }
    await user.sendEmailVerification();
  }

  static Future<bool> reloadCurrentUser({AuthDiagnosticAttempt? diagnostic}) async {
    final user = auth.currentUser;
    if (user == null) return false;
    try {
      await user.reload();
    } on FirebaseAuthException catch (error) {
      diagnostic?.record('FIREBASE_USER_RELOAD_FAILED', code: error.code);
      rethrow;
    }
    return auth.currentUser?.emailVerified ?? false;
  }

  static Future<void> sendPasswordResetEmail(String email) {
    return auth.sendPasswordResetEmail(email: email.trim());
  }

  static Future<void> updateProfile({
    String? displayName,
    String? photoUrl,
  }) async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }
    await user.updateProfile(displayName: displayName, photoURL: photoUrl);
  }

  static Future<void> verifyBeforeUpdateEmail(String email) async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }
    await user.verifyBeforeUpdateEmail(email.trim());
  }

  static Future<void> reauthenticateWithPassword(String password) async {
    final user = auth.currentUser;
    if (user == null || user.email == null) {
      throw StateError('Email/password reauthentication is unavailable.');
    }
    final credential = EmailAuthProvider.credential(
      email: user.email!.trim(),
      password: password,
    );
    await user.reauthenticateWithCredential(credential);
  }

  static Future<void> reauthenticateWithGoogle() async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }

    if (kIsWeb) {
      await user.reauthenticateWithPopup(GoogleAuthProvider());
      return;
    }

    final googleSignIn = GoogleSignIn.instance;
    try {
      final GoogleSignInAccount googleUser = await googleSignIn.authenticate();
      final clientAuth = await googleUser.authorizationClient
          .authorizeScopes(['email', 'profile']);
      final credential = GoogleAuthProvider.credential(
        idToken: googleUser.authentication.idToken,
        accessToken: clientAuth.accessToken,
      );
      await user.reauthenticateWithCredential(credential);
    } on GoogleSignInException catch (error, stackTrace) {
      debugPrint(
        'Google reauthentication failed: ${error.code.name}: ${error.description ?? ''}',
      );
      debugPrintStack(stackTrace: stackTrace);
      if (error.code == GoogleSignInExceptionCode.canceled) {
        throw FirebaseAuthException(
          code: 'popup-closed-by-user',
          message: 'Google reauthentication was cancelled.',
        );
      }
      rethrow;
    }
  }

  static Future<void> changePassword(String newPassword) async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }
    await user.updatePassword(newPassword);
  }

  static Future<void> deleteAccount() async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }
    await user.delete();
  }

  static Future<void> signOut() => auth.signOut();

  static Map<String, String?> currentProviderIdentity(String providerId) {
    final user = auth.currentUser;
    UserInfo? provider;
    for (final item in user?.providerData ?? const <UserInfo>[]) {
      if (item.providerId == providerId) {
        provider = item;
        break;
      }
    }
    return {
      'firebase_uid': user?.uid,
      'provider_id': provider?.providerId,
      'provider_subject': provider?.uid,
      'verified_email': user?.email,
      'display_name': provider?.displayName ?? user?.displayName,
      'photo_url': provider?.photoURL ?? user?.photoURL,
    };
  }

  static bool hasProvider(String providerId) {
    final user = auth.currentUser;
    return user?.providerData.any((p) => p.providerId == providerId) ?? false;
  }

  static Future<String> getIdToken({bool forceRefresh = false}) async {
    final user = auth.currentUser;
    if (user == null) {
      throw StateError('Firebase authentication required.');
    }
    final token = await user.getIdToken(forceRefresh);
    if (token == null || token.isEmpty) {
      throw StateError('Firebase authentication token unavailable.');
    }
    return token;
  }

  static String userFacingAuthError(Object error) {
    if (error is GoogleSignInException) {
      switch (error.code) {
        case GoogleSignInExceptionCode.canceled:
          return 'Sign-in was cancelled.';
        case GoogleSignInExceptionCode.uiUnavailable:
          return 'The sign-in window could not be opened. Allow pop-ups and try again.';
        case GoogleSignInExceptionCode.clientConfigurationError:
        case GoogleSignInExceptionCode.providerConfigurationError:
          return 'Google sign-in is not configured correctly for this application.';
        default:
          return 'Google sign-in could not be completed. Please try again.';
      }
    }

    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-credential':
        case 'invalid-login-credentials':
        case 'wrong-password':
          return 'Email or password is incorrect.';
        case 'user-not-found':
          return 'Firebase authentication could not be completed. Please sign in again.';
        case 'user-disabled':
          return 'This account is disabled.';
        case 'too-many-requests':
          return 'Too many sign-in attempts. Please try again later.';
        case 'network-request-failed':
          return 'Network connection failed. Check your connection and try again.';
        case 'operation-not-allowed':
          return 'This sign-in method is not enabled for this Firebase project.';
        case 'invalid-configuration':
          return 'This sign-in provider is not configured correctly. Check the Firebase provider settings.';
        case 'google-sign-in-initialization-failed':
          return 'Google sign-in could not start. Try email/password or Microsoft sign-in, or try Google again later.';
        case 'google-web-ui-required':
          return 'Google sign-in must be started with the Google sign-in button.';
        case 'google-provider-error':
          return 'Google sign-in could not be completed. Please try again.';
        case 'operation-not-supported-in-this-environment':
          return 'This sign-in method is not supported in this environment. Try again in a browser window.';
        case 'email-already-in-use':
          return 'An account already exists for this email.';
        case 'weak-password':
          return 'Choose a stronger password and try again.';
        case 'invalid-email':
          return 'Enter a valid email address.';
        case 'requires-recent-login':
        case 'credential-too-old-login-again':
          return 'Please sign in again to continue this security-sensitive action.';
        case 'account-exists-with-different-credential':
          return 'An account already exists with another sign-in method. Sign in with that method first.';
        case 'credential-already-in-use':
          return 'That sign-in credential is already linked to another account.';
        case 'popup-blocked':
          return 'The sign-in window was blocked. Allow pop-ups and try again.';
        case 'popup-closed-by-user':
        case 'cancelled-popup-request':
          return 'Sign-in was cancelled.';
        case 'invalid-verification-code':
        case 'expired-action-code':
          return 'That verification link is no longer valid. Request a new one.';
        case 'user-token-expired':
          return 'Your session expired. Please sign in again.';
        case 'web-storage-unsupported':
          return 'Persistent sign-in is unavailable in this browser.';
        default:
          return 'Authentication could not be completed. Please try again.';
      }
    }
    if (error is StateError) return error.message.toString();
    return 'Authentication could not be completed. Please try again.';
  }
}
