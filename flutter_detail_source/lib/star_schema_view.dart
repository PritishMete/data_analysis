import 'dart:math' as math;

import 'package:flutter/material.dart';

class StarSchemaView extends StatelessWidget {
  const StarSchemaView({super.key, required this.schema});

  final Map<String, dynamic> schema;

  List<Map<String, dynamic>> get _facts => _maps(schema['fact_tables']);
  List<Map<String, dynamic>> get _dimensions => _maps(schema['dimensions']);
  List<Map<String, dynamic>> get _relationships => _maps(schema['relationships']);

  @override
  Widget build(BuildContext context) {
    final fact = _facts.isEmpty ? <String, dynamic>{} : _facts.first;
    final dimensions = _dimensions;
    return Container(
      key: const ValueKey('native-star-schema'),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFF26334D)),
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFF0F172A), Color(0xFF082F49)],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Proposed Star Schema', style: TextStyle(color: Color(0xFF66E7FF), fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 5),
          const Text('Predefined layout; model content comes from the analysis contract.', style: TextStyle(color: Color(0xFF9AA8C0), fontSize: 12)),
          const SizedBox(height: 14),
          const Align(
            alignment: Alignment.topRight,
            child: _Legend(),
          ),
          const SizedBox(height: 8),
          LayoutBuilder(
            builder: (context, constraints) => _StarLayout(
              fact: fact,
              dimensions: dimensions,
              relationships: _relationships,
              narrow: constraints.maxWidth < 760,
            ),
          ),
          const SizedBox(height: 14),
          _ModelingNotes(fact: fact, dimensions: dimensions, relationships: _relationships),
        ],
      ),
    );
  }

  static List<Map<String, dynamic>> _maps(dynamic value) => value is List
      ? value.whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList()
      : const [];
}

class _StarLayout extends StatelessWidget {
  const _StarLayout({required this.fact, required this.dimensions, required this.relationships, required this.narrow});

  final Map<String, dynamic> fact;
  final List<Map<String, dynamic>> dimensions;
  final List<Map<String, dynamic>> relationships;
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    if (narrow) {
      return Column(
        key: const ValueKey('star-schema-narrow-layout'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FactTableCard(fact: fact),
          ...dimensions.map((dimension) => Padding(
                padding: const EdgeInsets.only(top: 10),
                child: _DimensionTableCard(
                  dimension: dimension,
                  relationship: _relationshipFor(dimension),
                ),
              )),
        ],
      );
    }

