import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'dart:typed_data';

import 'package:liquid_glass_widgets/core/services/powerbi_detail_analysis_service.dart';

void main() {
  test('rejects synthetic datasets before any remote Power BI upload', () async {
    final service = PowerBiDetailAnalysisService();
    final fixture = PlatformFile(
      name: 'synthetic_customers.csv',
      size: 22,
      bytes: Uint8List.fromList('id,name\n1,synthetic'.codeUnits),
    );

    await expectLater(
      service.analyze([fixture]),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('local-only'),
        ),
      ),
    );
  });
}
