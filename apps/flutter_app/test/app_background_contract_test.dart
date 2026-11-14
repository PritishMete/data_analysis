import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one historical TechAnimatedBackground is shared across application screens', () {
    final root = Directory('lib');
    final sharedBackground = File('lib/tech_background.dart').readAsStringSync();
    final dataScreen = File('lib/features/dashboard/data_screen.dart').readAsStringSync();
    final authShell =
        File('lib/features/auth/auth_glass_widgets.dart').readAsStringSync();
    final management =
        File('lib/features/auth/management_shell.dart').readAsStringSync();
    final authorization = File(
      'lib/features/auth/authorization_management_screen.dart',
    ).readAsStringSync();

    expect(sharedBackground,
        contains('class TechAnimatedBackground extends StatefulWidget'));
    for (final token in [
      'Color(0xFF080B14)',
      'Color(0xFF0F111A)',
      'Color(0xFF0A0E1A)',
      'TechColors.borderActive',
      'TechColors.statusBlue',
      'TechColors.statusGreen',
      'Duration(seconds: 22)',
      'alpha: 0.18',
      'alpha: 0.0',
      'BlendMode.plus',
      'size.shortestSide * radiusFactor',
      '0.50',
      '0.42',
      '0.38',
      '0.15 + 0.07 * math.sin(t * 0.8)',
      '0.20 + 0.06 * math.cos(t * 0.7)',
      '0.82 + 0.05 * math.cos(t * 1.1)',
      '0.65 + 0.07 * math.sin(t * 0.9)',
      '0.45 + 0.09 * math.sin(t * 0.6 + 1.5)',
      '0.88 + 0.04 * math.cos(t * 1.2)',
      'GlassAccessibilityData.of(context).reduceMotion',
    ]) {
      expect(sharedBackground, contains(token), reason: token);
    }
    expect(sharedBackground, isNot(contains('TechColors.brandDarkBlue')));
    expect(sharedBackground, isNot(contains('TechColors.brandBlue')));
    expect(sharedBackground, isNot(contains('TechColors.brandGraphite')));
    expect(sharedBackground, isNot(contains('0xFF123A8C')));
    expect(sharedBackground, isNot(contains('0xFF2E6FF2')));
    expect(sharedBackground, isNot(contains('0xFF6E6E76')));

    expect(dataScreen, contains("import '../../tech_background.dart';"));
    expect(dataScreen, contains('child: const TechAnimatedBackground()'));
    expect(dataScreen, isNot(contains('DataScreenTechBackground')));
    expect(dataScreen, contains('CORE // DATA-ENGINE'));
    expect(dataScreen, contains('TechColors.panelGlass'));

    expect(authShell, contains('GlassBackgroundSource'));
    expect(authShell, contains('TechAnimatedBackground'));
    expect(authShell, contains('backgroundColor: Colors.transparent'));
    expect(management, contains('GlassBackgroundSource'));
    expect(management, contains('TechAnimatedBackground'));
    expect(authorization, contains('GlassBackgroundSource'));
    expect(authorization, contains('TechAnimatedBackground'));

    for (final path in [
      'lib/features/auth/sign_in_screen.dart',
      'lib/features/auth/sign_up_screen.dart',
      'lib/features/auth/company_registration_screen.dart',
      'lib/features/auth/employee_profile_onboarding_screen.dart',
      'lib/features/auth/organization_onboarding_screen.dart',
    ]) {
      expect(File(path).readAsStringSync(), contains('AuthGlassScaffold'),
          reason: path);
    }

    // AnalysisScreen is rendered inside DataScreen's shared-background stack.
    final analysis = File('lib/features/analysis/analysis_screen.dart')
        .readAsStringSync();
    expect(analysis, contains('DataScreenState state'));

    // There must not be a second screen-specific animation source.
    expect(
      File('lib/features/dashboard/data_screen_tech_background.dart')
          .existsSync(),
      isFalse,
    );
    final dartFiles = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in dartFiles) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('DataScreenTechBackground')),
          reason: file.path);
    }

    final techColors = File('lib/app_colors.dart').readAsStringSync();
    for (final token in [
      'borderActive = Color(0xFF00E5FF)',
      'statusBlue   = Color(0xFF3399FF)',
      'statusGreen  = Color(0xFF00FF66)',
      'thickness: 22',
      'blur: 16',
      'glassColor: Color(0x1A00E5FF)',
      'thickness: 14',
      'blur: 8',
      'glassColor: Color(0x0F00E5FF)',
      'thickness: 10',
      'blur: 4',
      'glassColor: Color(0x0A00E5FF)',
    ]) {
      expect(techColors, contains(token), reason: token);
    }

    final nav =
        File('lib/features/dashboard/navigation_tabs.dart').readAsStringSync();
    expect(nav, contains('isRunningInsideOffice'));
    expect(nav, contains('GlassQuality.minimal'));
    expect(nav, contains('GlassQuality.premium'));

    final scan =
        File('lib/features/dashboard/analyze_fab.dart').readAsStringSync();
    expect(scan, contains('static const double _size = 56;'));
    expect(scan, contains('state.analyzeData'));
  });
}
