import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Data Screen uses its historical background without changing shared screens', () {
    final sharedScreens = <String, String>{
      'login': File('lib/features/auth/sign_in_screen.dart').readAsStringSync(),
      'sign up': File('lib/features/auth/sign_up_screen.dart').readAsStringSync(),
      'onboarding': File('lib/features/auth/organization_onboarding_screen.dart').readAsStringSync(),
      'company registration': File('lib/features/auth/company_registration_screen.dart').readAsStringSync(),
      'management': File('lib/features/auth/management_shell.dart').readAsStringSync(),
    };

    final colors = File('lib/app_colors.dart').readAsStringSync();
    expect(colors, contains('const Color kAppBackgroundColor = Color(0xFF22D3EE);'));
    for (final entry in sharedScreens.entries) {
      if (entry.key == 'login' ||
          entry.key == 'sign up' ||
          entry.key == 'onboarding' ||
          entry.key == 'company registration') {
        expect(entry.value, contains('AuthGlassScaffold'), reason: entry.key);
      } else {
        expect(entry.value, contains('TechAnimatedBackground'), reason: entry.key);
      }
    }

    final authShell = File('lib/features/auth/auth_glass_widgets.dart').readAsStringSync();
    expect(authShell, contains('backgroundColor: Colors.transparent'));
    expect(authShell, contains('GlassBackgroundSource'));
    expect(authShell, contains('TechAnimatedBackground'));
    expect(authShell, isNot(contains('AnimatedLiquidAuthBackground')));
    expect(authShell, isNot(contains('RadialGradient')));
    expect(authShell, isNot(contains('canvas.drawCircle')));

    final sharedBackground = File('lib/tech_background.dart').readAsStringSync();
    expect(sharedBackground, contains('class TechAnimatedBackground extends StatefulWidget'));
    expect(sharedBackground, contains('TechColors.brandDarkBlue'));
    expect(sharedBackground, contains('TechColors.brandBlue'));
    expect(sharedBackground, contains('TechColors.brandGraphite'));
    expect(sharedBackground, contains('Duration(seconds: 22)'));
    expect(sharedBackground, contains('BlendMode.plus'));

    final dataScreen = File('lib/features/dashboard/data_screen.dart').readAsStringSync();
    expect(dataScreen, contains('DataScreenTechBackground'));
    expect(dataScreen, isNot(contains('TechAnimatedBackground')));
    expect(dataScreen, contains('CORE // DATA-ENGINE'));
    expect(dataScreen, contains('TechColors.panelGlass'));

    final historicalBackground =
        File('lib/features/dashboard/data_screen_tech_background.dart').readAsStringSync();
    for (final color in [
      'Color(0xFF080B14)',
      'Color(0xFF0F111A)',
      'Color(0xFF0A0E1A)',
      'TechColors.borderActive',
      'TechColors.statusBlue',
      'TechColors.statusGreen',
    ]) {
      expect(historicalBackground, contains(color));
    }
    expect(historicalBackground, contains('Duration(seconds: 22)'));
    expect(historicalBackground, contains('alpha: 0.18'));
    expect(historicalBackground, contains('BlendMode.plus'));
    expect(historicalBackground, contains('0.15 + 0.07 * math.sin(t * 0.8)'));
    expect(historicalBackground, contains('0.82 + 0.05 * math.cos(t * 1.1)'));
    expect(historicalBackground, contains('0.45 + 0.09 * math.sin(t * 0.6 + 1.5)'));

    final scan = File('lib/features/dashboard/analyze_fab.dart').readAsStringSync();
    expect(scan, contains('static const double _size = 56;'));
    expect(scan, contains('state.analyzeData'));
  });
}
