import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../lib/core/profile/profile_form_widgets.dart';

void main() {
  Future<void> pumpField(
    WidgetTester tester, {
    String initialText = '',
  }) async {
    final controller = TextEditingController(text: initialText);
    addTearDown(controller.dispose);

    await tester.binding.setSurfaceSize(const Size(640, 240));
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
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            backgroundColor: Color(0xFF10121A),
            body: Center(
              child: SizedBox(
                width: 360,
                child: ProfileFloatingLabelField(
                  controller: controller,
                  label: 'Phone number',
                  placeholder: 'Enter phone number',
                  keyboardType: TextInputType.phone,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('phone and country controls stay side by side with compact code width', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(720, 240));
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
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 600,
                child: Row(
                  key: const Key('phone-row'),
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
                    Expanded(
                      flex: 3,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 12),
                        child: ProfileFloatingLabelField(
                          controller: TextEditingController(),
                          label: 'Phone number',
                          placeholder: 'Enter phone number',
                        ),
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

    final row = tester.widget<Row>(find.byKey(const Key('phone-row')));
    expect(row.children, hasLength(2));
    expect(find.byType(ProfileSelectField), findsOneWidget);
    expect(find.byType(ProfileFloatingLabelField), findsOneWidget);

    final countryBox = tester.renderObject<RenderBox>(
      find.byType(ProfileSelectField),
    );
    final phoneBox = tester.renderObject<RenderBox>(
      find.byType(ProfileFloatingLabelField),
    );
    expect(countryBox.size.width, closeTo(150, 1));
    expect(phoneBox.size.width, greaterThan(countryBox.size.width * 2));
  });

  testWidgets('phone label starts inside the field', (tester) async {
    await pumpField(tester);

    expect(find.text('Phone number'), findsOneWidget);
    final labelPosition = tester.widget<AnimatedPositioned>(
      find.byType(AnimatedPositioned),
    );
    expect(labelPosition.top, 13);
  });

  testWidgets('focus floats the phone label to the top border', (tester) async {
    await pumpField(tester);

    final field = find.byType(ProfileFloatingLabelField);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 180));

    final labelPosition = tester.widget<AnimatedPositioned>(
      find.byType(AnimatedPositioned),
    );
    expect(labelPosition.top, -7);
  });

  testWidgets('filled and unfocused phone field keeps the label floated', (
    tester,
  ) async {
    await pumpField(tester);

    final field = find.byType(ProfileFloatingLabelField);
    await tester.tap(field);
    await tester.enterText(find.byType(TextField), '9876543210');
    await tester.pump(const Duration(milliseconds: 180));
    await tester.tapAt(const Offset(620, 220));
    await tester.pump(const Duration(milliseconds: 180));

    final labelPosition = tester.widget<AnimatedPositioned>(
      find.byType(AnimatedPositioned),
    );
    expect(labelPosition.top, -7);
  });

  testWidgets('empty and unfocused phone field returns the label inside', (
    tester,
  ) async {
    await pumpField(tester);

    final field = find.byType(ProfileFloatingLabelField);
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 180));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 180));

    final labelPosition = tester.widget<AnimatedPositioned>(
      find.byType(AnimatedPositioned),
    );
    expect(labelPosition.top, 13);
  });
}
