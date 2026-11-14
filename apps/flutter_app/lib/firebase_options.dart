import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

/// Firebase Web configuration for InsightFlow.
///
/// The values are Firebase Web-app identifiers, not service-account secrets.
/// They are supplied at build time so no private credential is stored in the
/// repository. Prefer running `flutterfire configure` to generate the
/// equivalent file for the registered Web app.
class DefaultFirebaseOptions {
  static const _apiKey = String.fromEnvironment('INSIGHTFLOW_FIREBASE_WEB_API_KEY');
  static const _appId = String.fromEnvironment('INSIGHTFLOW_FIREBASE_WEB_APP_ID');
  static const _messagingSenderId =
      String.fromEnvironment('INSIGHTFLOW_FIREBASE_WEB_MESSAGING_SENDER_ID');
  static const _projectId =
      String.fromEnvironment('INSIGHTFLOW_FIREBASE_WEB_PROJECT_ID');
  static const _authDomain =
      String.fromEnvironment('INSIGHTFLOW_FIREBASE_WEB_AUTH_DOMAIN');

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: _apiKey,
    appId: _appId,
    messagingSenderId: _messagingSenderId,
    projectId: _projectId,
    authDomain: _authDomain,
  );

  static FirebaseOptions get currentPlatform {
    if (!kIsWeb) {
      throw UnsupportedError(
        'InsightFlow Firebase configuration is currently provisioned for Web only.',
      );
    }
    final missing = <String>[];
    if (_apiKey.isEmpty) missing.add('apiKey');
    if (_appId.isEmpty) missing.add('appId');
    if (_messagingSenderId.isEmpty) missing.add('messagingSenderId');
    if (_projectId.isEmpty) missing.add('projectId');
    if (_authDomain.isEmpty) missing.add('authDomain');
    if (missing.isNotEmpty || _projectId != 'insightflow-5a23d') {
      throw StateError(
        'InsightFlow Firebase Web configuration is missing or targets the wrong Firebase project.',
      );
    }
    return web;
  }
}
