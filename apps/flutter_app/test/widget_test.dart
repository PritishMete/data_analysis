import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/star_schema_view.dart';

void main() {
  testWidgets('Detail Analysis star schema renders its native shell', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SingleChildScrollView(child: StarSchemaView(schema: {
      'fact_tables': [
        {'display_name': 'Fact Sales', 'grain': 'one event row', 'measures': ['amount']},
      ],
      'dimensions': [
        {'id': 'dim_1', 'display_name': 'Dim Product', 'key': 'product_id', 'attributes': ['name']},
      ],
      'relationships': [
        {'from': 'dim_1', 'status': 'valid', 'cardinality': 'one_to_many'},
      ],
    }))));

    expect(find.text('Fact Sales'), findsOneWidget);
    expect(find.text('FACT TABLE'), findsOneWidget);
    expect(find.text('Dim Product'), findsOneWidget);
  });
}
