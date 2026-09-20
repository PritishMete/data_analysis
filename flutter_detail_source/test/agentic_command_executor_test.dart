import 'package:flutter_test/flutter_test.dart';

import '../lib/core/services/currency_registry.dart';
import '../lib/core/services/agentic_command_executor.dart';
import '../lib/core/security/outbound_privacy_guard.dart';
import '../lib/core/services/local_llm_service.dart';

void main() {
  test('categorize country column is routed as categorization in secure local mode', () async {
    final parsed = await parseAgenticCommand(
      userText: 'categorize country column',
      availableColumns: const [],
      availableSheets: const ['Sheet1'],
    );

    expect(parsed['action'], 'categorize');
    expect(parsed['confidence'], greaterThanOrEqualTo(0.9));
    expect(parsed['categorize'], isA<Map>());
  });

  test('categorize all columns is routed as categorization in secure local mode', () async {
    final parsed = await parseAgenticCommand(
      userText: 'categorize all columns',
      availableColumns: const ['Country', 'City', 'Rating'],
      availableSheets: const ['Sheet1'],
    );

    expect(parsed['action'], 'categorize');
    expect(parsed['confidence'], greaterThanOrEqualTo(0.9));

    final categorize = Map<String, dynamic>.from(parsed['categorize'] as Map);
    expect(categorize['allColumns'], isTrue);
    expect(categorize['sourceColumns'], isA<List>());
  });

  test('combined categorize and convert command keeps conversion separate from categorization', () async {
    final parsed = await parseAgenticCommand(
      userText: 'categorize columns and convert currency to INR',
      availableColumns: const ['Country', 'Currency', 'Rating'],
      availableSheets: const ['Sheet1'],
    );

    expect(parsed['action'], 'categorize');
    final categorize = Map<String, dynamic>.from(parsed['categorize'] as Map);
    expect(categorize['allColumns'], isTrue);
    expect(categorize.containsKey('targetCurrency'), isFalse);
  });

  test('explicit PivotTable request is classified locally with total cost measure', () async {
    final parsed = await parseAgenticCommand(
      userText: 'create a pivot table of total cost by cuisine',
      availableColumns: const ['Cuisine', 'Cost', 'Rating'],
      availableSheets: const ['Restaurants', 'Quality_Report'],
    );

    expect(parsed['action'], 'pivot');
    expect(parsed['confidence'], greaterThanOrEqualTo(0.9));
    expect(parsed['needsClarification'], isNot(true));

    final pivot = Map<String, dynamic>.from(parsed['pivot'] as Map);
    expect(pivot['rowFields'], ['Cuisine']);
    final values = List<Map<String, dynamic>>.from(
      (pivot['valueFields'] as List).map((v) => Map<String, dynamic>.from(v as Map)),
    );
    expect(values.single['field'], 'Cost');
    expect(values.single['op'], 'sum');
  });

  test('top PivotTable request preserves descending limit and stays local', () async {
    final parsed = await parseAgenticCommand(
      userText: 'show top 5 cuisines in a pivot table by total cost',
      availableColumns: const ['Cuisine', 'Cost', 'Rating'],
      availableSheets: const ['Restaurants', 'Quality_Report'],
    );

    expect(parsed['action'], 'pivot');
    final pivot = Map<String, dynamic>.from(parsed['pivot'] as Map);
    expect(pivot['rowFields'], ['Cuisine']);
    expect(pivot['limit'], 5);
    expect(pivot['sortByValue'], 'descending');
  });

  test('query PivotTable preserves explicit marked_price measure', () async {
    final parsed = await parseAgenticCommand(
      userText: 'Create a pivot table showing total marked_price by product_name',
      availableColumns: const ['product_name', 'brand_name', 'marked_price', 'discounted_price'],
      availableSheets: const ['Products'],
    );

    expect(parsed['action'], 'pivot');
    expect(parsed['needsClarification'], isNot(true));
    final pivot = Map<String, dynamic>.from(parsed['pivot'] as Map);
    expect(pivot['rowFields'], ['product_name']);
    final values = List<Map<String, dynamic>>.from(
      (pivot['valueFields'] as List).map((v) => Map<String, dynamic>.from(v as Map)),
    );
    expect(values.single, {'field': 'marked_price', 'op': 'sum'});
  });

  test('query PivotTable resolves spaced discounted price to exact header', () async {
    final parsed = await parseAgenticCommand(
      userText: 'Create a pivot table with brand_name as rows and discounted price as values using AVERAGE',
      availableColumns: const ['product_name', 'brand_name', 'marked_price', 'discounted_price'],
      availableSheets: const ['Products'],
    );

    expect(parsed['action'], 'pivot');
    final pivot = Map<String, dynamic>.from(parsed['pivot'] as Map);
    expect(pivot['rowFields'], ['brand_name']);
    final values = List<Map<String, dynamic>>.from(
      (pivot['valueFields'] as List).map((v) => Map<String, dynamic>.from(v as Map)),
    );
    expect(values.single, {'field': 'discounted_price', 'op': 'average'});
  });

  test('query PivotTable preserves row columns and sum value contract', () async {
    final parsed = await parseAgenticCommand(
      userText: 'Create a pivot table with category as rows, brand_name as columns, and sum of marked_price as values',
      availableColumns: const ['category', 'brand_name', 'marked_price', 'discounted_price'],
      availableSheets: const ['Products'],
    );

    expect(parsed['action'], 'pivot');
    final pivot = Map<String, dynamic>.from(parsed['pivot'] as Map);
    expect(pivot['rowFields'], ['category']);
    expect(pivot['columnFields'], ['brand_name']);
    final values = List<Map<String, dynamic>>.from(
      (pivot['valueFields'] as List).map((v) => Map<String, dynamic>.from(v as Map)),
    );
    expect(values.single, {'field': 'marked_price', 'op': 'sum'});
  });

  test('generic price PivotTable request asks for clarification when price columns conflict', () async {
    final parsed = await parseAgenticCommand(
      userText: 'Create a pivot table showing total price by product_name',
      availableColumns: const ['product_name', 'marked_price', 'discounted_price'],
      availableSheets: const ['Products'],
    );

    expect(parsed['action'], 'pivot');
    expect(parsed['needsClarification'], isTrue);
    expect(parsed['message'].toString(), contains('ambiguous'));
    final pivot = Map<String, dynamic>.from(parsed['pivot'] as Map);
    expect(pivot['candidates'], ['marked_price', 'discounted_price']);
  });

  test('underspecified top cuisines request asks for a ranking measure', () async {
    final parsed = await parseAgenticCommand(
      userText: 'create a pivot table to show top cuisines',
      availableColumns: const ['Cuisine', 'Cost', 'Rating'],
      availableSheets: const ['Restaurants', 'Quality_Report'],
    );

    expect(parsed['action'], 'pivot');
    expect(parsed['needsClarification'], isTrue);
    expect(parsed['message'].toString(), contains('count'));
    expect(parsed['message'].toString(), contains('total cost'));
    expect(parsed['message'].toString(), contains('average rating'));
  });

  test('target currency aliases resolve to ISO codes and symbols', () {
    expect(resolveTargetCurrency('convert currency to rupee'), 'INR');
    expect(resolveTargetCurrency('convert currency to rupees'), 'INR');
    expect(resolveTargetCurrency('convert currency to Indian rupee'), 'INR');
    expect(resolveTargetCurrency('convert currency to ₹'), 'INR');
    expect(resolveTargetCurrency('convert currency to USD'), 'USD');
    expect(resolveTargetCurrency('convert currency to dollar'), 'USD');
    expect(resolveTargetCurrency('convert currency to €'), 'EUR');
    expect(resolveTargetCurrency('convert currency to GBP'), 'GBP');
    expect(resolveTargetCurrency('convert currency to ¥'), 'JPY');
    expect(currencySymbolForCode('INR'), '₹');
    expect(currencySymbolForCode('USD'), r'$');
    expect(currencyNumberFormatForCode('INR'), '₹#,##0.00');
    expect(currencyNumberFormatForCode('JPY'), '¥#,##0');
  });

  test('local llm provider defaults to localhost only', () {
    final provider = createLocalLlmProvider();
    expect(provider, isNotNull);
    expect(provider is HttpLocalLlmProvider, isTrue);
    final httpProvider = provider as HttpLocalLlmProvider;
    expect(httpProvider.endpoint.host.toLowerCase(), anyOf('127.0.0.1', 'localhost', '::1'));
  });

  test('outbound privacy guard rejects nested workbook payloads', () {
    expect(
      () => OutboundPrivacyGuard.validateMetadataOnlyPayload({
        'text': 'filter',
        'context': {
          'nested': [
            {'rows': [{'Country': 'India'}]},
          ],
        },
      }),
      throwsA(isA<StateError>()),
    );
  });

  test('outbound privacy guard can redact workbook values with placeholders', () {
    final sanitized = OutboundPrivacyGuard.replaceTokens(
      'show Subway restaurant with delivery',
      {'Subway': 'ENTITY_001'},
    );

    expect(sanitized, contains('ENTITY_001'));
    expect(sanitized, isNot(contains('Subway')));
  });
}
