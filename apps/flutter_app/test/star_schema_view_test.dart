import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/star_schema_view.dart';

Map<String, dynamic> schema({int dimensionCount = 4}) {
  final dimensions = List.generate(dimensionCount, (index) {
    final role = switch (index) {
      0 => 'time',
      1 => 'customer',
      2 => 'product',
      3 => 'geography',
      _ => 'category',
    };
    final id = 'dim_${index + 1}';
    return {
      'id': id,
      'display_name': 'Dimension $index',
      'semantic_role': role,
      'key': 'key_$index',
      'attributes': ['attribute_$index'],
      'derived': index == 0,
      'derived_from': 'event_date',
      'quality_status': index == 1 ? 'requires_key_cleanup' : 'valid',
    };
  });
  return {
    'fact_tables': [
      {
        'id': 'fact_1',
        'display_name': 'Fact Sales',
        'grain': 'one event row',
        'business_key': ['event_id'],
        'foreign_keys': ['key_0', 'key_1'],
        'measures': ['amount'],
      },
    ],
    'dimensions': dimensions,
    'relationships': dimensions.map((dimension) => {
      'from': dimension['id'],
      'to': 'fact_1',
      'cardinality': 'one_to_many',
      'status': dimension['id'] == 'dim_2' ? 'requires_key_cleanup' : 'valid',
      'null_fk_count': 0,
      'orphan_count': 0,
    }).toList(),
  };
}

void main() {
  testWidgets('renders reusable fact and dimension content', (tester) async {
    await tester.pumpWidget(_host(StarSchemaView(schema: schema())));

    expect(find.text('Fact Sales'), findsOneWidget);
    expect(find.text('FACT TABLE'), findsOneWidget);
    expect(find.text('Dimension 0'), findsOneWidget);
    expect(find.text('DIMENSION'), findsNWidgets(3));
    expect(find.text('DERIVED DIMENSION'), findsOneWidget);
    expect(find.text('Warning: key cleanup required'), findsOneWidget);
  });

  for (final count in [1, 2, 3, 4, 5, 9]) {
    testWidgets('supports $count dimensions without changing the contract', (tester) async {
      await tester.pumpWidget(_host(StarSchemaView(schema: schema(dimensionCount: count))));
      expect(find.byKey(const ValueKey('star-schema-desktop-layout')), findsOneWidget);
      expect(find.text('Fact Sales'), findsOneWidget);
    });
  }

  testWidgets('uses narrow vertical fallback', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(StarSchemaView(schema: schema(dimensionCount: 2))));

    expect(find.byKey(const ValueKey('star-schema-narrow-layout')), findsOneWidget);
    expect(find.byKey(const ValueKey('star-schema-desktop-layout')), findsNothing);
  });

  testWidgets('keeps the fact centered and schema nodes separated', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(StarSchemaView(schema: schema())));

    final fact = tester.getRect(find.byKey(const ValueKey('fact-card')));
    final time = tester.getRect(find.byKey(const ValueKey('dimension-card-dim_1')));
    final customer = tester.getRect(find.byKey(const ValueKey('dimension-card-dim_2')));
    final product = tester.getRect(find.byKey(const ValueKey('dimension-card-dim_3')));
    final geography = tester.getRect(find.byKey(const ValueKey('dimension-card-dim_4')));
    expect((fact.center.dx - 600).abs(), lessThan(2));
    expect(time.bottom, lessThan(fact.top));
    expect(customer.right, lessThan(fact.left));
    expect(product.left, greaterThan(fact.right));
    expect(geography.top, greaterThan(fact.bottom));
    final nodes = [fact, time, customer, product, geography];
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        expect(nodes[i].overlaps(nodes[j]), isFalse);
      }
    }
  });

  testWidgets('keeps legend above the diagram and modeling notes below it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_host(StarSchemaView(schema: schema())));

    final legend = tester.getTopLeft(find.textContaining('Legend:'));
    final diagram = tester.getTopLeft(find.byKey(const ValueKey('star-schema-desktop-layout')));
    final notes = tester.getTopLeft(find.text('Modeling notes'));
    expect(legend.dy, lessThan(diagram.dy));
    expect(notes.dy, greaterThan(diagram.dy + 700));
  });
}

Widget _host(Widget child) => MaterialApp(
      home: SingleChildScrollView(child: child),
    );
