import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;

/// Sends Power BI-exported tables to the local, read-only profiling endpoint.
class PowerBiDetailAnalysisService {
  static final Uri endpoint = Uri.parse(
    'http://127.0.0.1:8000/powerbi/detail-analysis',
  );
  static final Uri customerCleanEndpoint = Uri.parse(
    'http://127.0.0.1:8000/powerbi/customer-clean',
  );
  static final Uri productCleanEndpoint = Uri.parse(
    'http://127.0.0.1:8000/powerbi/product-clean',
  );
  static final Uri orderCleanEndpoint = Uri.parse(
    'http://127.0.0.1:8000/powerbi/order-clean',
  );
  static final Uri dateDimensionEndpoint = Uri.parse(
    'http://127.0.0.1:8000/powerbi/date-dimension',
  );
  static final Uri businessAnalysisEndpoint = Uri.parse(
    'http://127.0.0.1:8000/powerbi/business-analysis',
  );

  Future<Map<String, dynamic>> analyze(List<PlatformFile> files) async {
    if (files.isEmpty) {
      throw const FormatException('Select at least one dataset to analyze.');
    }

    final request = http.MultipartRequest('POST', endpoint);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        throw FormatException('Could not read ${file.name}.');
      }
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }

    final streamed = await request.send().timeout(const Duration(minutes: 5));
    final response = await http.Response.fromStream(streamed);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Detail Analysis returned an invalid response.',
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FormatException(
        decoded['error']?.toString() ?? 'Power BI Detail Analysis failed.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> cleanCustomer(List<PlatformFile> files) async {
    if (files.isEmpty) {
      throw const FormatException(
        'Select at least one dataset for customer cleaning.',
      );
    }
    final request = http.MultipartRequest('POST', customerCleanEndpoint);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(minutes: 5)),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw FormatException(
        decoded is Map
            ? decoded['error']?.toString() ?? 'Customer cleaning failed.'
            : 'Invalid customer cleaning response.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> cleanProduct(List<PlatformFile> files) async {
    if (files.isEmpty) {
      throw const FormatException(
        'Select at least one dataset for product cleaning.',
      );
    }
    final request = http.MultipartRequest('POST', productCleanEndpoint);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(minutes: 5)),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw FormatException(
        decoded is Map
            ? decoded['error']?.toString() ?? 'Product cleaning failed.'
            : 'Invalid product cleaning response.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> cleanOrders(List<PlatformFile> files) async {
    if (files.isEmpty) {
      throw const FormatException(
        'Select at least one dataset for order cleaning.',
      );
    }
    final request = http.MultipartRequest('POST', orderCleanEndpoint);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(minutes: 5)),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw FormatException(
        decoded is Map
            ? decoded['error']?.toString() ?? 'Order cleaning failed.'
            : 'Invalid order cleaning response.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> buildDateDimension(
    List<PlatformFile> files,
  ) async {
    if (files.isEmpty) {
      throw const FormatException(
        'Select at least one dataset for date dimension creation.',
      );
    }
    final request = http.MultipartRequest('POST', dateDimensionEndpoint);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(minutes: 5)),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw FormatException(
        decoded is Map
            ? decoded['error']?.toString() ?? 'Date dimension creation failed.'
            : 'Invalid date dimension response.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> analyzeBusinessModel(
    List<PlatformFile> files, {
    Map<String, dynamic> filters = const <String, dynamic>{},
    String? query,
    Map<String, dynamic> context = const <String, dynamic>{},
    Map<String, dynamic>? predicate,
  }) async {
    if (files.isEmpty) {
      throw const FormatException(
        'Select at least one dataset for business analysis.',
      );
    }
    final request = http.MultipartRequest('POST', businessAnalysisEndpoint);
    for (final entry in filters.entries) {
      if (entry.value != null && entry.value.toString().isNotEmpty) {
        request.fields[entry.key] = entry.value is List
            ? jsonEncode(entry.value)
            : entry.value.toString();
      }
    }
    if (query != null && query.trim().isNotEmpty)
      request.fields['query'] = query;
    if (context.isNotEmpty)
      request.fields['context_json'] = jsonEncode(context);
    if (predicate != null)
      request.fields['predicate_json'] = jsonEncode(predicate);
    request.fields['active_filters_json'] = jsonEncode(filters);
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(minutes: 5)),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw FormatException(
        decoded is Map
            ? decoded['error']?.toString() ?? 'Business analysis failed.'
            : 'Invalid business analysis response.',
      );
    }
    return decoded;
  }

  Future<Map<String, dynamic>> buildDashboard(
    List<PlatformFile> files, {
    int? year,
    String? region,
    String? category,
  }) async {
    if (files.isEmpty) {
      throw const FormatException(
        'Select at least one dataset for the dashboard.',
      );
    }
    final request = http.MultipartRequest(
      'POST',
      Uri.parse('http://127.0.0.1:8000/powerbi/dashboard'),
    );
    if (year != null) request.fields['year'] = year.toString();
    if (region != null) request.fields['region'] = region;
    if (category != null) request.fields['category'] = category;
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      request.files.add(
        http.MultipartFile.fromBytes('files', bytes, filename: file.name),
      );
    }
    final response = await http.Response.fromStream(
      await request.send().timeout(const Duration(minutes: 5)),
    );
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic> || decoded['success'] != true) {
      throw FormatException(
        decoded is Map
            ? decoded['error']?.toString() ?? 'Dashboard creation failed.'
            : 'Invalid dashboard response.',
      );
    }
    return decoded;
  }
}
