import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../firebase_options.dart';

class InsightFlowAuthService {
  InsightFlowAuthService._();

  static FirebaseAuth get auth => FirebaseAuth.instance;

  static Future<void> initialize() async {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }

    // Native Firebase Auth persists sessions by default. On web, explicitly
    // select LOCAL so a successful sign-in survives page reloads/browser
    // restarts instead of becoming a session-only login.
    if (kIsWeb) {
      await auth.setPersistence(Persistence.LOCAL);
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

  static Future<UserCredential> signInWithGoogle() async {
    if (kIsWeb) {
      return auth.signInWithPopup(GoogleAuthProvider());
    }

    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) {
      throw FirebaseAuthException(
        code: 'popup-closed-by-user',
        message: 'Google sign-in was cancelled.',
      );
    }
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    return auth.signInWithCredential(credential);
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

  static Future<bool> reloadCurrentUser() async {
    final user = auth.currentUser;
    if (user == null) return false;
    await user.reload();
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

    final googleUser = await GoogleSignIn().signIn();
    if (googleUser == null) {
      throw FirebaseAuthException(
        code: 'popup-closed-by-user',
        message: 'Google reauthentication was cancelled.',
      );
    }
    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );
    await user.reauthenticateWithCredential(credential);
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
    if (error is FirebaseAuthException) {
      switch (error.code) {
        case 'invalid-credential':
        case 'invalid-login-credentials':
        case 'wrong-password':
        case 'user-not-found':
          return 'Email or password is incorrect.';
        case 'user-disabled':
          return 'This account is disabled.';
        case 'too-many-requests':
          return 'Too many sign-in attempts. Please try again later.';
        case 'network-request-failed':
          return 'Network connection failed. Check your connection and try again.';
        case 'operation-not-allowed':
          return 'This sign-in method is not enabled for this Firebase project.';
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