    final diagramHeight = dimensions.length > 8 ? 1100.0 : 784.0;
    return SizedBox(
      key: const ValueKey('star-schema-desktop-layout'),
      height: diagramHeight,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final factSize = Size(math.min(300.0, math.max(220.0, constraints.maxWidth * .24)), 220);
          final dimensionSize = Size(math.min(270.0, math.max(180.0, constraints.maxWidth * .20)), 190);
          final gap = math.max(64.0, math.min(100.0, constraints.maxWidth * .09));
          final geometry = _buildGeometry(
            Size(constraints.maxWidth, diagramHeight),
            factSize,
            dimensionSize,
            gap,
            dimensions,
          );
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  key: const ValueKey('relationship-painter'),
                  painter: _RelationshipPainter(
                    rects: geometry.rects,
                    factId: geometry.factId,
                    relationships: relationships,
                  ),
                ),
              ),
              _positionedCard(geometry.rects[geometry.factId]!, _FactTableCard(fact: fact)),
              ...dimensions.asMap().entries.map((entry) {
                final dimension = entry.value;
                final id = dimension['id']?.toString() ?? 'dim_${entry.key + 1}';
                return _positionedCard(
                  geometry.rects[id]!,
                  _DimensionTableCard(dimension: dimension, relationship: _relationshipFor(dimension)),
                );
              }),
            ],
          );
        },
      ),
    );
  }

  Map<String, dynamic> _relationshipFor(Map<String, dynamic> dimension) {
    final id = dimension['id']?.toString();
    return relationships.firstWhere(
      (item) => item['from']?.toString() == id,
      orElse: () => const <String, dynamic>{},
    );
  }

  static Widget _positionedCard(Rect rect, Widget child) => Positioned(
        left: rect.left,
        top: rect.top,
        width: rect.width,
        height: rect.height,
        child: child,
      );

  static _LayoutGeometry _buildGeometry(
    Size canvas,
    Size factSize,
    Size dimensionSize,
    double gap,
    List<Map<String, dynamic>> dimensions,
  ) {
    const factId = 'fact_1';
    final fact = Rect.fromCenter(
      center: Offset(canvas.width / 2, canvas.height / 2),
      width: factSize.width,
      height: factSize.height,
    );
    final rects = <String, Rect>{factId: fact};
    final slots = _slots(dimensions);
    final outerCount = slots.where((slot) => slot.startsWith('outer')).length;
    for (var index = 0; index < dimensions.length; index++) {
      final id = dimensions[index]['id']?.toString() ?? 'dim_${index + 1}';
      final slot = slots[index];
      Rect candidate;
      if (slot.startsWith('outer')) {
        final outerIndex = int.tryParse(slot.substring(5)) ?? 0;
        var radius = math.max(factSize.width, factSize.height) / 2 + dimensionSize.width / 2 + gap;
        do {
          final angle = 2 * math.pi * outerIndex / math.max(1, outerCount) - math.pi / 2;
          candidate = Rect.fromCenter(
            center: fact.center + Offset(radius * math.cos(angle), radius * math.sin(angle)),
            width: dimensionSize.width,
            height: dimensionSize.height,
          );
          radius += 28;
        } while ((candidate.overlaps(fact) || rects.values.any(candidate.overlaps)) && radius < math.max(canvas.width, canvas.height));
      } else {
        candidate = _slotRect(slot, fact, dimensionSize, gap);
      }
      rects[id] = candidate;
    }
    return _LayoutGeometry(factId: factId, rects: rects);
  }

  static Rect _slotRect(String slot, Rect fact, Size size, double gap) {
    final centerX = fact.center.dx;
    final centerY = fact.center.dy;
    return switch (slot) {
      'top' => Rect.fromCenter(center: Offset(centerX, fact.top - gap - size.height / 2), width: size.width, height: size.height),
      'bottom' => Rect.fromCenter(center: Offset(centerX, fact.bottom + gap + size.height / 2), width: size.width, height: size.height),
      'left' => Rect.fromCenter(center: Offset(fact.left - gap - size.width / 2, centerY), width: size.width, height: size.height),
      'right' => Rect.fromCenter(center: Offset(fact.right + gap + size.width / 2, centerY), width: size.width, height: size.height),
      'topRight' => Rect.fromCenter(center: Offset(fact.right + gap + size.width / 2, fact.top - gap - size.height / 2), width: size.width, height: size.height),
      'bottomRight' => Rect.fromCenter(center: Offset(fact.right + gap + size.width / 2, fact.bottom + gap + size.height / 2), width: size.width, height: size.height),
      'bottomLeft' => Rect.fromCenter(center: Offset(fact.left - gap - size.width / 2, fact.bottom + gap + size.height / 2), width: size.width, height: size.height),
      _ => Rect.fromCenter(center: Offset(fact.left - gap - size.width / 2, fact.top - gap - size.height / 2), width: size.width, height: size.height),
    };
  }

  static List<String> _slots(List<Map<String, dynamic>> dimensions) {
    const fallback = ['top', 'left', 'right', 'bottom', 'topRight', 'bottomRight', 'bottomLeft', 'topLeft'];
    final used = <String>{};
    final result = <String>[];
    for (final dimension in dimensions) {
      final role = dimension['semantic_role']?.toString().toLowerCase() ?? '';
      final preferred = role.contains('time') ? 'top' : role.contains('customer') || role.contains('person') ? 'left' : role.contains('product') || role.contains('item') ? 'right' : role.contains('geograph') || role.contains('location') ? 'bottom' : null;
      final slot = result.length >= 4
          ? 'outer${result.length - 4}'
          : preferred != null && !used.contains(preferred)
          ? preferred
          : fallback.firstWhere(
              (item) => !used.contains(item),
              orElse: () => 'outer${result.length - fallback.length}',
            );
      used.add(slot);
      result.add(slot);
    }
    return result;
  }

}

