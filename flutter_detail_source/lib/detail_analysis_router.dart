enum DetailAnalysisIntent {
  detailAnalysis,
  customerCleaning,
  productCleaning,
  orderCleaning,
  dateDimension,
  businessAnalysis,
  customerDataQuality,
  dashboard,
  unknown,
}

bool shouldAttachDetailAnalysisResult(
  DetailAnalysisIntent intent,
  bool isFullReportQuery, {
  bool isStructuredQuality = false,
}) =>
    isStructuredQuality ||
    intent == DetailAnalysisIntent.customerDataQuality ||
    (intent == DetailAnalysisIntent.detailAnalysis && isFullReportQuery);

class DetailAnalysisRoute {
  const DetailAnalysisRoute(this.intent, {this.subIntent});

  final DetailAnalysisIntent intent;
  final String? subIntent;
}

/// Deterministic routing for the supported local data workflows.
///
/// This deliberately does not inspect dataset values or call a remote model.
DetailAnalysisRoute routeDetailAnalysisMessage(
  String message, {
  DetailAnalysisRoute? previousRoute,
}) {
  final text = _normalize(message);
  final words = text.isEmpty ? <String>[] : text.split(' ');
  if (words.isEmpty)
    return const DetailAnalysisRoute(DetailAnalysisIntent.unknown);

  // Keep specific workflows ahead of generic analysis language.
  if (_containsAny(words, const ['dashboard', 'visualize', 'visualise'])) {
    return const DetailAnalysisRoute(DetailAnalysisIntent.dashboard);
  }
  if (_containsAnyPhrase(words, const [
    'create date dimension',
    'build dim date',
    'create calendar',
    'dim date',
  ])) {
    return const DetailAnalysisRoute(DetailAnalysisIntent.dateDimension);
  }
  if (_containsAnyPhrase(words, const [
    'clean order',
    'clean orders',
    'duplicate transaction',
    'prepare fact order',
    'prepare fact orders',
    'bad order date',
  ])) {
    return const DetailAnalysisRoute(DetailAnalysisIntent.orderCleaning);
  }
  if (_containsAnyPhrase(words, const [
    'clean product',
    'product categor',
    'product dimension',
    'fix product categor',
  ])) {
    return const DetailAnalysisRoute(DetailAnalysisIntent.productCleaning);
  }
  if (_containsAnyPhrase(words, const [
    'clean customer',
    'duplicate customer',
    'duplicate customers',
    'customer dimension',
  ])) {
    return const DetailAnalysisRoute(DetailAnalysisIntent.customerCleaning);
  }
  final isTopProducts =
      words.contains('top') && words.any((word) => word.startsWith('product'));
  final isInsightRequest = text.contains('insight') ||
      text.contains('pay attention') ||
      text.contains('unusual pattern') ||
      text.contains('profitability concern') ||
      text.contains('what changed the most') ||
      text.contains('tell me more') ||
      text.contains('why is that important') ||
      text.contains('underlying') ||
      text.contains('opportunit') ||
      text.contains('risk');
  final isReportRequest = text.contains('report') &&
      (text.contains('generate') ||
          text.contains('create') ||
          text.contains('current analysis'));
  final isBusinessRequest =
      isInsightRequest ||
      isReportRequest ||
      text.contains('compare ') ||
      text.contains('which one') ||
      (text.contains('why ') && text.contains(' than ')) ||
      text.contains('improved the most') ||
      text.contains('which product drives') ||
      _containsAnyPhrase(words, const [
        'regional profit',
        'regions generate',
        'monthly revenue',
        'monthly performance',
        'high revenue low margin',
        'product profitability',
        'business performance',
      ]) ||
      isTopProducts ||
      (words.any(
            const {'which', 'most', 'highest', 'top', 'lowest'}.contains,
          ) &&
          words.any(
            const {
              'profit',
              'profitable',
              'revenue',
              'sales',
              'margin',
              'margins',
            }.contains,
          )) ||
      (words.any(
            const {
              'revenue',
              'profit',
              'profitable',
              'sales',
              'margin',
              'margins',
            }.contains,
          ) &&
          words.any(
            const {
              'product',
              'products',
              'region',
              'regions',
              'month',
              'monthly',
              'trend',
              'trending',
            }.contains,
          ));
  if (isBusinessRequest) {
    final subIntent =
        isInsightRequest
        ? 'automatic_insights'
        : text.contains('compare') ||
            text.contains('which one') ||
            (text.contains('why ') && text.contains(' than ')) ||
            text.contains('improved the most') ||
            text.contains('which product drives')
        ? 'comparison_analysis'
        : text.contains('region') &&
              (text.contains('individual') ||
                  text.contains('region record') ||
                  text.contains('region member') ||
                  text.contains('region id'))
        ? 'region_member_profit'
        : text.contains('region')
        ? 'regional_profit'
        : text.contains('month')
        ? 'monthly_performance'
        : text.contains('margin')
        ? 'margin_watchlist'
        : text.contains('product')
        ? 'top_products'
        : null;
    return DetailAnalysisRoute(
      DetailAnalysisIntent.businessAnalysis,
      subIntent: subIntent,
    );
  }
  if (_containsAny(words, const [
    'relationship',
    'relationships',
    'foreign',
    'orphan',
    'referential',
  ])) {
    return const DetailAnalysisRoute(
      DetailAnalysisIntent.detailAnalysis,
      subIntent: 'data_quality:all',
    );
  }
  final qualityScope = _datasetQualityScope(words);
  if (qualityScope != null) {
    return DetailAnalysisRoute(
      qualityScope == 'customer'
          ? DetailAnalysisIntent.customerDataQuality
          : DetailAnalysisIntent.detailAnalysis,
      subIntent: 'data_quality:$qualityScope',
    );
  }
  final followUpScope = _datasetScope(words);
  if (previousRoute?.intent == DetailAnalysisIntent.businessAnalysis &&
      (words.any(
            const {
              'how',
              'performed',
              'performance',
              'what',
              'about',
              'only',
            }.contains,
          ) ||
          words.any((word) => RegExp(r'^20\d\d$').hasMatch(word)))) {
    return DetailAnalysisRoute(
      DetailAnalysisIntent.businessAnalysis,
      subIntent: previousRoute?.subIntent,
    );
  }
  if ((previousRoute?.intent == DetailAnalysisIntent.detailAnalysis ||
          previousRoute?.intent == DetailAnalysisIntent.customerDataQuality) &&
      (followUpScope != null || _isQualityFollowUp(words))) {
    return DetailAnalysisRoute(
      DetailAnalysisIntent.detailAnalysis,
      subIntent:
          'data_quality:${followUpScope ?? _scopeFromRoute(previousRoute)}',
    );
  }
  if (_isDetailAnalysisRequest(words)) {
    return const DetailAnalysisRoute(DetailAnalysisIntent.detailAnalysis);
  }
  return const DetailAnalysisRoute(DetailAnalysisIntent.unknown);
}

