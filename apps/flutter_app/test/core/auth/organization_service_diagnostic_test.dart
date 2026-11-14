import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:liquid_glass_widgets/core/auth/authenticated_http.dart';

void main() {
  test('duplicate active branch is a user-facing registration error', () {
    final response = http.Response(
      '{"detail":"Branch identifier is already in use by an active branch."}',
      400,
    );

    expect(
      organizationServiceBusinessErrorMessage(response),
      'Branch identifier is already in use by an active branch.',
    );
  });

  test('other 400 responses remain diagnostic-worthy', () {
    final response = http.Response(
      '{"detail":"Another validation error."}',
      400,
    );

    expect(organizationServiceBusinessErrorMessage(response), isNull);
  });
}
