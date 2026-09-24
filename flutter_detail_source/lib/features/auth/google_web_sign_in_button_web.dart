import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:google_sign_in_web/web_only.dart' as google_web;

class GoogleWebSignInButton extends StatefulWidget {
  const GoogleWebSignInButton({super.key, required this.enabled, required this.onStarted, required this.onAuthenticated, required this.onError});

  final bool enabled;
  final VoidCallback onStarted;
  final Future<void> Function(GoogleSignInAccount account) onAuthenticated;
  final ValueChanged<Object> onError;

  @override
  State<GoogleWebSignInButton> createState() => _GoogleWebSignInButtonState();
}

class _GoogleWebSignInButtonState extends State<GoogleWebSignInButton> {
  StreamSubscription<GoogleSignInAuthenticationEvent>? _subscription;
  bool _processing = false;

  @override
  void initState() {
    super.initState();
    _subscription = GoogleSignIn.instance.authenticationEvents.listen(
      (event) async {
        if (event is! GoogleSignInAuthenticationEventSignIn || _processing) return;
        _processing = true;
        widget.onStarted();
        try {
          await widget.onAuthenticated(event.user);
        } catch (error) {
          widget.onError(error);
        } finally {
          _processing = false;
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('[google-authenticate] event error: ' + error.runtimeType.toString());
        debugPrintStack(stackTrace: stackTrace);
        widget.onError(error);
      },
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return const SizedBox(height: 42);
    return SizedBox(
      width: double.infinity,
      height: 42,
      child: google_web.renderButton(
        configuration: google_web.GSIButtonConfiguration(
          type: google_web.GSIButtonType.standard,
          size: google_web.GSIButtonSize.large,
          text: google_web.GSIButtonText.continueWith,
          minimumWidth: 260,
        ),
      ),
    );
  }
}
