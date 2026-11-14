import 'package:flutter/material.dart';

import '../app_colors.dart';

/// Native, non-scrolling renderer for the structured analyst response.
class AnalystQualityMessage extends StatelessWidget {
  const AnalystQualityMessage({super.key, required this.response});

  final Map<String, dynamic> response;

  /// Extract the scoped structured response from the backend envelope.
  /// Keeping this at the widget boundary makes the API-to-renderer contract
  /// explicit and prevents callers from silently flattening the response.
  static Map<String, dynamic>? fromAnalystAnswer(
    Map<String, dynamic> answer, {
    String scope = 'customer',
  }) {
    final responses = answer['structured_responses'];
    if (responses is Map) {
      final scoped = responses[scope];
      if (scoped is Map &&
          scoped['response_type'] == 'analyst_quality_response') {
        return Map<String, dynamic>.from(scoped);
      }
    }
    final single = answer['structured_response'];
    if (single is Map &&
        single['response_type'] == 'analyst_quality_response') {
      return Map<String, dynamic>.from(single);
    }
    return null;
  }

  /// Produces the human-readable clipboard representation of the visible
  /// structured response, without transport or internal metadata.
  static String toCopyText(Map<String, dynamic> response) {
    final lines = <String>[];
    final intro = response['intro']?.toString().trim();
    if (intro != null && intro.isNotEmpty) lines.add(intro);
    final issues = _mapsForCopy(response['confirmed_issues']);
    if (issues.isNotEmpty) {
      lines
        ..add('')
        ..add('CONFIRMED ISSUES');
      for (var index = 0; index < issues.length; index++) {
        final issue = issues[index];
        final number = issue['number'] ?? index + 1;
        lines
          ..add('')
          ..add(
            number.toString() + '. ' + (issue['title'] ?? 'Issue').toString(),
          )
          ..add('Severity: ' + (issue['severity'] ?? 'Review').toString());
        _addCopyLine(lines, issue['summary']);
        for (final fact in _stringsForCopy(issue['facts'])) {
          lines.add('- ' + fact);
        }
        final examples = issue['examples'];
        if (examples is Map) {
          _addCopyTable(lines, Map<String, dynamic>.from(examples));
        }
        lines
          ..add('Impact')
          ..add(issue['impact']?.toString() ?? '');
      }
    }
    final observations = _mapsForCopy(response['minor_observations']);
    if (observations.isNotEmpty) {
      lines
        ..add('')
        ..add('MINOR OBSERVATIONS')
        ..add('| Area | Finding |')
        ..add('| --- | --- |');
      for (final observation in observations) {
        lines.add(
          '| ' +
              _copyCell(observation['area']) +
              ' | ' +
              _copyCell(observation['finding']) +
              ' |',
        );
      }
    }
    final checks = _stringsForCopy(response['passed_checks']);
    if (checks.isNotEmpty) {
      lines
        ..add('')
        ..add('WHAT IS NOT WRONG');
      lines.addAll(checks.map((check) => '- ' + check));
    }
    final recommendations = _stringsForCopy(response['recommendations']);
    if (recommendations.isNotEmpty) {
      lines
        ..add('')
        ..add('RECOMMENDED NEXT STEPS');
      for (var index = 0; index < recommendations.length; index++) {
        lines.add((index + 1).toString() + '. ' + recommendations[index]);
      }
    }
    return lines.join('\n').trim();
  }

