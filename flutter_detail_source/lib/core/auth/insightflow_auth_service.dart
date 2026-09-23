import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

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

    if (kIsWeb) {
      await auth.setPersistence(Persistence.LOCAL);
    }
  }

  static Stream<User?> get authStateChanges => auth.authStateChanges();

  static Future<UserCredential> signInWithEmailAndPassword(
    String email,
    String password,
  ) {
    return auth.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
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

  static Future<void> sendPasswordResetEmail(String email) {
    return auth.sendPasswordResetEmail(email: email.trim());
  }

  static Future<void> signOut() => auth.signOut();

  /// Firebase refreshes an expired token automatically. Passing true is used
  /// after a protected API reports an authentication failure or when the
  /// caller explicitly needs a fresh token.
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
          return 'Email/password authentication is not enabled for this Firebase project.';
        case 'email-already-in-use':
          return 'An account already exists for this email.';
        case 'weak-password':
          return 'Choose a stronger password and try again.';
        case 'invalid-email':
          return 'Enter a valid email address.';
        default:
          return 'Sign-in could not be completed. Please try again.';
      }
    }
    return 'Sign-in could not be completed. Please try again.';
  }
}
