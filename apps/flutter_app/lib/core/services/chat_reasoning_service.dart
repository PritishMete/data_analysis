import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

import '../../detail_analysis_router.dart';

/// Requests a privacy-safe intent plan. No file bytes, schemas, or values are
/// included; only abstract roles derived from the selected file extensions.
class ChatReasoningService {
  static final Uri endpoint = Uri.parse('http://127.0.0.1:8000/v1/chat/plan');

  Future<DetailAnalysisRoute?> plan(
    String query,
    List<PlatformFile> files, {
    DetailAnalysisRoute? previousRoute,
  }) async {
    final roles = <String>{};
    for (final file in files) {
      final name = file.name.toLowerCase();
      if (name.contains('customer')) roles.add('customer_dimension_candidate');
      if (name.contains('product')) roles.add('product_dimension_candidate');
      if (name.contains('order') || name.contains('transaction')) {
        roles.add('transaction_fact_candidate');
      }
      if (name.contains('region')) roles.add('region_dimension_candidate');
    }
    if (roles.isEmpty) roles.add('dataset');
    final context = <String, dynamic>{};
    if (previousRoute != null) {
      context['last_intent'] = previousRoute.intent.name;
      if (previousRoute.subIntent != null) {
        context['last_dataset_role'] = previousRoute.subIntent!.split(':').last;
      }
    }
    final response = await http
        .post(
          endpoint,
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({
            'query': query,
            'dataset_roles': roles.toList(),
            'capabilities': const [
              'duplicate_analysis',
              'key_integrity',
              'missing_value_analysis',
              'type_validation',
              'categorical_consistency',
              'cross_table_consistency',
              'cross_table_temporal_consistency',
              'quality_validation',
              'aggregate',
              'rank',
              'trend_analysis',
              'dashboard',
            ],
            'conversation_context': context,
          }),
        )
        .timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final decoded = jsonDecode(response.body);
    if (decoded is! Map || decoded['success'] != true) return null;
    final plan = decoded['plan'];
    if (plan is! Map) return null;
    return _toRoute(plan);
  }

  DetailAnalysisRoute? _toRoute(Map plan) {
    final intent = plan['intent'];
    switch (intent) {
      case 'data_quality_analysis':
      case 'detail_analysis':
        final scope = _scope(plan['dataset_scope']);
        return DetailAnalysisRoute(
          scope == 'customer'
              ? DetailAnalysisIntent.customerDataQuality
              : DetailAnalysisIntent.detailAnalysis,
          subIntent: scope == null ? null : 'data_quality:$scope',
        );
      case 'cleaning':
        return _cleaningRoute(_scope(plan['dataset_scope']));
      case 'dimensional_modeling':
        return const DetailAnalysisRoute(DetailAnalysisIntent.dateDimension);
      case 'business_analysis':
      case 'aggregation':
      case 'ranking':
      case 'trend_analysis':
        return const DetailAnalysisRoute(DetailAnalysisIntent.businessAnalysis);
      case 'dashboard':
        return const DetailAnalysisRoute(DetailAnalysisIntent.dashboard);
      default:
        return null;
    }
  }

  String? _scope(dynamic value) {
    if (value is! List || value.isEmpty || value.first is! String) return null;
    final role = value.first as String;
    if (role.startsWith('customer')) return 'customer';
    if (role.startsWith('product')) return 'product';
    if (role.startsWith('transaction')) return 'order';
    if (role.startsWith('region')) return 'region';
    return null;
  }

  DetailAnalysisRoute? _cleaningRoute(String? scope) {
    switch (scope) {
      case 'customer':
        return const DetailAnalysisRoute(DetailAnalysisIntent.customerCleaning);
      case 'product':
        return const DetailAnalysisRoute(DetailAnalysisIntent.productCleaning);
      case 'order':
        return const DetailAnalysisRoute(DetailAnalysisIntent.orderCleaning);
      default:
        return null;
    }
  }
}