  static List<Map<String, dynamic>> _mapsForCopy(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : const [];

  static List<String> _stringsForCopy(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];

  static void _addCopyLine(List<String> lines, Object? value) {
    final text = value?.toString().trim();
    if (text != null && text.isNotEmpty) lines.add(text);
  }

  static void _addCopyTable(List<String> lines, Map<String, dynamic> examples) {
    final columns = _stringsForCopy(examples['columns']);
    final rows = _mapsForCopy(examples['rows']);
    if (columns.isEmpty || rows.isEmpty) return;
    lines
      ..add('')
      ..add('Examples')
      ..add('| ' + columns.map(_copyCell).join(' | ') + ' |')
      ..add('| ' + columns.map((_) => '---').join(' | ') + ' |');
    for (final row in rows) {
      lines.add(
        '| ' +
            columns.map((column) => _copyCell(row[column])).join(' | ') +
            ' |',
      );
    }
  }

  static String _copyCell(Object? value) =>
      _displayForCopy(value).replaceAll('|', r'\|').replaceAll('\n', ' ');

  static String _displayForCopy(Object? value) =>
      value == null || value.toString().trim().isEmpty
      ? 'Missing'
      : value.toString();

  List<Map<String, dynamic>> _maps(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList()
      : const [];

  List<String> _strings(Object? value) =>
      value is List ? value.whereType<String>().toList() : const [];

  @override
  Widget build(BuildContext context) {
    final issues = _maps(response['confirmed_issues']);
    final observations = _maps(response['minor_observations']);
    final checks = _strings(response['passed_checks']);
    final recommendations = _strings(response['recommendations']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          response['intro']?.toString() ?? '',
          style: const TextStyle(fontSize: 14, height: 1.45),
        ),
        const SizedBox(height: 22),
        _heading('Confirmed issues'),
        ...issues.asMap().entries.map(
          (entry) => _issue(context, entry.key + 1, entry.value),
        ),
        if (observations.isNotEmpty) ...[
          const SizedBox(height: 14),
          _heading('Minor observations'),
          _observationTable(observations),
        ],
        if (checks.isNotEmpty) ...[
          const SizedBox(height: 22),
          _heading('What is not wrong'),
          ...checks.map((item) => _bullet(item)),
        ],
        if (recommendations.isNotEmpty) ...[
          const SizedBox(height: 22),
          _heading('Recommended next steps'),
          ...recommendations.asMap().entries.map(
            (entry) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                '${entry.key + 1}. ${entry.value}',
                style: const TextStyle(height: 1.4),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        color: TechColors.borderActive,
      ),
    ),
  );

  Widget _issue(BuildContext context, int number, Map<String, dynamic> issue) {
    final facts = _strings(issue['facts']);
    final examples = issue['examples'] is Map
        ? Map<String, dynamic>.from(issue['examples'] as Map)
        : const <String, dynamic>{};
    final columns = _strings(examples['columns']);
    final rows = _maps(examples['rows']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: TechColors.borderActive.withValues(alpha: .55),
              width: 2,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$number. ${issue['title'] ?? 'Issue'}',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _severity(issue['severity']?.toString() ?? 'review'),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              issue['summary']?.toString() ?? '',
              style: const TextStyle(height: 1.4),
            ),
            ...facts.map(_bullet),
            if (rows.isNotEmpty && columns.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Examples',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              _exampleTable(columns, rows),
            ],
            const SizedBox(height: 10),
            const Text('Impact', style: TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text(
              issue['impact']?.toString() ?? '',
              style: const TextStyle(height: 1.4),
            ),
          ],
        ),
      ),
    );
  }

  Widget _severity(String value) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: TechColors.statusAmber.withValues(alpha: .18),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      value.toUpperCase(),
      style: const TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: TechColors.statusAmber,
      ),
    ),
  );

  Widget _bullet(String text) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('•  '),
        Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
      ],
    ),
  );

  Widget _exampleTable(List<String> columns, List<Map<String, dynamic>> rows) =>
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.all(color: TechColors.borderMuted),
          children: [
            TableRow(
              decoration: BoxDecoration(color: TechColors.panelBg),
              children: columns.map((column) => _cell(column, true)).toList(),
            ),
            ...rows.map(
              (row) => TableRow(
                children: columns
                    .map((column) => _cell(_display(row[column]), false))
                    .toList(),
              ),
            ),
          ],
        ),
      );

  Widget _observationTable(List<Map<String, dynamic>> rows) => _exampleTable(
    const ['Area', 'Finding'],
    rows
        .map((row) => {'Area': row['area'], 'Finding': row['finding']})
        .toList(),
  );

  Widget _cell(String value, bool header) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    child: Text(
      value,
      style: TextStyle(
        fontSize: 12,
        fontWeight: header ? FontWeight.w700 : FontWeight.w400,
      ),
    ),
  );

  String _display(Object? value) =>
      value == null || value.toString().trim().isEmpty
      ? 'Missing'
      : value.toString();
}
