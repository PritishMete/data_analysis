import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all requested primary screens use the shared background architecture', () {
    final sources = <String, String>{
      'login': File('lib/features/auth/sign_in_screen.dart').readAsStringSync(),
      'sign up': File('lib/features/auth/sign_up_screen.dart').readAsStringSync(),
      'onboarding': File('lib/features/auth/organization_onboarding_screen.dart').readAsStringSync(),
      'company registration': File('lib/features/auth/company_registration_screen.dart').readAsStringSync(),
      'management': File('lib/features/auth/management_shell.dart').readAsStringSync(),
    };

    final colors = File('lib/app_colors.dart').readAsStringSync();
    expect(colors, contains('const Color kAppBackgroundColor = Color(0xFF22D3EE);'));

    final authShell = File('lib/features/auth/auth_glass_widgets.dart').readAsStringSync();
    expect(authShell, contains('backgroundColor: kAppBackgroundColor'));
    expect(authShell, isNot(contains('AnimatedLiquidAuthBackground')));
    expect(authShell, isNot(contains('RadialGradient')));
    expect(authShell, isNot(contains('canvas.drawCircle')));

    for (final entry in sources.entries) {
      if (entry.key == 'login' ||
          entry.key == 'sign up' ||
          entry.key == 'onboarding' ||
          entry.key == 'company registration') {
        expect(entry.value, contains('AuthGlassScaffold'), reason: entry.key);
      } else {
        expect(
          entry.value,
          contains('backgroundColor: kAppBackgroundColor'),
          reason: entry.key,
        );
      }
    }

    final techBackground = File('lib/tech_background.dart').readAsStringSync();
    expect(techBackground, contains('ColoredBox(color: kAppBackgroundColor)'));

    final dataScreen = File('lib/features/dashboard/data_screen.dart').readAsStringSync();
    expect(dataScreen, contains('backgroundColor: Colors.transparent'));
    expect(dataScreen, contains('DataScreenTechBackground'));
    expect(techBackground, contains('Color(0xFF080B14)'));
    expect(techBackground, contains('Color(0xFF0F111A)'));
    expect(techBackground, contains('Color(0xFF0A0E1A)'));
    expect(techBackground, contains('Duration(seconds: 22)'));
    expect(techBackground, contains('BlendMode.plus'));
    expect(techBackground, contains('alpha: 0.18'));
    expect(colors, contains('brandDarkBlue = Color(0xFF123A8C)'));
    expect(colors, contains('brandBlue = Color(0xFF2E6FF2)'));
    expect(colors, contains('brandGraphite = Color(0xFF6E6E76)'));

    final scan = File('lib/features/dashboard/analyze_fab.dart').readAsStringSync();
    expect(scan, contains('static const Color _accent = kAppBackgroundColor;'));
  });
}
