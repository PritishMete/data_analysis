class CurrencyTargetDefinition {
  final List<String> aliases;
  final String symbol;
  final int decimals;

  const CurrencyTargetDefinition({
    required this.aliases,
    required this.symbol,
    required this.decimals,
  });
}

const Map<String, CurrencyTargetDefinition> kCurrencyTargetRegistry = {
  'INR': CurrencyTargetDefinition(
    aliases: ['INR', 'inr', 'rupee', 'rupees', 'Indian rupee', 'Indian rupees', '₹', 'rs', 'rs.'],
    symbol: '₹',
    decimals: 2,
  ),
  'USD': CurrencyTargetDefinition(
    aliases: ['USD', 'usd', 'dollar', 'dollars', 'US dollar', 'US dollars', r'$', r'us$', 'us dollar', 'us dollars'],
    symbol: r'$',
    decimals: 2,
  ),
  'EUR': CurrencyTargetDefinition(
    aliases: ['EUR', 'eur', 'euro', 'euros', '€'],
    symbol: '€',
    decimals: 2,
  ),
  'GBP': CurrencyTargetDefinition(
    aliases: ['GBP', 'gbp', 'pound', 'pounds', 'British pound', 'British pounds', '£'],
    symbol: '£',
    decimals: 2,
  ),
  'JPY': CurrencyTargetDefinition(
    aliases: ['JPY', 'jpy', 'yen', 'Japanese yen', '¥'],
    symbol: '¥',
    decimals: 0,
  ),
  'AED': CurrencyTargetDefinition(
    aliases: ['AED', 'aed', 'dirham', 'dirhams', 'د.إ'],
    symbol: 'د.إ',
    decimals: 2,
  ),
  'SGD': CurrencyTargetDefinition(
    aliases: ['SGD', 'sgd', 'Singapore dollar', 'Singapore dollars', r'S$'],
    symbol: r'S$',
    decimals: 2,
  ),
  'CAD': CurrencyTargetDefinition(
    aliases: ['CAD', 'cad', 'Canadian dollar', 'Canadian dollars', r'C$'],
    symbol: r'C$',
    decimals: 2,
  ),
  'RUB': CurrencyTargetDefinition(
    aliases: ['RUB', 'rub', 'ruble', 'rubles', 'rubel', 'rubels', 'rouble', 'roubles', '₽'],
    symbol: '₽',
    decimals: 2,
  ),
  'BDT': CurrencyTargetDefinition(
    aliases: ['BDT', 'bdt', 'taka', '৳'],
    symbol: '৳',
    decimals: 2,
  ),
  'AUD': CurrencyTargetDefinition(
    aliases: ['AUD', 'aud', 'australian dollar', 'australian dollars', r'A$'],
    symbol: r'A$',
    decimals: 2,
  ),
  'CNY': CurrencyTargetDefinition(
    aliases: ['CNY', 'cny', 'yuan', 'renminbi', '元'],
    symbol: '¥',
    decimals: 2,
  ),
  'HKD': CurrencyTargetDefinition(
    aliases: ['HKD', 'hkd', 'hong kong dollar', 'hong kong dollars', r'HK$'],
    symbol: r'HK$',
    decimals: 2,
  ),
};

String? resolveTargetCurrency(String userText) {
  final lowered = userText.toLowerCase();
  if (!RegExp(r'\b(?:convert|change|exchange|transform|express|denominate)\b').hasMatch(lowered)) {
    return null;
  }
  final normalized = lowered.replaceAll(RegExp(r'[\u00A0\u202F\t\r\n]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  final patterns = [
    RegExp(r'\b(?:in|to|into|as)\s+(.+?)(?=$|\b(?:and|then|for|with|from|on|by|please)\b|[.,;:])', caseSensitive: false),
    RegExp(r'\bcurrency\s+(?:as|in|to|into)\s+(.+?)(?=$|\b(?:and|then|for|with|from|on|by|please)\b|[.,;:])', caseSensitive: false),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(normalized);
    if (match == null) continue;
    final candidate = match.group(1)?.trim() ?? '';
    final resolved = normalizeTargetCurrency(candidate);
    if (resolved != null) return resolved;
  }
  return null;
}

String? normalizeTargetCurrency(String? value) {
  if (value == null) return null;
  final s = value.replaceAll(RegExp(r'[\u00A0\u202F\t\r\n]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.isEmpty) return null;
  final lower = s.toLowerCase();
  for (final entry in kCurrencyTargetRegistry.entries) {
    for (final alias in entry.value.aliases) {
      final aliasLower = alias.toLowerCase().trim();
      if (aliasLower.isEmpty) continue;
      if (lower == aliasLower) return entry.key;
      if (RegExp(r'(?<!\w)' + RegExp.escape(aliasLower) + r'(?!\w)', caseSensitive: false).hasMatch(s)) {
        return entry.key;
      }
    }
  }
  return null;
}

String? currencySymbolForCode(String code) {
  final normalized = normalizeTargetCurrency(code) ?? code.toUpperCase();
  return kCurrencyTargetRegistry[normalized]?.symbol;
}

String currencyNumberFormatForCode(String code) {
  final normalized = normalizeTargetCurrency(code) ?? code.toUpperCase();
  final entry = kCurrencyTargetRegistry[normalized];
  if (entry == null) return '#,##0.00';
  return entry.decimals == 0 ? '${entry.symbol}#,##0' : '${entry.symbol}#,##0.00';
}
