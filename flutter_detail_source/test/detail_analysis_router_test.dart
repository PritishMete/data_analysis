import 'package:flutter_test/flutter_test.dart';

import 'package:liquid_glass_widgets/detail_analysis_router.dart';

void main() {
  test('customer quality chat messages retain structured results', () {
    expect(
      shouldAttachDetailAnalysisResult(
        DetailAnalysisIntent.customerDataQuality,
        false,
      ),
      isTrue,
    );
    expect(
      shouldAttachDetailAnalysisResult(
        DetailAnalysisIntent.detailAnalysis,
        false,
      ),
      isFalse,
    );
    expect(
      shouldAttachDetailAnalysisResult(
        DetailAnalysisIntent.detailAnalysis,
        true,
      ),
      isTrue,
    );
    expect(
      shouldAttachDetailAnalysisResult(
        DetailAnalysisIntent.detailAnalysis,
        false,
        isStructuredQuality: true,
      ),
      isTrue,
    );
  });

  test('routes generic business, relationship, and follow-up questions', () {
    final regional = routeDetailAnalysisMessage(
      'Which region is the most profitable?',
    );
    expect(regional.intent, DetailAnalysisIntent.businessAnalysis);
    expect(regional.subIntent, 'regional_profit');

    final individual = routeDetailAnalysisMessage(
      'Which individual region record is most profitable?',
    );
    expect(individual.intent, DetailAnalysisIntent.businessAnalysis);
    expect(individual.subIntent, 'region_member_profit');

    final product = routeDetailAnalysisMessage(
      'Which products have high revenue but low margins?',
    );
    expect(product.intent, DetailAnalysisIntent.businessAnalysis);
    expect(product.subIntent, 'margin_watchlist');

    final monthly = routeDetailAnalysisMessage(
      'How are revenue and profit trending month by month?',
    );
    expect(monthly.intent, DetailAnalysisIntent.businessAnalysis);
    expect(monthly.subIntent, 'monthly_performance');

    final relationship = routeDetailAnalysisMessage(
      'Are there any relationship problems between the datasets?',
    );
    expect(relationship.intent, DetailAnalysisIntent.detailAnalysis);
    expect(relationship.subIntent, 'data_quality:all');

    final followUp = routeDetailAnalysisMessage(
      'How did it perform in 2025?',
      previousRoute: regional,
    );
    expect(followUp.intent, DetailAnalysisIntent.businessAnalysis);
    expect(followUp.subIntent, 'regional_profit');

    final refinement = routeDetailAnalysisMessage(
      'What about Clothing only?',
      previousRoute: followUp,
    );
    expect(refinement.intent, DetailAnalysisIntent.businessAnalysis);
    expect(refinement.subIntent, 'regional_profit');

    final replacement = routeDetailAnalysisMessage(
      'What about 2024?',
      previousRoute: followUp,
    );
    expect(replacement.intent, DetailAnalysisIntent.businessAnalysis);
    expect(replacement.subIntent, 'regional_profit');
  });

  test('routes automatic insight questions to the local business workflow', () {
    for (final query in [
      'Give me the key insights from this business',
      'What should I pay attention to?',
      'Give me the most important insights for 2025',
      'What are the key insights for North in 2025?',
      'Which area has the biggest profitability concern?',
    ]) {
      final route = routeDetailAnalysisMessage(query);
      expect(route.intent, DetailAnalysisIntent.businessAnalysis);
      expect(route.subIntent, 'automatic_insights');
    }
  });

  test('keeps product ranking intent through pronoun and year follow-ups', () {
    final product = routeDetailAnalysisMessage(
      'Which product has the highest revenue?',
    );
    expect(product.intent, DetailAnalysisIntent.businessAnalysis);
    expect(product.subIntent, 'top_products');

    final profitability = routeDetailAnalysisMessage(
      'How profitable is it?',
      previousRoute: product,
    );
    expect(profitability.intent, DetailAnalysisIntent.businessAnalysis);
    expect(profitability.subIntent, 'top_products');

    final year = routeDetailAnalysisMessage(
      'What about in 2025?',
      previousRoute: profitability,
    );
    expect(year.intent, DetailAnalysisIntent.businessAnalysis);
    expect(year.subIntent, 'top_products');
  });

  test('routes natural language profiling requests locally', () {
    for (final text in [
      'analyze the datasets',
      'analyse the datasets',
      'analyze my data',
      'analyze data',
      'analyze these files',
      'give me detail analysis',
      'give me detailed analysis',
      'give detailed analysis',
      'detailed analysis',
      'detail analysis',
      'full analysis',
      'complete analysis',
      'dataset analysis',
      'data analysis',
      'analyze everything',
      'understand the data',
      'understand these datasets',
      'profile the data',
      'profile datasets',
      'data profiling',
      'inspect the datasets',
      'inspect my data',
      'review the datasets',
      'check the datasets',
      'check data quality',
      'tell me about these datasets',
      'what is in this data',
      'what do these datasets contain',
      'GIVE ME DETAIL ANALYSIS.',
      'give me detailed analysis please',
      'Can you analyze these datasets?',
      'please analyze my data',
    ]) {
      expect(
        routeDetailAnalysisMessage(text).intent,
        DetailAnalysisIntent.detailAnalysis,
      );
    }
  });

  test('routes supported cleaning and modeling workflows', () {
    expect(
      routeDetailAnalysisMessage('clean customer data').intent,
      DetailAnalysisIntent.customerCleaning,
    );
    expect(
      routeDetailAnalysisMessage('standardize product categories').intent,
      DetailAnalysisIntent.productCleaning,
    );
    expect(
      routeDetailAnalysisMessage('prepare fact orders').intent,
      DetailAnalysisIntent.orderCleaning,
    );
    expect(
      routeDetailAnalysisMessage('build dim_date').intent,
      DetailAnalysisIntent.dateDimension,
    );
    expect(
      routeDetailAnalysisMessage('show dashboard').intent,
      DetailAnalysisIntent.dashboard,
    );
  });

  test('routes Chapter 6 questions with a contextual sub-intent', () {
    final route = routeDetailAnalysisMessage(
      'Which regions generate the highest profit?',
    );
    expect(route.intent, DetailAnalysisIntent.businessAnalysis);
    expect(route.subIntent, 'regional_profit');
  });

  test('keeps specific business questions ahead of generic analysis', () {
    expect(
      routeDetailAnalysisMessage('analyze monthly revenue').subIntent,
      'monthly_performance',
    );
    expect(
      routeDetailAnalysisMessage('analyze product profitability').subIntent,
      'top_products',
    );
    expect(
      routeDetailAnalysisMessage('show top 10 products by revenue').subIntent,
      'top_products',
    );
    expect(
      routeDetailAnalysisMessage(
        'show high revenue low margin products',
      ).subIntent,
      'margin_watchlist',
    );
  });

  test('routes customer quality questions to profiling, not cleaning', () {
    for (final text in [
      'what are the issues with customer data',
      'what issues are in customer data',
      'show customer data issues',
      'customer data quality issues',
      'check customer data quality',
      'find problems in customer data',
      'what problems are in customers',
      'analyze customer data quality',
      'inspect customer issues',
      'tell me customer data problems',
    ]) {
      final route = routeDetailAnalysisMessage(text);
      expect(route.intent, DetailAnalysisIntent.customerDataQuality);
      expect(route.subIntent, 'data_quality:customer');
    }
    expect(
      routeDetailAnalysisMessage('clean customer data').intent,
      DetailAnalysisIntent.customerCleaning,
    );
    expect(
      routeDetailAnalysisMessage('remove duplicate customers').intent,
      DetailAnalysisIntent.customerCleaning,
    );
  });

  test('generalizes quality analysis across dataset roles', () {
    for (final text in [
      'What is wrong with the orders?',
      'Check product quality.',
      'Any issues in regions?',
    ]) {
      final route = routeDetailAnalysisMessage(text);
      expect(route.intent, DetailAnalysisIntent.detailAnalysis);
      expect(route.subIntent, startsWith('data_quality:'));
    }
  });

  test('resolves short quality follow-ups from local route context', () {
    final customer = routeDetailAnalysisMessage('review customers');
    final followUp = routeDetailAnalysisMessage(
      'what about customers?',
      previousRoute: customer,
    );
    expect(followUp.intent, DetailAnalysisIntent.detailAnalysis);
    expect(followUp.subIntent, 'data_quality:customer');
  });

  test('does not guess unsupported requests', () {
    for (final text in ['hello', 'what can you do?', 'write me a poem']) {
      expect(
        routeDetailAnalysisMessage(text).intent,
        DetailAnalysisIntent.unknown,
      );
    }
  });

  test('routes analytical report commands to the local business workflow', () {
    for (final text in [
      'Generate an executive summary report.',
      'Create a detailed business analysis report.',
      'Generate a report for North in 2025.',
      'Generate a report from the current analysis.',
    ]) {
      final route = routeDetailAnalysisMessage(text);
      expect(route.intent, DetailAnalysisIntent.businessAnalysis);
    }
  });
}
