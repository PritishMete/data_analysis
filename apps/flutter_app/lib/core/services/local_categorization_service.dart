// lib/core/services/local_categorization_service.dart
// Secure-local categorization and currency conversion.
// The workbook rows NEVER leave the device. Gemini is used only by the
// metadata-only /agentic_command planner to understand the user's request;
// this service executes the returned plan locally.
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'currency_registry.dart';
import 'local_llm_service.dart';

const String _backend = 'https://data-analysis-oajs.onrender.com';

class LocalCategorizationResult {
  final List<List<dynamic>> rows;
  final List<String> messages;
  final int convertedCells;
  final List<String> convertedColumns;
  final Map<String, String> numberFormats;
  final Map<String, dynamic> diagnostics;
  LocalCategorizationResult({
    required this.rows,
    required this.messages,
    required this.convertedCells,
    required this.convertedColumns,
    required this.numberFormats,
    required this.diagnostics,
  });
}

class LocalCategorizationService {
  static LocalLlmProvider? localLlmProvider = createLocalLlmProvider();

  static String _normalizeCellText(dynamic value) {
    final text = value?.toString() ?? '';
    return text
        .replaceAll(RegExp(r'[\u00A0\u202F\t\r\n]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _norm(String v) => v.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();

  static int _levenshtein(String a, String b) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final prev = List<int>.generate(b.length + 1, (i) => i);
    final curr = List<int>.filled(b.length + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      curr[0] = i;
      for (var j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1,
          curr[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      for (var j = 0; j <= b.length; j++) {
        prev[j] = curr[j];
      }
    }
    return prev[b.length];
  }

  static String? _fuzzyLookup(String raw, Map<String, String> aliases, List<String> canonicals, {int maxDistance = 2}) {
    final n = _norm(raw).replaceAll(' ', '');
    if (n.isEmpty) return null;
    final aliasHit = aliases[n];
    if (aliasHit != null) return aliasHit;
    String? best;
    var bestDistance = 1 << 30;
    for (final canonical in canonicals) {
      final c = canonical.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
      final distance = _levenshtein(n, c);
      if (distance < bestDistance) {
        bestDistance = distance;
        best = canonical;
      } else if (distance == bestDistance) {
        best = null; // ambiguous
      }
    }
    if (best != null && bestDistance <= maxDistance) return best;
    return null;
  }

  static String? _currencyFromText(dynamic value) {
    if (value == null) return null;
    final s = _normalizeCellText(value);
    final low = s.toLowerCase();
    final checks = <MapEntry<RegExp, String>>[
      MapEntry(RegExp(r'us\$', caseSensitive: false), 'USD'),
      MapEntry(RegExp(r'\bus dollar(?:s)?\b', caseSensitive: false), 'USD'),
      MapEntry(RegExp(r'\busd\b', caseSensitive: false), 'USD'),
      MapEntry(RegExp(r's\$', caseSensitive: false), 'SGD'),
      MapEntry(RegExp(r'\bsingapore dollar(?:s)?\b', caseSensitive: false), 'SGD'),
      MapEntry(RegExp(r'\bsgd\b', caseSensitive: false), 'SGD'),
      MapEntry(RegExp(r'c\$', caseSensitive: false), 'CAD'),
      MapEntry(RegExp(r'\bcanadian dollar(?:s)?\b', caseSensitive: false), 'CAD'),
      MapEntry(RegExp(r'\bcad\b', caseSensitive: false), 'CAD'),
      MapEntry(RegExp(r'a\$', caseSensitive: false), 'AUD'),
      MapEntry(RegExp(r'\baustralian dollar(?:s)?\b', caseSensitive: false), 'AUD'),
      MapEntry(RegExp(r'\baud\b', caseSensitive: false), 'AUD'),
      MapEntry(RegExp(r'hk\$', caseSensitive: false), 'HKD'),
      MapEntry(RegExp(r'\bhong kong dollar(?:s)?\b', caseSensitive: false), 'HKD'),
      MapEntry(RegExp(r'\bhkd\b', caseSensitive: false), 'HKD'),
      MapEntry(RegExp(RegExp.escape('د.إ'), caseSensitive: false), 'AED'),
      MapEntry(RegExp(r'\baed\b', caseSensitive: false), 'AED'),
      MapEntry(RegExp(r'\bdirham(?:s)?\b', caseSensitive: false), 'AED'),
      MapEntry(RegExp(r'₹'), 'INR'),
      MapEntry(RegExp(r'\binr\b', caseSensitive: false), 'INR'),
      MapEntry(RegExp(r'\brs\.?\b', caseSensitive: false), 'INR'),
      MapEntry(RegExp(r'\brupee(?:s)?\b', caseSensitive: false), 'INR'),
      MapEntry(RegExp(r'৳'), 'BDT'),
      MapEntry(RegExp(r'\bbdt\b', caseSensitive: false), 'BDT'),
      MapEntry(RegExp(r'\btaka\b', caseSensitive: false), 'BDT'),
      MapEntry(RegExp(r'₽'), 'RUB'),
      MapEntry(RegExp(r'\brub(?:le|les)?\b', caseSensitive: false), 'RUB'),
      MapEntry(RegExp(r'\brubel(?:s)?\b', caseSensitive: false), 'RUB'),
      MapEntry(RegExp(r'\brouble(?:s)?\b', caseSensitive: false), 'RUB'),
      MapEntry(RegExp(r'€'), 'EUR'),
      MapEntry(RegExp(r'\beur\b', caseSensitive: false), 'EUR'),
      MapEntry(RegExp(r'\beuro(?:s)?\b', caseSensitive: false), 'EUR'),
      MapEntry(RegExp(r'£'), 'GBP'),
      MapEntry(RegExp(r'\bgbp\b', caseSensitive: false), 'GBP'),
      MapEntry(RegExp(r'\bpound(?:s)?\b', caseSensitive: false), 'GBP'),
      MapEntry(RegExp(r'¥'), 'JPY'),
      MapEntry(RegExp(r'\bjpy\b', caseSensitive: false), 'JPY'),
      MapEntry(RegExp(r'\byen\b', caseSensitive: false), 'JPY'),
      MapEntry(RegExp(r'\bcny\b', caseSensitive: false), 'CNY'),
      MapEntry(RegExp(r'\byuan\b', caseSensitive: false), 'CNY'),
      MapEntry(RegExp(r'\brenminbi\b', caseSensitive: false), 'CNY'),
      MapEntry(RegExp(r'元'), 'CNY'),
      MapEntry(RegExp(r'\$'), 'USD'),
    ];
    for (final entry in checks) {
      if (entry.key.hasMatch(s) || entry.key.hasMatch(low)) return entry.value;
    }
    return null;
  }

  static double? _amount(dynamic value) {
    if (value == null || value is bool) return null;
    if (value is num) return value.toDouble();
    final s = _normalizeCellText(value).replaceAll(',', '');
    final m = RegExp(r'[-+]?\d+(?:\.\d+)?').firstMatch(s);
    return m == null ? null : double.tryParse(m.group(0)!);
  }

  static String? _headerCurrency(String header) {
    final n = _norm(header);
    final m = RegExp(r'\b(usd|inr|rub|bdt|eur|gbp|aed|sgd|jpy|cny|cad|aud)\b').firstMatch(n);
    return m?.group(1)?.toUpperCase();
  }

  static bool _looksMoneyHeader(String header) => RegExp(r'\b(currency|price|amount|cost|fare|salary|revenue|sales|income|budget|fee|charge|value|pay|payment)\b', caseSensitive: false).hasMatch(header);

  static Future<double> _rate(String from, String to) async {
    if (from == to) return 1.0;
    final uri = Uri.parse('$_backend/currency/rates?base=${Uri.encodeComponent(from)}&target=${Uri.encodeComponent(to)}');
    final res = await http.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode < 200 || res.statusCode >= 300) throw Exception('Exchange-rate service returned HTTP ${res.statusCode}.');
    final body = jsonDecode(res.body);
    final rate = body is Map ? body['rate'] : null;
    if (rate is num) return rate.toDouble();
    throw Exception('No $from→$to exchange rate is available.');
  }

  static String _booleanCategory(String v) {
    final x = v.trim().toLowerCase();
    String compact = x;
    while (compact.length >= 2 && compact[compact.length - 1] == compact[compact.length - 2]) {
      compact = compact.substring(0, compact.length - 1);
    }
    if ({'yes','y','ye','true','t','1'}.contains(x) || {'yes','y','ye','true','t'}.contains(compact)) return 'Yes';
    if ({'no','n','false','f','0'}.contains(x) || {'no','n','false','f'}.contains(compact)) return 'No';
    return 'Unknown';
  }

  static String _countryCategory(String v) {
    const aliases = {
      'india': 'India',
      'ind': 'India',
      'in': 'India',
      'idnia': 'India',
      'indai': 'India',
      'uae': 'United Arab Emirates',
      'united arab emirates': 'United Arab Emirates',
      'unitedarabemirates': 'United Arab Emirates',
      'arab': 'United Arab Emirates',
      'singapore': 'Singapore',
      'singapor': 'Singapore',
      'uk': 'United Kingdom',
      'united kingdom': 'United Kingdom',
      'us': 'United States',
      'usa': 'United States',
      'united states': 'United States',
      'bangladesh': 'Bangladesh',
      'bd': 'Bangladesh',
      'russia': 'Russia',
      'russina': 'Russia',
      'canada': 'Canada',
      'canad': 'Canada',
    };
    final n = _norm(v).replaceAll(' ', '');
    if (n.isEmpty) return 'Unknown';
    final direct = aliases[n];
    if (direct != null) return direct;
    const canonicals = ['India', 'United Arab Emirates', 'Singapore', 'United Kingdom', 'United States', 'Bangladesh', 'Russia', 'Canada'];
    return _fuzzyLookup(v, aliases, canonicals, maxDistance: 2) ?? _title(v);
  }

  static String _genderCategory(String v) {
    final n = _norm(v).replaceAll(' ', '');
    final compact = n.replaceAll(RegExp(r'(.)\1+$'), r'$1');
    if ({'m', 'male', 'malee', 'mlae', 'mal'}.contains(n) || {'m', 'male', 'malee', 'mlae', 'mal'}.contains(compact)) return 'Male';
    if ({'f', 'female', 'femalee', 'femle', 'femaile'}.contains(n) || {'f', 'female', 'femalee', 'femle', 'femaile'}.contains(compact)) return 'Female';
    if ({'t', 'trans', 'transgender'}.contains(n)) return 'Transgender';
    if ({'nb', 'nonbinary', 'non-binary', 'nonbinary'.replaceAll('-', ''), 'non binary'}.contains(n)) return 'Non-binary';
    return 'Unknown';
  }

  static Map<String,String>? _specialMapping(List<String> values, String header) {
    final name = _norm(header).replaceAll(' ', '');
    final low = {for (final v in values) v: v.trim().toLowerCase()};
    const boolTokens = {'yes','no','y','n','ye','true','false','t','f','1','0'};
    const nullTokens = {'','none','null','na','n/a','nan','unknown'};
    final nonNull = low.values.where((v) => !nullTokens.contains(v)).toSet();
    final explicitBool = name == 'bool' || name == 'boolean' || name == 'flag' || name == 'binary' || name.startsWith('is') || name.startsWith('has') || name.endsWith('flag');
    if (explicitBool || (nonNull.isNotEmpty && nonNull.every(boolTokens.contains))) {
      return {for (final e in low.entries) e.key: _booleanCategory(e.value)};
    }
    if (name.contains('country') || {'nation','countryname'}.contains(name)) {
      return {
        for (final e in low.entries)
          e.key: _countryCategory(e.value)
      };
    }
    if (name.contains('city') || {'town','cityname'}.contains(name)) {
      const aliases = {'new delhi':'New Delhi','delhi':'Delhi','newdelhi':'New Delhi','mumbai':'Mumbai','bombay':'Mumbai','kolkata':'Kolkata','calcutta':'Kolkata','gurgaon':'Gurgaon','gurugram':'Gurgaon','bangalore':'Bangalore','bengaluru':'Bangalore','hyderabad':'Hyderabad','chennai':'Chennai','madras':'Chennai','pune':'Pune','noida':'Noida','faridabad':'Faridabad','jaipur':'Jaipur','ahmedabad':'Ahmedabad','dubai':'Dubai','abu dhabi':'Abu Dhabi','abudhabi':'Abu Dhabi','london':'London','singapore':'Singapore','dhaka':'Dhaka','moscow':'Moscow','new york':'New York','newyork':'New York','nyc':'New York','toronto':'Toronto'};
      return {for (final e in low.entries) e.key: aliases[e.value] ?? (nullTokens.contains(e.value) ? 'Unknown' : _title(e.value))};
    }
    if (name.contains('region') || {'area','zone','territory'}.contains(name)) {
      const aliases = {'asia':'Asia','asia pacific':'Asia','apac':'Asia','ncr':'NCR','middle east':'Middle East','middleeast':'Middle East','eu':'Europe','europe':'Europe','north america':'North America','northamerica':'North America','south america':'South America','southamerica':'South America','africa':'Africa','oceania':'Oceania'};
      return {for (final e in low.entries) e.key: aliases[e.value] ?? (nullTokens.contains(e.value) ? 'Unknown' : _title(e.value))};
    }
    if (name.contains('gender') || {'sex','gendercode'}.contains(name)) {
      final out=<String,String>{};
      for (final e in low.entries) {
        out[e.key] = _genderCategory(e.value);
      }
      return out;
    }
    return null;
  }

  static String _inferSemanticType(String header, List<String> values, {String userText = ''}) {
    final normalized = _norm(header).replaceAll(' ', '');
    final request = _norm(userText).replaceAll(' ', '');
    if (normalized.contains('country') || {'nation', 'countryname'}.contains(normalized)) return 'country';
    if (normalized.contains('region') || {'area', 'zone', 'territory'}.contains(normalized)) return 'region';
    if (normalized.contains('city') || {'town', 'cityname'}.contains(normalized)) return 'city';
    if (normalized.contains('gender') || {'sex', 'gendercode'}.contains(normalized)) return 'gender';
    if (normalized == 'bool' || normalized == 'boolean' || normalized == 'flag' || normalized == 'binary' || normalized.startsWith('is') || normalized.startsWith('has') || normalized.endsWith('flag')) return 'boolean';
    if (normalized.contains('review') || normalized.contains('comment') || normalized.contains('feedback') || request.contains('sentiment')) return 'sentiment';
    if (_looksMoneyHeader(header) || values.any((v) => _currencyFromText(v) != null)) return 'currency';
    return 'categorical';
  }

  static Map<String, String> _applyLlmMappings(
    List<String> values,
    List<LocalLlmMapping> mappings,
  ) {
    final out = <String, String>{};
    final allowed = values.toSet();
    for (final mapping in mappings) {
      if (!allowed.contains(mapping.source)) continue;
      if (mapping.confidence < 0.8) continue;
      final canonical = mapping.canonical.trim();
      if (canonical.isEmpty) continue;
      out[mapping.source] = canonical;
    }
    return out;
  }

  static String _title(String s) => s.trim().split(RegExp(r'\s+')).where((x)=>x.isNotEmpty).map((x)=>x[0].toUpperCase()+x.substring(1).toLowerCase()).join(' ');

  static bool _isNumericColumn(List<dynamic> values) {
    final nonEmpty=values.where((v)=>v!=null && v.toString().trim().isNotEmpty).toList();
    if (nonEmpty.isEmpty) return false;
    final good=nonEmpty.where((v)=>_amount(v)!=null).length;
    return good/nonEmpty.length >= .9;
  }

  static Future<LocalCategorizationResult> execute({required List<List<dynamic>> sourceRows, required List<String> sourceColumns, required bool allColumns, required String? targetCurrency, String userText = ''}) async {
    if (sourceRows.isEmpty) throw Exception('No local dataset is loaded.');
    final headers=sourceRows.first.map((e)=>e?.toString()??'').toList();
    final selected = allColumns ? List<String>.from(headers) : sourceColumns.where((c)=>headers.any((h)=>_norm(h)==_norm(c))).toList();
    if (selected.isEmpty && sourceColumns.any((c)=>_norm(c)=='__booleancolumn__')) {
      final allowed = {'yes','no','y','n','true','false','t','f','1','0','ye'};
      for (final header in headers) {
        final values = <String>[];
        final idx = headers.indexOf(header);
        for (var r=1;r<sourceRows.length;r++) {
          if (idx >= sourceRows[r].length) continue;
          final value = sourceRows[r][idx]?.toString().trim().toLowerCase() ?? '';
          if (value.isNotEmpty) values.add(value);
        }
        if (values.isNotEmpty && values.length <= 500 && values.toSet().every(allowed.contains)) {
          selected.add(header);
          break;
        }
      }
    }
    if (selected.isEmpty) throw Exception('No requested columns were found in the local dataset.');
    final out=sourceRows.map((r)=>List<dynamic>.from(r)).toList();
    final messages=<String>[]; final convertedCols=<String>[]; int converted=0;
    final numberFormats=<String, String>{};
    final diagnostics = <String, dynamic>{
      'ai_used': false,
      'gemini_attempted': false,
      'privacy_mode': 'local_only',
      'raw_data_sent_to_ai': false,
      'values_sent_to_ai': 0,
      'columns_sent_to_ai': 0,
      'metadata_sent_to_ai': false,
      'unique_values_sent_to_ai': false,
      'local_fallback_used': true,
      'categorization_engine': 'local_deterministic',
      'currency_engine': targetCurrency != null ? 'local_conversion' : 'unused',
      'currency_conversion_requested': targetCurrency != null,
      'sentiment_requested': false,
      'numeric_binning_requested': false,
      'columns_requested': selected,
    };

    // A Currency column can supply the source code for a numeric amount column.
    final currencyColIndex=headers.indexWhere((h)=>RegExp(r'\b(currency|currency code|ccy)\b',caseSensitive:false).hasMatch(h));
    final rateCache=<String,double>{};

    // Transform selected columns in place so the result sheet keeps the
    // original dataset shape instead of adding companion category columns.
    for (final header in selected) {
      final idx=headers.indexOf(header); if (idx<0) continue;
      final vals=<String>[];
      for (var r=1;r<out.length;r++) { if (idx<out[r].length) { final v=out[r][idx]?.toString()??''; if (!vals.contains(v)) vals.add(v); } }
      final moneyHeader=_looksMoneyHeader(header) || _headerCurrency(header)!=null || vals.take(100).any((v)=>_currencyFromText(v)!=null);
      final normalizedHeader = _norm(header).replaceAll(' ', '');
      final isCountry = normalizedHeader.contains('country') || {'nation', 'countryname'}.contains(normalizedHeader);
      final isGender = normalizedHeader.contains('gender') || {'sex', 'gendercode'}.contains(normalizedHeader);
      final isBool = normalizedHeader == 'bool' || normalizedHeader == 'boolean' || normalizedHeader == 'flag' || normalizedHeader == 'binary' || normalizedHeader.startsWith('is') || normalizedHeader.startsWith('has') || normalizedHeader.endsWith('flag');
      if (isCountry) {
        for (var r=1;r<out.length;r++) {
          if (idx<out[r].length) {
            out[r][idx] = _countryCategory(out[r][idx]?.toString() ?? '');
          }
        }
        messages.add("Categorized '$header' locally using high-confidence rules.");
        continue;
      }
      if (isGender) {
        for (var r=1;r<out.length;r++) {
          if (idx<out[r].length) {
            out[r][idx] = _genderCategory(out[r][idx]?.toString() ?? '');
          }
        }
        messages.add("Categorized '$header' locally using high-confidence rules.");
        continue;
      }
      if (isBool) {
        for (var r=1;r<out.length;r++) {
          if (idx<out[r].length) {
            out[r][idx] = _booleanCategory(out[r][idx]?.toString() ?? '');
          }
        }
        messages.add("Categorized '$header' locally using high-confidence rules.");
        continue;
      }
      final currentValues=<String>[];
      for (var r=1;r<out.length;r++) { if (idx<out[r].length) { final v=out[r][idx]?.toString()??''; if (!currentValues.contains(v)) currentValues.add(v); } }
      final mapping=_specialMapping(currentValues,header);
      if (mapping!=null) {
        for (var r=1;r<out.length;r++) {
          if (idx<out[r].length) {
            out[r][idx]=mapping[out[r][idx]?.toString()??''] ?? 'Unknown';
          }
        }
        messages.add("Categorized '$header' locally using high-confidence rules.");
        final unresolved = vals.where((v) => !mapping.containsKey(v)).toList();
        if (unresolved.isNotEmpty && localLlmProvider != null && targetCurrency == null) {
          try {
            final semanticType = _inferSemanticType(header, vals, userText: userText);
            final llmMappings = await localLlmProvider!.categorizeValues(
              semanticType: semanticType,
              values: unresolved,
              instruction: userText,
            );
            final accepted = _applyLlmMappings(unresolved, llmMappings);
            if (accepted.isNotEmpty) {
              for (var r = 1; r < out.length; r++) {
                if (idx < out[r].length) {
                  final current = out[r][idx]?.toString() ?? '';
                  if (accepted.containsKey(current)) {
                    out[r][idx] = accepted[current];
                  }
                }
              }
              messages.add("Refined '$header' with local LLM assistance.");
            }
          } catch (_) {}
        }
        continue;
      }
      final unresolved = currentValues.where((value) => value.trim().isNotEmpty).toList();
      if (localLlmProvider != null && unresolved.isNotEmpty && targetCurrency == null) {
        try {
          final semanticType = _inferSemanticType(header, unresolved, userText: userText);
          final llmMappings = await localLlmProvider!.categorizeValues(
            semanticType: semanticType,
            values: unresolved,
            instruction: userText,
          );
          final accepted = _applyLlmMappings(unresolved, llmMappings);
          if (accepted.isNotEmpty) {
            for (var r = 1; r < out.length; r++) {
              if (idx < out[r].length) {
                final current = out[r][idx]?.toString() ?? '';
                if (accepted.containsKey(current)) {
                  out[r][idx] = accepted[current];
                }
              }
            }
            messages.add("Categorized '$header' using local LLM assistance.");
            continue;
          }
        } catch (_) {}
      }
      if (targetCurrency!=null && moneyHeader) {
        final headerSource=_headerCurrency(header);
        for (var r=1;r<out.length;r++) {
          if (idx>=out[r].length) continue;
          final original=out[r][idx];
          final amount=_amount(original);
          if (amount==null) continue;
          var source=_currencyFromText(original) ?? headerSource;
          if (source==null && currencyColIndex>=0 && currencyColIndex<out[r].length) {
            source=_currencyFromText(out[r][currencyColIndex]);
          }
          if (source==null) continue;
          source=source.toUpperCase();
          final key='$source->$targetCurrency';
          double? rate=rateCache[key];
          if (rate == null) {
            rate = await _rate(source,targetCurrency!);
            rateCache[key] = rate;
          }
          out[r][idx]=double.parse((amount*rate).toStringAsFixed(2));
          converted++;
        }
        if (!convertedCols.contains(header)) convertedCols.add(header);
        numberFormats[header] = currencyNumberFormatForCode(targetCurrency!);
        messages.add("Converted '$header' to $targetCurrency locally.");
        continue;
      }

      if (moneyHeader) {
        messages.add("Left '$header' unchanged because currency conversion was not requested.");
        continue;
      }

      messages.add("Left '$header' unchanged because only high-confidence local fallback rules are applied.");
    }

    if (targetCurrency!=null && convertedCols.isEmpty) messages.add('No monetary column with a detectable source currency was found; no currency values were changed.');
    return LocalCategorizationResult(
      rows: out,
      messages: messages,
      convertedCells: converted,
      convertedColumns: convertedCols,
      numberFormats: numberFormats,
      diagnostics: diagnostics,
    );
  }

  static Future<Map<String, dynamic>> analyzeSentiment({
    required List<List<dynamic>> sourceRows,
    required String reviewColumn,
    String? restaurantColumn,
    int batchSize = 150,
  }) async {
    if (sourceRows.isEmpty) throw Exception('No local dataset is loaded.');
    final headers = sourceRows.first.map((e) => e?.toString() ?? '').toList();
    final reviewIndex = headers.indexWhere((h) => _norm(h).replaceAll(' ', '').contains(_norm(reviewColumn).replaceAll(' ', '')));
    if (reviewIndex < 0) throw Exception('Could not find the review-text column.');
    final restaurantIndex = restaurantColumn == null ? -1 : headers.indexWhere((h) => _norm(h).replaceAll(' ', '') == _norm(restaurantColumn).replaceAll(' ', ''));
    final reviewRows = <Map<String, dynamic>>[];
    for (var r = 1; r < sourceRows.length; r++) {
      final row = sourceRows[r];
      final review = reviewIndex < row.length ? row[reviewIndex]?.toString().trim() ?? '' : '';
      if (review.isNotEmpty) {
        reviewRows.add({
          'index': r - 1,
          'review': review,
        });
      }
    }
    final labels = <int, String>{};
    final fallback = (String text) {
      final t = text.toLowerCase();
      final negative = {'bad', 'awful', 'terrible', 'disappointing', 'noisy', 'dirty', 'rude', 'slow', 'worst', 'poor', 'hate', 'horrible', 'unhappy'};
      final positive = {'great', 'excellent', 'amazing', 'good', 'friendly', 'clean', 'fast', 'delicious', 'love', 'wonderful', 'perfect'};
      final n = negative.where(t.contains).length;
      final p = positive.where(t.contains).length;
      if (n > p && n > 0) return 'Negative';
      if (p > n && p > 0) return 'Positive';
      return 'Neutral';
    };
    if (localLlmProvider != null) {
      try {
        final reviews = reviewRows.map((e) => e['review'].toString()).toList();
        final llmLabels = await localLlmProvider!.analyzeSentiment(
          reviews: reviews,
          instruction: 'Classify each review as Positive, Neutral, Negative, or Mixed.',
        );
        for (final label in llmLabels) {
          if (label.index >= 0 && label.index < reviews.length) {
            final sentiment = {'Positive', 'Neutral', 'Negative', 'Mixed'}.contains(label.sentiment) ? label.sentiment : fallback(reviews[label.index]);
            labels[label.index] = sentiment;
          }
        }
      } catch (_) {}
    }
    for (final row in reviewRows) {
      final idx = row['index'] as int;
      labels.putIfAbsent(idx, () => fallback(row['review']?.toString() ?? ''));
    }
    final sentimentValues = <String>[];
    for (var i = 0; i < sourceRows.length - 1; i++) {
      sentimentValues.add(labels[i] ?? '');
    }
    final counts = {'Positive': 0, 'Neutral': 0, 'Negative': 0, 'Mixed': 0};
    for (final label in labels.values) {
      counts[label] = (counts[label] ?? 0) + 1;
    }
    final total = labels.length;
    final result = {
      'review_column': reviewColumn,
      'restaurant_column': restaurantIndex >= 0 ? headers[restaurantIndex] : restaurantColumn,
      'batch_size': batchSize,
      'overall': {
        'reviews_analyzed': total,
        'positive': counts['Positive'] ?? 0,
        'neutral': counts['Neutral'] ?? 0,
        'negative': counts['Negative'] ?? 0,
        'mixed': counts['Mixed'] ?? 0,
        'average_score': 0.0,
        'satisfaction_rate': total == 0 ? 0.0 : (((counts['Positive'] ?? 0) + 0.5 * (counts['Mixed'] ?? 0)) / total * 100).roundToDouble(),
      },
      'sentiment_column': 'Sentiment',
      'sentiment_values': sentimentValues,
      'summary_columns': <String>[],
      'summary_rows': <dynamic>[],
      'detail_columns': <String>[],
      'detail_rows': <dynamic>[],
      'details_included': false,
    };
    return result;
  }
}
