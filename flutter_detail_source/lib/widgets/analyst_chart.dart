import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app_colors.dart';

class AnalystChart extends StatelessWidget {
  const AnalystChart({super.key, required this.spec});
  final Map<String, dynamic> spec;

  @override
  Widget build(BuildContext context) {
    final series = (spec['series'] as List? ?? const []).whereType<Map>().toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Container(
        key: const Key('native-analyst-chart'),
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: .035), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white.withValues(alpha: .08))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(spec['title']?.toString() ?? 'Analysis chart', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Wrap(spacing: 12, children: series.map((item) => Text('● ${item['label'] ?? item['key']}', style: const TextStyle(fontSize: 11))).toList()),
          const SizedBox(height: 6),
          SizedBox(height: 210, width: double.infinity, child: CustomPaint(painter: _AnalystChartPainter(spec))),
        ]),
      ),
    );
  }
}

class _AnalystChartPainter extends CustomPainter {
  _AnalystChartPainter(this.spec);
  final Map<String, dynamic> spec;

  @override
  void paint(Canvas canvas, Size size) {
    final rows = (spec['rows'] as List? ?? const []).whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
    final series = (spec['series'] as List? ?? const []).whereType<Map>().map((row) => Map<String, dynamic>.from(row)).toList();
    if (rows.isEmpty || series.isEmpty) return;
    final plot = Rect.fromLTWH(42, 8, size.width - 52, size.height - 36);
    final values = <double>[];
    for (final row in rows) {
      for (final item in series) {
        final value = double.tryParse(row[item['key']]?.toString() ?? '');
        if (value != null) values.add(value);
      }
    }
    if (values.isEmpty) return;
    final maxValue = values.map((value) => value.abs()).reduce((a, b) => a > b ? a : b);
    final scale = maxValue == 0 ? 1.0 : maxValue;
    final axis = Paint()..color = Colors.white.withValues(alpha: .25)..strokeWidth = 1;
    canvas.drawLine(Offset(plot.left, plot.bottom), Offset(plot.right, plot.bottom), axis);
    final colors = [TechColors.borderActive, const Color(0xFFFFB86B), const Color(0xFF8BE9FD)];
    if (spec['chart_type'] == 'line') {
      for (var s = 0; s < series.length; s++) {
        final path = Path();
        for (var index = 0; index < rows.length; index++) {
          final value = double.tryParse(rows[index][series[s]['key']]?.toString() ?? '') ?? 0;
          final x = rows.length == 1 ? plot.center.dx : plot.left + plot.width * index / (rows.length - 1);
          final y = plot.bottom - (value / scale) * plot.height;
          if (index == 0) path.moveTo(x, y); else path.lineTo(x, y);
        }
        canvas.drawPath(path, Paint()..color = colors[s % colors.length]..style = PaintingStyle.stroke..strokeWidth = 2.5);
      }
    } else {
      final groupWidth = plot.width / rows.length;
      final barWidth = (groupWidth * .68) / series.length;
      for (var index = 0; index < rows.length; index++) {
        for (var s = 0; s < series.length; s++) {
          final value = double.tryParse(rows[index][series[s]['key']]?.toString() ?? '') ?? 0;
          final x = plot.left + groupWidth * index + groupWidth * .16 + s * barWidth;
          final y = value >= 0 ? plot.bottom - (value / scale) * plot.height : plot.bottom;
          canvas.drawRect(Rect.fromLTWH(x, y, barWidth - 2, plot.bottom - y), Paint()..color = colors[s % colors.length]);
        }
      }
    }
    final labels = rows.length > 12 ? [0, rows.length ~/ 2, rows.length - 1] : List<int>.generate(rows.length, (index) => index);
    for (final index in labels) {
      final value = rows[index][spec['x_role']?.toString() ?? 'entity']?.toString() ?? '';
      final text = TextPainter(text: TextSpan(text: value, style: const TextStyle(color: Colors.white70, fontSize: 9)), textDirection: ui.TextDirection.ltr)..layout(maxWidth: 70);
      final x = rows.length == 1 ? plot.center.dx - text.width / 2 : plot.left + plot.width * index / (rows.length - 1) - text.width / 2;
      text.paint(canvas, Offset(x.clamp(plot.left, plot.right - text.width), plot.bottom + 5));
    }
  }

  @override
  bool shouldRepaint(covariant _AnalystChartPainter oldDelegate) => oldDelegate.spec != spec;
}
