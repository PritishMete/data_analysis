import 'package:flutter/material.dart';

import '../../core/auth/insightflow_auth_service.dart';
import '../../app_colors.dart';
import 'auth_glass_widgets.dart';
import '../dashboard/data_screen.dart';
import 'sign_in_screen.dart';

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder(
      stream: InsightFlowAuthService.authStateChanges,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const _AuthLoading();
        }

        if (snapshot.hasError) {
          return const _AuthError();
        }

        if (snapshot.data == null) {
          return const SignInScreen();
        }

        return const DataScreen();
      },
    );
  }
}

class _AuthLoading extends StatelessWidget {
  const _AuthLoading();

  @override
  Widget build(BuildContext context) {
    return const AuthGlassScaffold(
      title: 'AUTH / INITIALIZING',
      subtitle: 'CONNECTING TO FIREBASE AUTHENTICATION',
      children: [
        Center(
          child: CircularProgressIndicator(
            strokeWidth: 1.8,
            color: TechColors.borderActive,
          ),
        ),
      ],
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError();

  @override
  Widget build(BuildContext context) {
    return const AuthGlassScaffold(
      title: 'AUTH / ERROR',
      subtitle: 'AUTHENTICATION CHANNEL UNAVAILABLE',
      children: [
        AuthGlassMessage(
          text: 'Authentication could not be initialized. Please reload the add-in.',
        ),
      ],
    );
  }
}
