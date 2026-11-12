import 'package:flutter/material.dart';
import '../../app_colors.dart';

/// Shared reference catalog for chart selection and analytical wording.
class AnalyticsReferenceWorkspace extends StatefulWidget {
  const AnalyticsReferenceWorkspace({super.key});
  @override
  State<AnalyticsReferenceWorkspace> createState() => _AnalyticsReferenceWorkspaceState();
}

class _AnalyticsReferenceWorkspaceState extends State<AnalyticsReferenceWorkspace> {
  int tab = 0;
  String query = '';

  @override
  Widget build(BuildContext context) {
    final charts = tab == 0;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [TechColors.borderActive.withValues(alpha: .18), TechColors.panelBg]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: TechColors.borderActive.withValues(alpha: .3)),
          ),
          child: Row(children: [
            Icon(charts ? Icons.auto_graph : Icons.spellcheck, color: TechColors.borderActive, size: 28),
            const SizedBox(width: 12),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Analytics reference', style: TextStyle(color: TechColors.textPrimary, fontSize: 19, fontWeight: FontWeight.w800)),
              SizedBox(height: 4),
              Text('A reusable guide to charts and analytical language.', style: TextStyle(color: TechColors.textMuted, fontSize: 12)),
            ])),
          ]),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _GuideTab(label: 'Chart guide', icon: Icons.insert_chart_outlined, selected: charts, onTap: () => setState(() => tab = 0))),
          const SizedBox(width: 8),
          Expanded(child: _GuideTab(label: 'Analytical vocabulary', icon: Icons.menu_book_outlined, selected: !charts, onTap: () => setState(() => tab = 1))),
        ]),
        const SizedBox(height: 10),
        TextField(
          onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
          style: const TextStyle(color: TechColors.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            hintText: charts ? 'Search charts, categories or purpose' : 'Search actions or analytical terms',
            hintStyle: const TextStyle(color: TechColors.textMuted),
            prefixIcon: const Icon(Icons.search, color: TechColors.textMuted),
            filled: true, fillColor: TechColors.panelBg,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: TechColors.borderMuted)),
            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: TechColors.borderMuted)),
          ),
        ),
        const SizedBox(height: 10),
        Expanded(child: charts ? _ChartCatalog(query: query) : _VocabularyCatalog(query: query)),
      ]),
    );
  }
}

class _GuideTab extends StatelessWidget {
  const _GuideTab({required this.label, required this.icon, required this.selected, required this.onTap});
  final String label; final IconData icon; final bool selected; final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: selected ? TechColors.borderActive.withValues(alpha: .16) : TechColors.panelBg,
    borderRadius: BorderRadius.circular(11),
    child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(11), child: Container(
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), border: Border.all(color: selected ? TechColors.borderActive : TechColors.borderMuted)),
      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        Icon(icon, size: 16, color: selected ? TechColors.borderActive : TechColors.textMuted),
        const SizedBox(width: 6),
        Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: selected ? TechColors.textPrimary : TechColors.textMuted))),
      ]),
    )),
  );
}

class _Chart { const _Chart(this.name, this.purpose, this.icon); final String name, purpose; final IconData icon; }
class _ChartGroup { const _ChartGroup(this.name, this.icon, this.color, this.items); final String name; final IconData icon; final Color color; final List<_Chart> items; }

