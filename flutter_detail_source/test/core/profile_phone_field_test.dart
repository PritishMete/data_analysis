import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../lib/core/profile/profile_form_widgets.dart';

void main() {
  testWidgets('phone row uses a compact country code and normal phone input', (
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
                  children: [
                    SizedBox(
                      width: 96,
                      child: ProfileSelectField(
                        label: 'COUNTRY CODE *',
                        value: 'India  +91',
                        placeholder: 'Select calling code',
                        onTap: () {},
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('PHONE NUMBER *'),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 46,
                            child: TextField(
                              controller: controller,
                              keyboardType: TextInputType.phone,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                              ],
                              decoration: const InputDecoration(
                                hintText: 'Phone number',
                              ),
                            ),
                          ),
                        ],
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

    expect(find.byType(ProfileSelectField), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byType(ProfileFloatingLabelField), findsNothing);

    final countryBox = tester.renderObject<RenderBox>(
      find.byType(ProfileSelectField),
    );
    expect(countryBox.size.width, closeTo(96, 1));

    final textField = tester.renderObject<RenderBox>(find.byType(TextField));
    expect(textField.size.height, closeTo(46, 2));
  });
}