String? _datasetQualityScope(List<String> words) {
  final scope = _datasetScope(words);
  if (scope == null) return null;
  const issueWords = {
    'issue',
    'issues',
    'problem',
    'problems',
    'quality',
    'suspicious',
    'anomaly',
    'anomalies',
    'integrity',
    'attention',
    'wrong',
    'fix',
    'healthy',
  };
  const reviewWords = {'check', 'inspect', 'review'};
  if (words.any(issueWords.contains) || words.any(reviewWords.contains)) {
    return scope;
  }
  return null;
}

String? _datasetScope(List<String> words) {
  for (final entry in const {
    'customer': 'customer',
    'customers': 'customer',
    'product': 'product',
    'products': 'product',
    'order': 'order',
    'orders': 'order',
    'transaction': 'order',
    'transactions': 'order',
    'region': 'region',
    'regions': 'region',
  }.entries) {
    if (words.contains(entry.key)) return entry.value;
  }
  return null;
}

bool _isQualityFollowUp(List<String> words) =>
    words.any(const {'why', 'serious', 'biggest', 'attention', 'fix'}.contains);

String _scopeFromRoute(DetailAnalysisRoute? route) {
  final subIntent = route?.subIntent ?? '';
  final separator = subIntent.indexOf(':');
  return separator >= 0 ? subIntent.substring(separator + 1) : 'all';
}

String _normalize(String message) => message
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\banalyse\b'), 'analyze');

bool _containsAny(List<String> words, List<String> values) =>
    values.any(words.contains);

bool _containsAnyPhrase(List<String> words, List<String> phrases) =>
    phrases.any((phrase) => _containsPhrase(words, phrase));

bool _containsPhrase(List<String> words, String phrase) {
  final phraseWords = _normalize(phrase).split(' ');
  if (phraseWords.length > words.length) return false;
  for (var index = 0; index <= words.length - phraseWords.length; index++) {
    var matches = true;
    for (var offset = 0; offset < phraseWords.length; offset++) {
      final expected = phraseWords[offset];
      final actual = words[index + offset];
      if (expected.endsWith('categor')) {
        if (!actual.startsWith('categor')) matches = false;
      } else if (actual != expected) {
        matches = false;
      }
    }
    if (matches) return true;
  }
  return false;
}

bool _isDetailAnalysisRequest(List<String> words) {
  const dataObjects = {'data', 'dataset', 'datasets', 'file', 'files'};
  const analysisActions = {
    'analyze',
    'analysis',
    'profile',
    'profiling',
    'inspect',
    'understand',
    'review',
    'check',
  };
  const directPhrases = [
    'detail analysis',
    'detailed analysis',
    'data analysis',
    'dataset analysis',
    'data profiling',
    'full analysis',
    'complete analysis',
    'comprehensive analysis',
    'check data quality',
    'tell me about these datasets',
    'what is in this data',
    'what do these datasets contain',
  ];

  if (_containsAnyPhrase(words, directPhrases)) return true;
  if (words.contains('everything') && words.contains('analyze')) return true;

  final hasAction = words.any(analysisActions.contains);
  final hasDataObject = words.any(dataObjects.contains);
  return hasAction && hasDataObject;
}
