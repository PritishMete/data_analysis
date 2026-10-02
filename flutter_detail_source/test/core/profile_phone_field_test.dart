import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../lib/core/profile/profile_form_widgets.dart';

void main() {
  testWidgets('profile phone row has exactly two controls with compact code width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TextEditingController();
    addTearDown(controller.dispose);

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
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: Row(
                  key: const Key('phone-controls-row'),
                  children: [
                    Expanded(
                      flex: 1,
                      child: ProfileSelectField(
                        label: 'COUNTRY CODE *',
                        value: 'India  +91',
                        placeholder: 'Select calling code',
                        onTap: () {},
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 2,
                      child: ProfileTextField(
                        controller: controller,
                        label: 'Phone Number',
                        placeholder: 'Phone number',
                        keyboardType: TextInputType.phone,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final row = tester.widget<Row>(find.byKey(const Key('phone-controls-row')));
    expect(row.children, hasLength(3));
    expect(find.byType(ProfileSelectField), findsOneWidget);
    expect(find.byType(ProfileTextField), findsOneWidget);
    expect(find.byType(ProfileFloatingLabelField), findsNothing);

    final countryBox = tester.renderObject<RenderBox>(
      find.byType(ProfileSelectField),
    );
    final phoneBox = tester.renderObject<RenderBox>(
      find.byType(ProfileTextField),
    );
    expect(countryBox.size.width, closeTo(196.7, 2));
    expect(phoneBox.size.width, closeTo(393.3, 2));
    expect(phoneBox.size.width, greaterThan(countryBox.size.width * 1.9));
  });

  testWidgets('phone hint stays inside the standard input', (tester) async {
    await tester.binding.setSurfaceSize(const Size(480, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = TextEditingController();
    addTearDown(controller.dispose);

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
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: ProfileTextField(
              controller: controller,
              label: 'Phone Number',
              placeholder: 'Phone number',
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Phone number'), findsOneWidget);
    expect(find.byType(ProfileFloatingLabelField), findsNothing);
    expect(find.byType(AnimatedPositioned), findsNothing);
  });
}
