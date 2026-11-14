import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/core/services/business_analysis_context.dart';

void main() {
  test('binds a product selection from the structured local ranking', () {
    final entity = bindSelectedEntityFromResult(
      {
        'top_products_by_revenue': {
          'rows': [
            {'product_id': 'P98', 'product': 'Kids Product 98', 'revenue': 829112.99},
          ],
        },
      },
      requestedGrain: 'product',
      rankingMetric: 'revenue',
    );

    expect(entity, {
      'role': 'product',
      'display_value': 'Kids Product 98',
      'local_key': 'P98',
      'grain': 'product',
      'ranking_metric': 'revenue',
    });
  });

  test('binds a business region using the same structured-result path', () {
    final entity = bindSelectedEntityFromResult(
      {
        'business_region_profit': {
          'rows': [
            {'region': 'North', 'profit': 100.0},
          ],
        },
      },
      requestedGrain: 'business_region',
      rankingMetric: 'profit',
    );

    expect(entity?['role'], 'business_region');
    expect(entity?['display_value'], 'North');
  });

  test('inherits selected product, merges year, replaces year, and resets', () {
    final context = {
      'filters': {'product': 'Kids Product 98', 'product_id': 'P98'},
      'filter_options': {
        'business_region': ['North'],
        'category': ['Clothing'],
        'product': ['Kids Product 98'],
      },
    };

    expect(
      resolveBusinessFiltersFromContext(context, 'How profitable is it?'),
      {'product': 'Kids Product 98', 'product_id': 'P98'},
    );
    expect(
      resolveBusinessFiltersFromContext(context, 'What about in 2025?'),
      {'product': 'Kids Product 98', 'product_id': 'P98', 'year': '2025'},
    );
    final yearContext = {
      ...context,
      'filters': {'product': 'Kids Product 98', 'product_id': 'P98', 'year': '2025'},
    };
    expect(
      resolveBusinessFiltersFromContext(yearContext, 'What about 2024?'),
      {'product': 'Kids Product 98', 'product_id': 'P98', 'year': '2024'},
    );
    expect(
      resolveBusinessFiltersFromContext(yearContext, 'Show overall company performance'),
      isEmpty,
    );
  });
}
