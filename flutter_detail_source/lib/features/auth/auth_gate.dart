import 'package:flutter/cupertino.dart';

import '../../core/auth/insightflow_auth_service.dart';
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
    return const CupertinoPageScaffold(
      child: Center(
        child: CupertinoActivityIndicator(radius: 14),
      ),
    );
  }
}

class _AuthError extends StatelessWidget {
  const _AuthError();

  @override
  Widget build(BuildContext context) {
    return const CupertinoPageScaffold(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Authentication could not be initialized. Please reload the add-in.',
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
