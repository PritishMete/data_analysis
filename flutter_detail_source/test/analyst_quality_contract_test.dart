import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/widgets/analyst_quality_message.dart';
import 'package:liquid_glass_widgets/detail_analysis_router.dart';

void main() {
  test(
    'decodes the live backend envelope through the structured chat contract',
    () {
      final backendEnvelope = <String, dynamic>{
        'analyst_answer': {
          'analysis_scope': 'customer',
          'response_type': 'analyst_quality_response',
          'short_answer':
              'I found 3 customer issue(s) worth addressing.',
          'short_answers': [
            'I found 3 customer issue(s) worth addressing.',
          ],
          'structured_response': {
            'response_type': 'analyst_quality_response',
            'intro': 'I found 3 customer issue(s) worth addressing.',
          },
          'structured_responses': {
            'customer': {
              'response_type': 'analyst_quality_response',
              'intro': 'I found 3 customer issue(s) worth addressing.',
              'confirmed_issues': [
                {
                  'number': 1,
                  'summary': 'Customer identifiers repeat.',
                  'facts': ['10 identifiers occur more than once.'],
                  'title': 'Duplicate Customer records',
                  'severity': 'HIGH',
                  'impact': 'Dimension joins need review.',
                  'examples': {
                    'columns': ['customer_id'],
                    'rows': [
                      {'customer_id': 'C001'},
                    ],
                  },
                },
              ],
              'minor_observations': [
                {'area': 'Names', 'finding': 'Placeholder-like values.'},
              ],
              'passed_checks': ['No orphan product references.'],
              'recommendations': ['Resolve duplicate customer keys.'],
            },
          },
        },
      };

      final decoded =
          jsonDecode(jsonEncode(backendEnvelope)) as Map<String, dynamic>;
      final answer = Map<String, dynamic>.from(
        decoded['analyst_answer'] as Map,
      );
      final response = AnalystQualityMessage.fromAnalystAnswer(answer);

      expect(response, isNotNull);
      expect(
        shouldAttachDetailAnalysisResult(
          DetailAnalysisIntent.customerDataQuality,
          false,
        ),
        isTrue,
      );
      expect(response!['response_type'], 'analyst_quality_response');
      expect(response['confirmed_issues'], hasLength(1));
      expect(
        response['confirmed_issues'][0]['examples']['rows'][0]['customer_id'],
        'C001',
      );
      expect(response['minor_observations'], hasLength(1));
      expect(
        response['passed_checks'],
        contains('No orphan product references.'),
      );
      expect(
        response['recommendations'],
        contains('Resolve duplicate customer keys.'),
      );

      // This is the same retention decision made before _ChatMessage enters
      // the active conversation list. It guards against silently flattening
      // the response into the legacy short_answer field.
      final chatMessageResult = shouldAttachDetailAnalysisResult(
        DetailAnalysisIntent.customerDataQuality,
        false,
      )
          ? response
          : null;
      expect(chatMessageResult, isNotNull);
      expect(chatMessageResult!['confirmed_issues'], isNotEmpty);
    },
  );

  test(
    'structured copy mirrors visible content and excludes flat fallback',
    () {
      final response = <String, dynamic>{
        'response_type': 'analyst_quality_response',
        'intro': 'I found 1 customer issue worth addressing.',
        'confirmed_issues': [
          {
            'number': 1,
            'title': 'Duplicate customer records',
            'severity': 'HIGH',
            'summary': 'Customer identifiers repeat.',
            'facts': ['10 identifiers occur more than once.'],
            'examples': {
              'columns': ['Customer ID', 'Name'],
              'rows': [
                {'Customer ID': 'C001', 'Name': 'Alex'},
              ],
            },
            'impact': 'Dimension joins need review.',
          },
        ],
        'minor_observations': [
          {'area': 'Names', 'finding': 'Values appear placeholder-like.'},
        ],
        'passed_checks': ['No populated IDs reference unknown customers.'],
        'recommendations': ['Resolve duplicate customer keys.'],
      };

      final copied = AnalystQualityMessage.toCopyText(response);

      expect(copied, contains('Duplicate customer records'));
      expect(copied, contains('Severity: HIGH'));
      expect(copied, contains('10 identifiers occur more than once.'));
      expect(copied, contains('C001'));
      expect(copied, contains('Alex'));
      expect(copied, contains('Impact'));
      expect(copied, contains('Dimension joins need review.'));
      expect(copied, contains('MINOR OBSERVATIONS'));
      expect(copied, contains('WHAT IS NOT WRONG'));
      expect(copied, contains('No populated IDs reference unknown customers.'));
      expect(copied, contains('RECOMMENDED NEXT STEPS'));
      expect(copied, contains('1. Resolve duplicate customer keys.'));
      expect(
        copied,
        isNot(contains('I found 3 customer issue(s) worth addressing.')),
      );
      expect(copied, isNot(contains('response_type')));
    },
  );
}