class _LayoutGeometry {
  const _LayoutGeometry({required this.factId, required this.rects});
  final String factId;
  final Map<String, Rect> rects;
}

class _FactTableCard extends StatelessWidget {
  const _FactTableCard({required this.fact});
  final Map<String, dynamic> fact;

  @override
  Widget build(BuildContext context) => _SchemaCard(
        key: const ValueKey('fact-card'),
        name: _text(fact, 'display_name', 'Fact table'),
        badge: 'FACT TABLE',
        accent: const Color(0xFF00E5FF),
        lines: [
          'Grain: ${_text(fact, 'grain', 'not identified')}',
          'Business key: ${_previewList(fact['business_key'], 2)}',
          'Foreign keys: ${_previewList(fact['foreign_keys'], 4)}',
          'Measures: ${_previewList(fact['measures'], 4)}',
        ],
      );
}

class _DimensionTableCard extends StatelessWidget {
  const _DimensionTableCard({required this.dimension, required this.relationship});
  final Map<String, dynamic> dimension;
  final Map<String, dynamic> relationship;

  @override
  Widget build(BuildContext context) {
    final status = relationship['status']?.toString() ?? dimension['quality_status']?.toString() ?? 'relationship issue';
    final warning = status != 'valid';
    return _SchemaCard(
      key: ValueKey('dimension-card-${dimension['id'] ?? dimension['display_name']}'),
      name: _text(dimension, 'display_name', 'Dimension'),
      badge: dimension['derived'] == true ? 'DERIVED DIMENSION' : 'DIMENSION',
      accent: warning ? const Color(0xFFFBBF24) : const Color(0xFF7DD3FC),
      lines: [
        'Key: ${_text(dimension, 'key', 'not identified')}',
        'Attributes: ${_previewList(dimension['attributes'], 5)}',
        if (dimension['derived'] == true) 'Derived from: ${_text(dimension, 'derived_from', 'source date field')}',
        if (warning) 'Warning: key cleanup required',
      ],
    );
  }
}

class _SchemaCard extends StatelessWidget {
  const _SchemaCard({super.key, required this.name, required this.badge, required this.lines, required this.accent});
  final String name;
  final String badge;
  final List<String> lines;
  final Color accent;

  @override
  Widget build(BuildContext context) => Card(
        color: const Color(0xF20F172A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: accent)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
            Text(badge, style: TextStyle(color: accent, fontSize: 10, letterSpacing: 1)),
            const Divider(color: Color(0xFF26334D)),
            ...lines.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  line,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11, height: 1.25),
                ),
              ),
            ),
          ]),
        ),
      );
}

class _RelationshipPainter extends CustomPainter {
  const _RelationshipPainter({required this.rects, required this.factId, required this.relationships});
  final Map<String, Rect> rects;
  final String factId;
  final List<Map<String, dynamic>> relationships;

  @override
  void paint(Canvas canvas, Size size) {
    final fact = rects[factId];
    if (fact == null) return;
    for (final relation in relationships) {
      final id = relation['from']?.toString();
      final dimension = id == null ? null : rects[id];
      if (dimension == null) continue;
      final valid = relation['status']?.toString() == 'valid' && relation['cardinality']?.toString() == 'one_to_many';
      final issue = relation.isEmpty || (!valid && relation['status']?.toString() != 'requires_key_cleanup');
      final color = issue ? const Color(0xFFF87171) : valid ? const Color(0xFF7DD3FC) : const Color(0xFFFBBF24);
      final paint = Paint()..color = color..strokeWidth = 2;
      if (!valid) paint.strokeCap = StrokeCap.square;
      final direction = (fact.center - dimension.center);
      final unit = direction / direction.distance;
      final start = _edgePoint(dimension, fact) + unit * 4;
      final edgeEnd = _edgePoint(fact, dimension);
      final end = edgeEnd - unit * 7;
      _drawLine(canvas, start, end, paint, valid);
      if (valid) {
        _arrowHead(canvas, end, unit, paint);
        _cardinalityLabel(canvas, start, end, '1', color, nearStart: true);
        _cardinalityLabel(canvas, start, end, '*', color, nearStart: false);
      } else {
        _warningLabel(canvas, start, end, unit, issue ? 'relationship issue' : 'key cleanup required', color);
      }
    }
  }