const _charts = <_ChartGroup>[
  _ChartGroup('Comparison', Icons.bar_chart, Color(0xFF3399FF), [
    _Chart('Bar chart', 'Compare categories.', Icons.bar_chart),
    _Chart('Column chart', 'Compare values across categories or periods.', Icons.insert_chart),
  ]),
  _ChartGroup('Trend', Icons.trending_up, Color(0xFF00C875), [
    _Chart('Line chart', 'Show trends over time.', Icons.show_chart),
    _Chart('Area chart', 'Show trends and magnitude over time.', Icons.show_chart),
  ]),
  _ChartGroup('Part-to-whole', Icons.pie_chart, Color(0xFF9B65F5), [
    _Chart('Pie chart', 'Show parts of a whole.', Icons.pie_chart),
    _Chart('Donut chart', 'Show proportions of a total.', Icons.donut_large),
    _Chart('Stacked bar chart', 'Compare category composition.', Icons.stacked_bar_chart),
  ]),
  _ChartGroup('Distribution', Icons.equalizer, Color(0xFFFFC247), [
    _Chart('Histogram', 'Show distribution of numerical data.', Icons.bar_chart),
    _Chart('Box plot', 'Show spread, median and outliers.', Icons.view_agenda),
  ]),
  _ChartGroup('Relationship', Icons.scatter_plot, Color(0xFF22B8C7), [
    _Chart('Scatter plot', 'Show relationship between two variables.', Icons.scatter_plot),
    _Chart('Bubble chart', 'Show three variables using position and size.', Icons.circle),
  ]),
  _ChartGroup('Contribution to change', Icons.stacked_line_chart, Color(0xFFFF6875), [
    _Chart('Waterfall chart', 'Explain increases and decreases in a total.', Icons.stacked_bar_chart),
  ]),
  _ChartGroup('Process stages', Icons.filter_alt, Color(0xFF9B65F5), [
    _Chart('Funnel chart', 'Show values across sequential stages.', Icons.filter_alt),
  ]),
  _ChartGroup('Geographic', Icons.place, Color(0xFF22B8C7), [
    _Chart('Map chart', 'Visualize geographic data.', Icons.map),
  ]),
  _ChartGroup('Target achievement', Icons.gps_fixed, Color(0xFFFF914D), [
    _Chart('Gauge chart', 'Show progress toward a target.', Icons.speed),
    _Chart('Bullet chart', 'Compare actual performance with a target.', Icons.linear_scale),
  ]),
  _ChartGroup('Other key charts', Icons.star, Color(0xFF8DA9C4), [
    _Chart('Treemap', 'Show hierarchical proportions.', Icons.grid_view),
    _Chart('Pareto chart', 'Identify biggest contributors to a problem.', Icons.leaderboard),
    _Chart('KPI card', 'Highlight a key metric.', Icons.monitor_heart),
  ]),
];

class _ChartCatalog extends StatelessWidget {
  const _ChartCatalog({required this.query}); final String query;
  @override
  Widget build(BuildContext context) {
    final groups = _charts.map((g) => (g: g, items: g.items.where((x) => query.isEmpty || g.name.toLowerCase().contains(query) || x.name.toLowerCase().contains(query) || x.purpose.toLowerCase().contains(query)).toList())).where((x) => x.items.isNotEmpty).toList();
    if (groups.isEmpty) return const _NoResults();
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12), itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 9),
      itemBuilder: (context, i) {
        final g = groups[i].g;
        return Container(
          decoration: BoxDecoration(color: TechColors.panelBg, borderRadius: BorderRadius.circular(13), border: Border.all(color: TechColors.borderMuted)),
          child: Column(children: [
            Padding(padding: const EdgeInsets.all(12), child: Row(children: [
              _IconTile(icon: g.icon, color: g.color),
              const SizedBox(width: 10),
              Expanded(child: Text(g.name, style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w800))),
              Text('${groups[i].items.length}', style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
            ])),
            for (var j = 0; j < groups[i].items.length; j++) ...[
              if (j > 0) Divider(height: 1, color: TechColors.borderMuted),
              Padding(padding: const EdgeInsets.fromLTRB(13, 9, 13, 10), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 32, height: 30, child: Icon(groups[i].items[j].icon, color: g.color, size: 21)),
                const SizedBox(width: 9),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(groups[i].items[j].name, style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(groups[i].items[j].purpose, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.35)),
                ])),
              ])),
            ],
          ]),
        );
      },
    );
  }
}

class _Words { const _Words(this.action, this.terms); final String action, terms; }
class _WordGroup { const _WordGroup(this.name, this.icon, this.color, this.items); final String name; final IconData icon; final Color color; final List<_Words> items; }

