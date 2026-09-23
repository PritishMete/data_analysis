import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import 'package:liquid_glass_widgets/features/auth/sign_in_screen.dart';
import 'package:liquid_glass_widgets/features/auth/sign_up_screen.dart';

void main() {
  Future<void> pumpAuthApp(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(330, 556),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      LiquidGlassWidgets.wrap(
        theme: GlassThemeData(
          brightness: Brightness.dark,
          dark: const GlassThemeVariant(
            settings: GlassThemeSettings(
              glassColor: Color(0x1FFFFFFF),
              thickness: 20,
              blur: 14,
              refractiveIndex: 0.9,
              saturation: 1.2,
              ambientStrength: 0.4,
              lightIntensity: 0.8,
            ),
            quality: GlassQuality.minimal,
          ),
        ),
        child: CupertinoApp(
          theme: const CupertinoThemeData(brightness: Brightness.dark),
          home: child,
        ),
      ),
    );

    await tester.pump();
  }

  testWidgets('sign in uses shared glass fields and remains narrow-pane safe', (
    tester,
  ) async {
    await pumpAuthApp(tester, const SignInScreen());

    expect(find.text('InsightFlow'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.byType(GlassTextField), findsNWidgets(2));
    expect(find.byType(GlassPasswordField), findsOneWidget);
    expect(find.text('EMAIL'), findsOneWidget);
    expect(find.text('PASSWORD'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    expect(find.text('Forgot password?'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shared password field keeps show/hide interaction', (
    tester,
  ) async {
    await pumpAuthApp(tester, const SignInScreen());

    expect(find.byIcon(CupertinoIcons.eye_slash_fill), findsOneWidget);
    await tester.tap(find.byIcon(CupertinoIcons.eye_slash_fill));
    await tester.pump();

    expect(find.byIcon(CupertinoIcons.eye_fill), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('sign up uses shared glass fields and scrolls in narrow pane', (
    tester,
  ) async {
    await pumpAuthApp(tester, const SignUpScreen());

    expect(find.text('Create account'), findsOneWidget);
    expect(find.byType(GlassPasswordField), findsNWidgets(2));
    expect(find.byType(GlassTextField), findsNWidgets(4));
    expect(find.text('FULL NAME'), findsOneWidget);
    expect(find.text('EMAIL'), findsOneWidget);
    expect(find.text('PASSWORD'), findsOneWidget);
    expect(find.text('CONFIRM PASSWORD'), findsOneWidget);
    expect(find.text('Create Account'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