  static Offset _edgePoint(Rect from, Rect to) {
    final delta = to.center - from.center;
    if (delta == Offset.zero) return from.center;
    final scale = 1 / math.max(delta.dx.abs() / (from.width / 2), delta.dy.abs() / (from.height / 2));
    return from.center + delta * scale;
  }

  static void _arrowHead(Canvas canvas, Offset tip, Offset direction, Paint paint) {
    final perpendicular = Offset(-direction.dy, direction.dx);
    final path = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(tip.dx - direction.dx * 13 + perpendicular.dx * 6, tip.dy - direction.dy * 13 + perpendicular.dy * 6)
      ..lineTo(tip.dx - direction.dx * 13 - perpendicular.dx * 6, tip.dy - direction.dy * 13 - perpendicular.dy * 6)
      ..close();
    canvas.drawPath(path, paint);
  }

  static void _drawLine(Canvas canvas, Offset start, Offset end, Paint paint, bool solid) {
    if (solid) {
      canvas.drawLine(start, end, paint);
      return;
    }
    final distance = (end - start).distance;
    for (var offset = 0.0; offset < distance; offset += 12) {
      final a = start + (end - start) * (offset / distance);
      final b = start + (end - start) * (math.min(offset + 6, distance) / distance);
      canvas.drawLine(a, b, paint);
    }
  }

  static void _cardinalityLabel(Canvas canvas, Offset start, Offset end, String text, Color color, {required bool nearStart}) {
    final point = nearStart ? Offset.lerp(start, end, .18)! : Offset.lerp(start, end, .82)!;
    final painter = TextPainter(text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700)), textDirection: TextDirection.ltr)..layout(maxWidth: 130);
    painter.paint(canvas, point - Offset(painter.width / 2, painter.height / 2));
  }

  static void _warningLabel(Canvas canvas, Offset start, Offset end, Offset unit, String text, Color color) {
    final normal = Offset(-unit.dy, unit.dx);
    final midpoint = Offset.lerp(start, end, .5)! + normal * 16;
    final painter = TextPainter(
      text: TextSpan(text: text, style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 150);
    painter.paint(canvas, midpoint - Offset(painter.width / 2, painter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _RelationshipPainter oldDelegate) => oldDelegate.rects != rects || oldDelegate.relationships != relationships;
}

class _Legend extends StatelessWidget {
  const _Legend();

  @override
  Widget build(BuildContext context) => const Text('Legend: solid = validated 1 → many    dashed = key cleanup required    red = relationship issue', style: TextStyle(color: Color(0xFF9AA8C0), fontSize: 11));
}

class _ModelingNotes extends StatelessWidget {
  const _ModelingNotes({required this.fact, required this.dimensions, required this.relationships});
  final Map<String, dynamic> fact;
  final List<Map<String, dynamic>> dimensions;
  final List<Map<String, dynamic>> relationships;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Modeling notes', style: TextStyle(color: Color(0xFFA8B8D8), fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text('Fact grain: ${_text(fact, 'grain', 'not identified')}', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11)),
        ...relationships.map((item) => Text('${item['from'] ?? 'dimension'} → fact: ${item['status'] ?? 'relationship issue'}; null FKs ${item['null_fk_count'] ?? 0}; orphan rows ${item['orphan_count'] ?? 0}.', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11))),
        ...dimensions.where((item) => item['derived'] == true).map((item) => Text('Derived dimension: ${item['display_name'] ?? 'dimension'} from ${item['derived_from'] ?? 'source field'}.', style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 11))),
      ]);
}

String _text(Map<String, dynamic> value, String key, String fallback) => value[key]?.toString().trim().isNotEmpty == true ? value[key].toString() : fallback;
String _previewList(dynamic value, int maxItems) {
  if (value is! List || value.isEmpty) return 'none detected';
  final items = value.map((item) => item.toString()).toList();
  final shown = items.take(maxItems).join(', ');
  final remaining = items.length - math.min(items.length, maxItems);
  return remaining > 0 ? '$shown + $remaining more' : shown;
}
