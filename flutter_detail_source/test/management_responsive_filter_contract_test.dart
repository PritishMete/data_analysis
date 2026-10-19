import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('People metrics use valid layout parents at every width', () {
    final source =
        File('lib/features/auth/management_shell.dart').readAsStringSync();
    final start = source.indexOf('Widget peopleView() {');
    final end = source.indexOf('\n  Widget ', start + 10);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final peopleView = source.substring(start, end);
    expect(
      peopleView,
      contains(
        'Widget metric(String label, int value, IconData icon) => _glassRow(',
      ),
    );
    expect(
      peopleView,
      isNot(contains(
        'Widget metric(String label, int value, IconData icon) => Expanded(',
      )),
    );
  });

  test('Organization and People filters use the same location and section IDs',
      () {
    final source =
        File('lib/features/auth/management_shell.dart').readAsStringSync();
    final start = source.indexOf('Widget peopleView() {');
    final end = source.indexOf('\n  Widget ', start + 10);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final peopleView = source.substring(start, end);
    expect(peopleView, contains("p['location_id']?.toString() != selectedLocation"));
    expect(peopleView, contains("p['section_id']?.toString() != selectedSection"));
    expect(peopleView, contains("value: location['location_id']?.toString()"));
    expect(peopleView, contains("value: section['section_id']?.toString()"));
  });

  test('Clear filters resets search, location, section, and role', () {
    final source =
        File('lib/features/auth/management_shell.dart').readAsStringSync();
    final start = source.indexOf('Widget peopleView() {');
    final end = source.indexOf('\n  Widget ', start + 10);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final peopleView = source.substring(start, end);
    expect(peopleView, contains("selectedRole = null;"));
    expect(peopleView, contains("selectedLocation = null;"));
    expect(peopleView, contains("selectedSection = null;"));
    expect(peopleView, contains("search = '';"));
  });
}
