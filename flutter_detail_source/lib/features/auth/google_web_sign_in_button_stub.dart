import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

class GoogleWebSignInButton extends StatelessWidget {
  const GoogleWebSignInButton({super.key, required this.enabled, required this.onStarted, required this.onAuthenticated, required this.onError});
  final bool enabled;
  final VoidCallback onStarted;
  final Future<void> Function(GoogleSignInAccount account) onAuthenticated;
  final ValueChanged<Object> onError;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