const _vocabulary = <_WordGroup>[
  _WordGroup('Growth / increase', Icons.trending_up, Color(0xFF00C875), [_Words('Went up', 'Increased · Climbed · Surged · Escalated')]),
  _WordGroup('Decline / decrease', Icons.trending_down, Color(0xFFFF6875), [_Words('Went down', 'Declined · Decreased · Contracted · Plunged')]),
  _WordGroup('No change', Icons.remove, Color(0xFF9AA6B2), [_Words('Stayed the same', 'Stable · Consistent · Stagnant · Plateaued')]),
  _WordGroup('Fluctuation', Icons.swap_vert, Color(0xFF9B65F5), [_Words('Moved up and down', 'Fluctuated · Volatile · Exhibited variance')]),
  _WordGroup('Extremes', Icons.compare_arrows, Color(0xFFFFC247), [
    _Words('Hit the top', 'Peaked · Reached a historical high · Maximized'),
    _Words('Hit the bottom', 'Bottomed out · Reached a trough · Minimized'),
  ]),
  _WordGroup('Scale', Icons.straighten, Color(0xFF00C875), [
    _Words('Big', 'Significant · Substantial · Pronounced · Material'),
    _Words('Small', 'Marginal · Incremental · Negligible · Nominal'),
  ]),
  _WordGroup('Patterns', Icons.show_chart, Color(0xFF22B8C7), [_Words('Normal / average', 'Baseline · Typical · Within standard deviation')]),
  _WordGroup('Pace', Icons.speed, Color(0xFF22B8C7), [
    _Words('Fast', 'Rapid · Accelerated · Exponential'),
    _Words('Slow', 'Gradual · Steady · Protracted'),
  ]),
  _WordGroup('Timeline', Icons.timelapse, Color(0xFFFF8A65), [
    _Words('Right away', 'Immediate · Instantaneous · Real-time'),
    _Words('Over time', 'Long-term · Chronological progression'),
  ]),
  _WordGroup('Evaluation', Icons.thumb_up_alt_outlined, Color(0xFF22B8C7), [
    _Words('Good', 'Positive trend · Favorable variance · Optimal'),
    _Words('Bad', 'Performance concern · Adverse trend · Suboptimal'),
  ]),
  _WordGroup('Expectations', Icons.star, Color(0xFF7C83F6), [
    _Words('Better than expected', 'Outperformed · Exceeded projections · Surpassed'),
    _Words('Worse than expected', 'Underperformed · Fell short · Lagged'),
  ]),
  _WordGroup('Context / inquiry', Icons.event_note, Color(0xFFFFA45B), [
    _Words('Compared to last year', 'Year-over-year (YoY) · Relative to prior period'),
    _Words('Leads to', 'Yields · Generates · Catalyzes · Translates to'),
    _Words('Look into', 'Investigate · Conduct a deep dive · Drill down'),
  ]),
  _WordGroup('Solution', Icons.build_circle_outlined, Color(0xFF8DA9C4), [
    _Words('Fix', 'Optimize · Remediate · Calibrate · Mitigate'),
  ]),
];

class _VocabularyCatalog extends StatelessWidget {
  const _VocabularyCatalog({required this.query}); final String query;
  @override
  Widget build(BuildContext context) {
    final groups = _vocabulary.map((g) => (g: g, items: g.items.where((x) => query.isEmpty || g.name.toLowerCase().contains(query) || x.action.toLowerCase().contains(query) || x.terms.toLowerCase().contains(query)).toList())).where((x) => x.items.isNotEmpty).toList();
    if (groups.isEmpty) return const _NoResults();
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12), itemCount: groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final g = groups[i].g;
        return Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: TechColors.panelBg, borderRadius: BorderRadius.circular(13), border: Border.all(color: TechColors.borderMuted)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _IconTile(icon: g.icon, color: g.color),
            const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(g.name, style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w800)),
              const SizedBox(height: 7),
              for (var j = 0; j < groups[i].items.length; j++) ...[
                if (j > 0) const SizedBox(height: 8),
                Text(groups[i].items[j].action, style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
                const SizedBox(height: 3),
                Text(groups[i].items[j].terms, style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, height: 1.4, fontWeight: FontWeight.w600)),
              ],
            ])),
          ]),
        );
      },
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({required this.icon, required this.color}); final IconData icon; final Color color;
  @override
  Widget build(BuildContext context) => Container(
    width: 35, height: 35,
    decoration: BoxDecoration(color: color.withValues(alpha: .14), borderRadius: BorderRadius.circular(10)),
    child: Icon(icon, color: color, size: 20),
  );
}

class _NoResults extends StatelessWidget {
  const _NoResults();
  @override
  Widget build(BuildContext context) => const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(Icons.search_off, color: TechColors.textMuted, size: 28),
    SizedBox(height: 8),
    Text('No matching reference terms', style: TextStyle(color: TechColors.textMuted, fontSize: 12)),
  ]));
}
