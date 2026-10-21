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
        'Widget metric(String label, int value, IconData icon, Color accent) => Container(',
      ),
    );
    expect(
      peopleView,
      isNot(contains(
        'Widget metric(String label, int value, IconData icon, Color accent) => Expanded(',
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
    expect(peopleView, contains("value:v['location_id']?.toString()"));
    expect(peopleView, contains("value:v['section_id']?.toString()"));
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

  test('People directory exposes search and recoverable empty states', () {
    final source =
        File('lib/features/auth/management_shell.dart').readAsStringSync();
    final start = source.indexOf('Widget peopleView() {');
    final end = source.indexOf('\n  Widget ', start + 10);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));

    final peopleView = source.substring(start, end);
    expect(peopleView, contains("A clear view of your team, roles, and branch assignments."));
    expect(peopleView, contains("Search name, email, employee ID, or role"));
    expect(peopleView, contains("No people match your search"));
    expect(peopleView, contains("No people match these filters"));
    expect(peopleView, contains("No people yet"));
    expect(peopleView, contains("Clear search and filters"));
  });
}
