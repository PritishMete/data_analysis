/// Local-only utilities for carrying an analytical selection across chat turns.
///
/// Values originate from the deterministic backend result and remain in the
/// browser session. Nothing in this file calls an external planner or service.
library;

Map<String, dynamic> resolveBusinessFiltersFromContext(
  Map<String, dynamic> context,
  String query,
) {
  final text = query.toLowerCase();
  final words = text
      .split(RegExp(r'[^a-z0-9]+'))
      .where((word) => word.isNotEmpty)
      .toList();
  final reset =
      text.contains('reset') ||
      (text.contains('overall') && text.contains('company'));
  if (reset) return <String, dynamic>{};

  final followUp =
      context.isNotEmpty &&
      (words.any(
            {
              'it',
              'that',
              'same',
              'there',
              'what',
              'how',
              'only',
              'and',
            }.contains,
          ) ||
          RegExp(r'\b20\d\d\b').hasMatch(text));
  final filters = <String, dynamic>{
    if (followUp)
      ...Map<String, dynamic>.from(
        (context['filters'] as Map?) ?? const <String, dynamic>{},
      ),
  };

  final year = RegExp(r'\b20\d\d\b').firstMatch(text)?.group(0);
  if (year != null) {
    filters['year'] = year;
  } else if (text.contains('previous year') && filters['year'] != null) {
    filters['year'] = int.parse(filters['year'].toString()) - 1;
  }

  final options = context['filter_options'] is Map
      ? Map<String, dynamic>.from(context['filter_options'] as Map)
      : const <String, dynamic>{};
  for (final dimension in const ['business_region', 'category', 'product']) {
    final values = (options[dimension] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final match = values.where((value) => text.contains(value.toLowerCase()));
    if (match.isNotEmpty) {
      filters[dimension] = match.first;
      // An explicitly named product replaces the prior selected entity.
      if (dimension == 'product') filters.remove('product_id');
    }
  }
  return filters;
}

/// Binds the winning row of a structured local ranking to session context.
///
/// The function deliberately reads analysis fields, never rendered prose.  The
/// returned identifier is kept only for the local filter request; display text
/// is used for the report scope.
Map<String, dynamic>? bindSelectedEntityFromResult(
  Map<String, dynamic> analysisResult, {
  required String requestedGrain,
  required String rankingMetric,
}) {
  final resultKey = switch (requestedGrain) {
    'business_region' => 'business_region_profit',
    'product' => 'top_products_by_revenue',
    _ => null,
  };
  if (resultKey == null) return null;
  final section = analysisResult[resultKey];
  if (section is! Map || section['rows'] is! List) return null;
  final rows = section['rows'] as List;
  if (rows.isEmpty || rows.first is! Map) return null;
  final row = Map<String, dynamic>.from(rows.first as Map);
  final display = _firstPresent(
    row,
    switch (requestedGrain) {
      'business_region' => const ['region', 'business_region', 'name', 'label'],
      'product' => const ['product', 'product_name', 'name', 'label', 'product_id'],
      _ => const ['name', 'label', 'value', 'id'],
    },
  );
  if (display == null) return null;
  final localKey = _firstPresent(
    row,
    switch (requestedGrain) {
      'product' => const ['product_id', 'product_key', 'id', 'key'],
      _ => const ['id', 'key'],
    },
  );
  return {
    'role': requestedGrain,
    'display_value': display,
    if (localKey != null) 'local_key': localKey,
    'grain': requestedGrain,
    'ranking_metric': rankingMetric,
  };
}

String? _firstPresent(Map<String, dynamic> row, List<String> candidates) {
  for (final key in candidates) {
    final value = row[key];
    if (value != null && value.toString().trim().isNotEmpty) {
      return value.toString();
    }
  }
  return null;
}
