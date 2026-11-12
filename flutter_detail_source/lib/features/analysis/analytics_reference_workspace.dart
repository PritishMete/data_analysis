import 'package:flutter/material.dart';

import '../../app_colors.dart';

/// Dataset-independent analytical reference. Opening this screen performs no
/// dataset scan, registration, network request or data mutation.
class AnalyticsReferenceWorkspace extends StatefulWidget {
  const AnalyticsReferenceWorkspace({super.key, this.onBack});
  final VoidCallback? onBack;

  @override
  State<AnalyticsReferenceWorkspace> createState() => _AnalyticsReferenceWorkspaceState();
}

class _AnalyticsReferenceWorkspaceState extends State<AnalyticsReferenceWorkspace> {
  String query = '';
  String category = 'All categories';
  String question = 'Compare values across categories';

  static const questions = <String, String>{
    'Compare values across categories': 'Bar chart',
    'Track a measure over time': 'Line chart',
    'Understand numerical distribution': 'Histogram',
    'Identify outliers across groups': 'Box plot',
    'Explore a relationship between measures': 'Scatter plot',
    'Explain contribution to a change': 'Waterfall chart',
    'Compare actual against target': 'Bullet chart',
    'Show composition of a small total': '100% stacked bar chart',
    'Find the largest contributors': 'Pareto chart',
    'Show movement through process stages': 'Funnel chart',
    'Explore geographic concentration': 'Geographic heatmap',
  };

  @override
  Widget build(BuildContext context) {
    final categories = <String>{
      'All categories',
      ..._vocabulary.map((e) => e.category),
      ..._charts.map((e) => e.category),
      ..._methods.map((e) => e.category),
      ..._interpretations.map((e) => e.category),
    }.toList()..sort();
    categories.remove('All categories');
    categories.insert(0, 'All categories');

    return DefaultTabController(
      length: 5,
      child: ColoredBox(
        color: TechColors.bgBlack,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(onBack: widget.onBack),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: TechColors.panelBg,
                  border: Border.all(color: TechColors.borderMuted),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  labelColor: TechColors.borderActive,
                  unselectedLabelColor: TechColors.textMuted,
                  indicatorColor: TechColors.borderActive,
                  indicatorWeight: 3,
                  labelStyle: TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
                  tabs: [
                    Tab(text: 'Overview'),
                    Tab(text: 'Analytical vocabulary'),
                    Tab(text: 'Chart selection'),
                    Tab(text: 'Analytical methods'),
                    Tab(text: 'Interpret findings'),
                  ],
                ),
              ),
              const SizedBox(height: 9),
              LayoutBuilder(builder: (context, constraints) {
                final search = TextField(
                  onChanged: (v) => setState(() => query = v.trim().toLowerCase()),
                  style: const TextStyle(color: TechColors.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Search terms, charts, methods and examples',
                    hintStyle: const TextStyle(color: TechColors.textMuted, fontSize: 12),
                    prefixIcon: const Icon(Icons.search, color: TechColors.textMuted, size: 19),
                    suffixIcon: query.isEmpty ? null : IconButton(
                      tooltip: 'Clear search',
                      onPressed: () => setState(() => query = ''),
                      icon: const Icon(Icons.close, color: TechColors.textMuted, size: 17),
                    ),
                    filled: true,
                    fillColor: TechColors.panelBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    border: _border,
                    enabledBorder: _border,
                    focusedBorder: _focusBorder,
                  ),
                );
                final filter = DropdownButtonFormField<String>(
                  value: category,
                  isExpanded: true,
                  dropdownColor: TechColors.panelBg,
                  style: const TextStyle(color: TechColors.textPrimary, fontSize: 12),
                  decoration: InputDecoration(
                    labelText: 'Category',
                    labelStyle: const TextStyle(color: TechColors.textMuted, fontSize: 11),
                    filled: true,
                    fillColor: TechColors.panelBg,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                    border: _border,
                    enabledBorder: _border,
                    focusedBorder: _focusBorder,
                  ),
                  items: categories.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))).toList(),
                  onChanged: (v) => setState(() => category = v ?? 'All categories'),
                );
                if (constraints.maxWidth < 560) {
                  return Column(children: [search, const SizedBox(height: 8), filter]);
                }
                return Row(children: [
                  Expanded(flex: 3, child: search),
                  const SizedBox(width: 9),
                  Expanded(flex: 2, child: filter),
                ]);
              }),
              const SizedBox(height: 9),
              Expanded(
                child: TabBarView(children: [
                  _OverviewTab(question: question, onQuestionChanged: (v) => setState(() => question = v)),
                  _Catalog(entries: _vocabulary, query: query, category: category, empty: 'No vocabulary terms match this search.'),
                  _Catalog(entries: _charts, query: query, category: category, empty: 'No chart types match this search.'),
                  _Catalog(entries: _methods, query: query, category: category, empty: 'No analytical methods match this search.'),
                  _Interpretations(query: query, category: category),
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final _border = OutlineInputBorder(
  borderRadius: BorderRadius.circular(8),
  borderSide: const BorderSide(color: TechColors.borderMuted),
);
final _focusBorder = OutlineInputBorder(
  borderRadius: BorderRadius.circular(8),
  borderSide: const BorderSide(color: TechColors.borderActive, width: 1.3),
);

class _Header extends StatelessWidget {
  const _Header({this.onBack});
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(color: TechColors.panelBg, border: Border.all(color: TechColors.borderMuted), borderRadius: BorderRadius.circular(10)),
    child: Row(children: [
      if (onBack != null) ...[
        IconButton(tooltip: 'Back to Data Workspace', onPressed: onBack, icon: const Icon(Icons.arrow_back, color: TechColors.textPrimary, size: 19)),
        const SizedBox(width: 3),
      ],
      Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(color: TechColors.borderActive.withValues(alpha: .12), borderRadius: BorderRadius.circular(8)),
        child: const Icon(Icons.insights_outlined, color: TechColors.borderActive, size: 23),
      ),
      const SizedBox(width: 12),
      const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Analytics learning workspace', style: TextStyle(color: TechColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w900)),
        SizedBox(height: 4),
        Text('Choose the right language, method and visual; explain what the evidence means.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
      ])),
      if (MediaQuery.of(context).size.width > 520)
        Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(color: TechColors.statusGreen.withValues(alpha: .08), border: Border.all(color: TechColors.statusGreen.withValues(alpha: .35)), borderRadius: BorderRadius.circular(5)),
        child: const Text('REFERENCE', style: TextStyle(color: TechColors.statusGreen, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .7)),
      ),
    ]),
  );
}

class _Entry {
  const _Entry(this.category, this.title, this.meaning, this.when, this.example, {
    this.data = '', this.question = '', this.strengths = '', this.limits = '', this.note = '',
  });
  final String category, title, meaning, when, example, data, question, strengths, limits, note;
  String get searchable => [category, title, meaning, when, example, data, question, strengths, limits, note].join(' ').toLowerCase();
}

const _vocabulary = <_Entry>[
  _Entry('Trend and movement','Growth / increase','A value becomes higher than its earlier or reference value.','Use “increase” for a neutral change; state the comparison period and quantify it.','Revenue increased by 12% compared with the previous quarter.',note:'An increase is not automatically favourable: higher expenses may be undesirable.'),
  _Entry('Trend and movement','Surged','Increased rapidly over a relatively short period.','Use when the size or rate of increase is unusually high relative to a meaningful baseline.','Monthly revenue surged by 35% following the campaign.',note:'A surge describes movement; it does not prove what caused it.'),
  _Entry('Trend and movement','Decline / decrease','A value becomes lower than its earlier or reference value.','Use for a downward movement; identify whether it is one-period change or sustained trend.','Order volume declined by 8% year over year.'),
  _Entry('Trend and movement','Stable / no change','A measure remains approximately at the same level over a stated period.','Use when variation is small relative to the measure and decision context.','Customer churn remained broadly stable at 3.2%.',note:'Stable does not mean healthy; compare the level with a target or benchmark.'),
  _Entry('Trend and movement','Fluctuation','Repeated or irregular movement above and below a typical level.','Use when a series varies rather than following a smooth direction.','Daily demand fluctuated considerably during the holiday period.'),
  _Entry('Trend and movement','Peak','The highest observed value within a defined period or dataset.','State the time window or comparison set.','Daily orders peaked at 1,240 on 18 October.'),
  _Entry('Trend and movement','Trough','The lowest observed value within a defined period or dataset.','Use for the low point in a time series or cycle.','Production reached a trough in the second week of June.'),
  _Entry('Trend and movement','Recovery','A measure rises after a prior decline, moving toward its earlier level or target.','State whether the former level has actually been regained.','Sales recovered to 96% of their pre-disruption level.'),
  _Entry('Trend and movement','Reversal','The direction of a trend changes from rising to falling, or vice versa.','Use when direction changes, not merely when values fluctuate.','The upward sales trend reversed in the final month.'),
  _Entry('Trend and movement','Acceleration','The rate of increase becomes faster over time.','Use when successive changes show a rising growth rate, not simply a rising value.','Revenue growth accelerated from 4% to 9% across consecutive quarters.'),
  _Entry('Trend and movement','Deceleration','The rate of growth or decline slows.','Use when growth continues but at a slower rate, or a decline becomes less rapid.','Subscriber growth decelerated from 14% to 6%.'),
  _Entry('Magnitude and scale','Significant','Important or large enough to matter in context; in statistics it can mean a test meets a defined threshold.','Clarify practical importance versus statistical significance.','The 2.1-point conversion improvement was commercially material.',note:'Statistical significance is not the same as practical significance.'),
  _Entry('Magnitude and scale','Substantial','Large in amount or degree relative to the context.','Use for a clearly meaningful magnitude and provide the amount where possible.','The branch recorded a substantial reduction in processing time.'),
  _Entry('Magnitude and scale','Material','Large enough to influence a decision, financial statement or business judgement.','Use when the effect matters to a decision threshold or reporting context.','The cost variance is material to the quarterly operating plan.'),
  _Entry('Magnitude and scale','Marginal','Small or limited in size, often close to a threshold.','Use for a small difference; do not imply statistical insignificance.','The new workflow produced a marginal increase in throughput.'),
  _Entry('Magnitude and scale','Incremental','A small additional change or improvement added to an existing level.','Use for stepwise gains or additions.','The team delivered incremental productivity improvements each month.'),
  _Entry('Magnitude and scale','Negligible','So small that it has little practical effect in the stated context.','Use only when the effect is immaterial for the decision.','The rounding difference was negligible relative to total spend.'),
  _Entry('Magnitude and scale','Nominal','A face-value amount; in some contexts, an amount not adjusted for inflation.','Use carefully: nominal does not necessarily mean small.','Nominal revenue rose 5%, while inflation-adjusted revenue rose 1%.'),
  _Entry('Magnitude and scale','Proportional','Changing in a consistent ratio to another quantity.','Use when the relationship is ratio-based, not merely when values move together.','Support staffing increased proportionally with active customer volume.'),
  _Entry('Distribution and variation','Average (mean)','The arithmetic sum of values divided by the number of observations.','Use when the mean is representative and extreme values do not dominate.','Average order value was ₹1,850.', data: 'Numeric observations', question: 'What is the arithmetic average?', strengths: 'Uses every value.', limits: 'Sensitive to extreme observations.'),
  _Entry('Distribution and variation','Median','The middle observation after values are sorted.','Use for skewed data such as salaries, transaction values or delivery times.','The median delivery time was 2.4 days.', data: 'Ordered numeric observations', question: 'What is the central observation?', strengths: 'Robust to extreme values.', limits: 'Does not describe the full spread.'),
  _Entry('Distribution and variation','Mode','The most frequently occurring value or category.','Use to identify the most common response, product or category.','The most common ticket category was account access.'),
  _Entry('Distribution and variation','Variance','The average squared deviation from the mean, using a population or sample definition.','Use as a dispersion measure in statistical work when squared units are acceptable.','The sample variance of daily demand increased in peak season.'),
  _Entry('Distribution and variation','Standard deviation','The square root of variance; describes spread around the mean in original units.','Use when mean-based spread is appropriate for the distribution.','Demand averaged 500 units with a standard deviation of 42 units.'),
  _Entry('Distribution and variation','Skewness','A measure of distribution asymmetry.','Use to describe whether a distribution has a longer tail on one side.','Transaction values were positively skewed, with a few very large orders.',note:'Positive skew generally has a longer right tail; negative skew a longer left tail.'),
  _Entry('Distribution and variation','Kurtosis','A measure related to tail heaviness and extreme observations relative to a reference distribution.','Use when tail behaviour matters; state the kurtosis convention.','The return series showed elevated excess kurtosis and heavier tails.'),
  _Entry('Distribution and variation','Outlier','An observation unusually distant from the rest under a chosen rule or model.','Check data quality and context; an outlier may be valid or erroneous.','One transaction was flagged as an outlier for manual review.'),
  _Entry('Distribution and variation','Quartile','One of three cut points dividing sorted data into four groups.','Use to summarize spread and compare lower, middle and upper portions.','The third quartile of resolution time was 4.8 hours.'),
  _Entry('Distribution and variation','Percentile','A value at or below which a stated percentage of observations falls.','Use for service levels, ranking and distribution thresholds.','The 90th percentile response time was 1.8 seconds.'),
  _Entry('Distribution and variation','Distribution','The pattern of values, including frequency, centre, spread, shape and tails.','Use when the full pattern matters more than one summary statistic.','Customer spend followed a right-skewed distribution.'),
  _Entry('Distribution and variation','Deviation','The difference between an observation and a reference value, often the mean or target.','Always state the reference point; distinguish deviation from standard deviation.','Actual cost deviated by ₹42,000 from budget.'),
  _Entry('Performance and evaluation','Outperformed','Achieved a better result than a defined comparator.','Name the benchmark or peer group and ensure like-for-like scope.','The East branch outperformed the regional average on on-time delivery.'),
  _Entry('Performance and evaluation','Underperformed','Achieved a result below a defined expectation, benchmark or peer reference.','Use with a clear comparator and fair, like-for-like scope.','The branch underperformed its quarterly sales target by 7%.'),
  _Entry('Performance and evaluation','Exceeded expectations','Delivered a result better than the agreed expectation or target.','Use when the expectation was defined before observing the result.','Retention exceeded the 92% target, reaching 94.1%.'),
  _Entry('Performance and evaluation','Fell short','Did not reach a stated target or expected level.','Use for a measurable gap against an explicit goal.','The project fell short of its 30-day completion target.'),
  _Entry('Performance and evaluation','Optimal','Best under a stated objective and constraints; not universally best.','State the objective and relevant constraints.','The schedule was optimal for minimizing overtime while meeting demand.'),
  _Entry('Performance and evaluation','Suboptimal','Not the best available result under the stated objective and constraints.','Use when a better feasible alternative exists or performance is below an agreed standard.','The current allocation is suboptimal during peak-hour demand.'),
  _Entry('Performance and evaluation','Favorable','A variance or outcome that benefits the stated objective.','Interpret direction in context: lower cost may be favourable; lower revenue is not.','Operating expenses were ₹1.2 lakh below budget, a favourable variance.'),
  _Entry('Performance and evaluation','Adverse','An outcome or variance that works against the stated objective.','Use with the relevant target or business consequence.','An adverse cost variance widened during the quarter.'),
  _Entry('Performance and evaluation','Efficiency','Output achieved relative to inputs consumed.','Use an explicit ratio such as units per labour hour or cost per transaction.','Processing efficiency improved to 18 cases per employee-hour.'),
  _Entry('Performance and evaluation','Productivity','The amount of output produced per unit of input over a period.','Compare output and resource input using consistent definitions.','Team productivity increased from 24 to 28 completed cases per week.'),
  _Entry('Comparison and context','Year-over-Year (YoY)','Compares a period with the corresponding period one year earlier.','Use to reduce seasonal distortion in annual business cycles.','October revenue grew 9% YoY.'),
  _Entry('Comparison and context','Month-over-Month (MoM)','Compares a month with the immediately preceding month.','Use for short-term movement; account for month length and seasonality.','Active users increased 3.5% MoM.'),
  _Entry('Comparison and context','Quarter-over-Quarter (QoQ)','Compares one fiscal or calendar quarter with the immediately preceding quarter.','Disclose the fiscal-quarter convention.','Gross margin improved 1.4 percentage points QoQ.'),
  _Entry('Comparison and context','Period-over-Period','Compares a defined reporting period with the prior comparable period.','State the exact period pair.','Returns fell 6% period over period.'),
  _Entry('Comparison and context','Benchmark','A reference standard, peer group or external comparator.','Choose a relevant, current comparator measured consistently.','The branch conversion rate was 2.3 points below the industry benchmark.'),
  _Entry('Comparison and context','Baseline','The starting or reference measurement against which later results are assessed.','Define date, scope and calculation method.','The project baseline was 14 days per onboarding case.'),
  _Entry('Comparison and context','Relative change','Change expressed as a proportion or percentage of the starting value.','Use (new − old) ÷ old × 100 and state the base period.','Revenue increased 30%, from ₹10 lakh to ₹13 lakh.'),
  _Entry('Comparison and context','Absolute change','The arithmetic difference between two values, in original units.','Use to communicate the actual amount added or lost.','Revenue increased by ₹3 lakh, from ₹10 lakh to ₹13 lakh.'),
  _Entry('Comparison and context','Variance analysis','Examines the difference between actual and budget, forecast, target or prior period.','Quantify the gap and investigate its components.','Actual operating cost was ₹2.4 lakh above budget.'),
  _Entry('Relationships and causes','Correlation','A statistical measure of direction and strength of association between variables.','Choose Pearson, Spearman or another method to suit the data.','Ad spend and sales showed a positive correlation.', data: 'Paired numeric observations', question: 'Do variables co-move?', strengths: 'Summarizes association.', limits: 'Correlation alone does not establish causation.'),
  _Entry('Relationships and causes','Association','A general relationship or dependence between variables or categories.','Use when describing a relationship without asserting a causal mechanism.','Late deliveries were associated with lower customer satisfaction.'),
  _Entry('Relationships and causes','Positive correlation','Two variables tend to move in the same direction.','Use when higher values of one tend to accompany higher values of another.','Order volume and packing hours had a positive correlation.'),
  _Entry('Relationships and causes','Negative correlation','Two variables tend to move in opposite directions.','Use when higher values of one tend to accompany lower values of another.','Wait time and satisfaction showed a negative correlation.'),
  _Entry('Relationships and causes','Causation','A change in one factor produces a change in another under a defensible causal design.','Require credible evidence such as a randomized experiment or robust quasi-experiment.','A controlled experiment estimated that reminders caused a 4-point lift in attendance.'),
  _Entry('Relationships and causes','Contributing factor','A condition that may help explain an outcome, often alongside other factors.','Use for plausible influences while causal evidence is being assessed.','Staffing shortages were a contributing factor in delayed dispatches.'),
  _Entry('Relationships and causes','Driver','A variable or operational factor that materially influences a result.','Use when evidence supports influence; otherwise say candidate driver.','Repeat-purchase frequency was a key revenue driver.'),
  _Entry('Relationships and causes','Impact','The effect or consequence associated with a change, action or event.','Quantify the outcome and distinguish estimated impact from observed difference.','The policy change reduced average handling time by 11%.'),
  _Entry('Relationships and causes','Dependency','A condition or variable on which another process or outcome relies.','Use for operational, technical or analytical prerequisites.','Forecast accuracy depends on complete, consistently dated sales history.'),
  _Entry('Relationships and causes','Attribution','A method of assigning credit or contribution to touchpoints, factors or sources.','Name the attribution model and its assumptions.','Last-click attribution assigned 42% of conversions to paid search.'),
  _Entry('Forecasting and prediction','Projection','A calculated future value based on stated assumptions or an extrapolated pattern.','Make assumptions explicit; treat the result as conditional.','At the current run rate, the projection is ₹1.8 crore for the year.'),
  _Entry('Forecasting and prediction','Forecast','An estimate of a future outcome using history, assumptions and a model.','Use when estimating the most plausible future under current information.','The demand forecast indicates 8,500 units next month.'),
  _Entry('Forecasting and prediction','Extrapolation','Extending an observed pattern beyond the range of available data.','Use cautiously when the underlying process is reasonably stable.','A straight-line extrapolation suggests further growth if conditions persist.'),
  _Entry('Forecasting and prediction','Trendline','A fitted line or curve summarizing the general direction of data.','Use to show a broad pattern, not a guaranteed future path.','The trendline indicates a gradual rise in monthly demand.'),
  _Entry('Forecasting and prediction','Seasonality','A recurring pattern tied to a known calendar or seasonal cycle.','Use when periodic effects repeat at a regular interval.','Sales peak each festive quarter.'),
  _Entry('Forecasting and prediction','Moving average','An average recalculated over a rolling window of recent observations.','State the window; use to smooth noise while retaining broad direction.','The 7-day moving average reduced daily demand volatility.'),
  _Entry('Forecasting and prediction','Confidence interval','An interval procedure that captures a fixed parameter at a stated coverage rate under repeated sampling assumptions.','Use for an estimated parameter; distinguish from a prediction interval for future observations.','The estimated lift was 2.4 points with a 95% confidence interval of 0.8–4.0 points.'),
  _Entry('Forecasting and prediction','Prediction','An estimated value or class for a new or future case.','Communicate uncertainty and validation performance.','The model predicts elevated renewal risk for this account.'),
  _Entry('Forecasting and prediction','Scenario analysis','Compares outcomes under different internally consistent assumptions.','Use when future conditions are uncertain and decisions depend on alternatives.','The downside scenario assumes 10% lower demand and 5% higher input costs.'),
  _Entry('Data quality and reliability','Completeness','The extent to which required records and fields are present.','State denominator and required-field definition.','Customer email completeness was 97.6%.'),
  _Entry('Data quality and reliability','Accuracy','How closely recorded values match true or accepted reference values.','Use when values can be checked against a trusted source.','A sample audit found 99.2% accuracy in invoice amounts.'),
  _Entry('Data quality and reliability','Consistency','Whether values and formats follow the same rules across records and systems.','Use for standardized definitions, units, codes and formats.','Date formats were inconsistent across source files.'),
  _Entry('Data quality and reliability','Validity','Whether values conform to defined rules, ranges, formats or business constraints.','Use for rule-based checks; valid data can still be inaccurate.','All invoice dates passed permitted date-range validation.'),
  _Entry('Data quality and reliability','Uniqueness','Whether each entity or event appears only as intended, without unintended duplicates.','Define the unique key or duplicate-detection rule.','Customer IDs were unique after duplicate resolution.'),
  _Entry('Data quality and reliability','Missing values','Fields for which no value is recorded or available.','Report count and percentage; assess missingness before imputation.','Eleven percent of records lacked a verified region.'),
  _Entry('Data quality and reliability','Duplicate records','Multiple rows representing the same entity or event under the chosen matching rule.','Define the entity key and distinguish duplicates from legitimate repeated events.','Duplicate invoice IDs accounted for 0.7% of imported rows.'),
  _Entry('Data quality and reliability','Data integrity','The degree to which data remains accurate, complete, consistent and protected through its lifecycle.','Use for end-to-end trustworthiness, constraints and controlled transformations.','Referential checks and audit logs helped preserve data integrity.'),
];

_Entry _c(String cat, String title, String meaning, String when, String data, String question, String strengths, String limits, String example) =>
    _Entry(cat, title, meaning, when, example, data: data, question: question, strengths: strengths, limits: limits);
final _charts = <_Entry>[
  _c('Comparison','Bar chart','Horizontal bars compare values across discrete categories.','Use when category names are long or ranking matters.','Category plus numeric measure.','Which categories are larger or smaller?','Easy to rank and compare; long labels fit.','Too many categories create a long chart; use a consistent scale.','Compare revenue across branches.'),
  _c('Comparison','Column chart','Vertical bars compare values across categories or ordered periods.','Use for a modest number of categories or periods.','Category or period plus numeric measure.','How do values differ across groups or periods?','Familiar and effective for clear differences.','Long labels are awkward; bar baselines should normally start at zero.','Compare monthly sales across four products.'),
  _c('Comparison','Grouped bar chart','Places bars side by side to compare series within each category.','Use when direct comparison between a small number of series matters.','Category, series and numeric measure.','How does each series compare within a category?','Preserves individual series values.','Crowds with many series or categories.','Compare actual and budget revenue by branch.'),
  _c('Comparison','Stacked bar chart','Stacks component values into a total for each category.','Use when both total size and composition matter.','Category, component and additive numeric measure.','What makes up each category total?','Shows totals and composition together.','Only the baseline segment is easy to compare precisely.','Show expense categories within each branch total.'),
  _c('Comparison','Lollipop chart','Shows a point value connected to a baseline by a thin line.','Use for a clean ranked comparison.','Category and numeric measure.','Which categories rank highest or lowest?','Less visual ink than thick bars.','Less familiar; small differences may be hard to perceive.','Rank branches by satisfaction.'),
  _c('Trend','Line chart','Connects ordered observations to show change over time or sequence.','Use for time series with consistent intervals.','Ordered time and numeric series.','How is the measure changing over time?','Shows direction and turning points.','Irregular intervals can mislead; too many lines clutter.','Track weekly revenue for a year.'),
  _c('Trend','Area chart','Fills area beneath a line to emphasize magnitude over an ordered axis.','Use when total volume matters as well as trend.','Ordered time and numeric measure.','How does volume evolve over time?','Emphasizes scale and continuity.','Filled areas can obscure overlap and exaggerate visual weight.','Show daily website visits.'),
  _c('Trend','Stacked area chart','Stacks time-series areas to show components of a changing total.','Use for a few non-negative additive series.','Time plus additive component measures.','How does total and composition change over time?','Shows total movement and contribution.','Middle layers lack a common baseline.','Show product-family sales mix by month.'),
  _c('Trend','Sparkline','A compact, axis-light trend line beside a metric.','Use for quick context in tables and KPI summaries.','Short ordered numeric series.','What has the recent direction looked like?','Compact for scanning many metrics.','Not suited to detailed comparison or precise reading.','Show recent orders beside each branch KPI.'),
  _c('Trend','Moving average chart','Plots a rolling average to smooth short-term variation.','Use when noise hides the trend; state window length.','Ordered numeric observations and rolling window.','What is the smoothed direction?','Reduces short-term noise.','Lags turning points and may hide brief changes.','Compare daily demand with its 7-day average.'),
  _c('Part-to-whole','Pie chart','Slices represent parts of one whole.','Use only for a few mutually exclusive categories summing to a meaningful total.','One non-negative total split into a few categories.','What share does each category represent?','Recognizable for simple composition.','Avoid many categories, negative values or unrelated totals; angles are hard to compare.','Share of revenue from three product lines.'),
  _c('Part-to-whole','Donut chart','A pie-like composition chart with a central hole.','Use for a few mutually exclusive shares, often with a total in the centre.','One non-negative total split into a few categories.','How is the total divided?','Can display a central total.','Slice comparisons remain imprecise.','Customer mix across three plans.'),
  _c('Part-to-whole','Treemap','Nested rectangles sized by values show hierarchical composition.','Use for many categories or hierarchy when space is limited.','Hierarchy and non-negative size measure.','Which groups occupy the largest share?','Compact hierarchy and relative size.','Small rectangles and similar values are hard to compare.','Expense allocation by department and type.'),
  _c('Part-to-whole','100% stacked bar chart','Normalizes each stacked bar to 100% to compare composition.','Use when proportions matter more than absolute totals.','Category, component and non-negative additive values.','How does composition differ between groups?','Makes percentage mix comparable.','Hides group size; middle segments are difficult to compare.','Payment-method mix across branches.'),
  _c('Distribution','Histogram','Groups continuous observations into bins and displays frequencies.','Use to inspect shape, spread, skew and multiple peaks.','One numeric variable and binning rule.','How are numerical observations distributed?','Reveals shape and concentration.','Appearance depends on bin width and boundaries.','Inspect invoice amounts.'),
  _c('Distribution','Box plot','Summarizes median, quartiles, interquartile range and possible outliers.','Use to compare spread and outliers across groups.','Numeric variable and optional group.','Which groups vary more and where are unusual values?','Compact group comparison.','Hides multimodality and most individual observations.','Compare resolution times by branch.'),
  _c('Distribution','Violin plot','Combines a density shape with summary information.','Use to compare distribution shapes when sample sizes support density estimates.','Numeric observations and optional group.','Do groups have different shapes or multiple modes?','Shows more shape detail than a box plot.','Density can be unstable for small samples.','Compare waiting-time distributions by location.'),
  _c('Distribution','Density plot','A smoothed estimate of a continuous variable distribution.','Use to compare shapes without histogram bin edges.','Continuous numeric variable, optionally grouped.','Where are values concentrated?','Smoothly reveals shape and multiple peaks.','Bandwidth changes appearance; height is not a raw count.','Compare order values across channels.'),
  _c('Distribution','Frequency polygon','Connects frequencies at bin midpoints.','Use to compare frequency shapes for multiple groups.','Binned numeric observations and frequencies.','How do group frequency patterns differ?','Overlays distributions clearly.','Depends on bin choice and may be less familiar.','Compare training-score distributions by team.'),
  _c('Relationship','Scatter plot','Plots paired numeric observations on two axes.','Use to explore association, clusters, non-linearity and outliers.','Two numeric variables per observation.','Do two measures move together or form patterns?','Shows individual points and non-linear patterns.','Overplotting hides dense regions; correlation is not causation.','Explore discount rate versus order margin.'),
  _c('Relationship','Bubble chart','Uses position for two variables and bubble size for a third.','Use when a third quantitative measure adds context.','Two numeric axes plus non-negative size measure.','How do three numeric measures vary together?','Adds a third dimension.','Area comparisons are imprecise; bubbles overlap.','Compare branch sales, margin and customer count.'),
  _c('Relationship','Heatmap','Colour intensity encodes values in a matrix or grid.','Use to scan patterns across two categorical or ordered dimensions.','Two dimensions and numeric measure.','Where are high and low values concentrated?','Highlights clusters and hotspots.','Colour scale and perception affect interpretation.','Ticket volume by hour and weekday.'),
  _c('Relationship','Correlation matrix','A table or heatmap of pairwise correlation coefficients.','Use for exploratory screening of pairwise associations.','Multiple numeric variables and specified correlation method.','Which variables have stronger positive or negative associations?','Summarizes many pairs compactly.','Not causal; can hide confounding and non-linear links.','Review sales, discount, traffic and margin.'),
  _c('Contribution and decomposition','Waterfall chart','Sequential positive and negative contributions bridge a start value to an end value.','Use to explain the bridge between two totals.','Starting total, signed changes and ending total.','Which factors explain the change?','Makes positive and negative contributions explicit.','Requires correct running-total logic and reconciliation.','Bridge budget profit to actual profit.'),
  _c('Contribution and decomposition','Pareto chart','Ranks categories by contribution with a cumulative-percentage line.','Use to identify categories contributing most to a total problem or outcome.','Categories and non-negative contribution values.','Which categories account for most of the total?','Prioritizes improvement opportunities.','The 80/20 pattern is not guaranteed; define denominator.','Rank defect types by total defects.'),
  _c('Contribution and decomposition','Decomposition chart','Breaks an aggregate metric into components or dimensions.','Use to drill from a headline metric into component contributions.','A measure with additive components or defined decomposition.','Which segments account for the overall result?','Connects headline outcomes to segments.','Some decompositions are model-dependent, not causal.','Break revenue change into volume, price and mix.'),
  _c('Process','Funnel chart','Shows counts or values across sequential process stages.','Use when each stage represents a comparable cohort.','Ordered stages and stage counts or conversion rates.','At which stage are the largest drop-offs?','Makes stage loss visible.','Stage populations must be comparable.','Leads through qualified, proposal and sale.'),
  _c('Process','Sankey diagram','Weighted flows between nodes show how quantities move.','Use when flow paths and transfers matter.','Source node, target node and non-negative flow weight.','Where do resources or transactions flow?','Reveals dominant paths and diversions.','Many nodes and crossing links become unreadable.','Customer movement between channels and plans.'),
  _c('Geographic','Choropleth map','Colours geographic regions according to a normalized or comparable rate.','Use for rates or ratios, not raw counts when populations differ.','Geographic boundary and comparable rate.','Where are rates higher or lower?','Shows regional spatial patterns.','Large regions dominate visually; denominator matters.','Complaints per 1,000 customers by district.'),
  _c('Geographic','Symbol map','Places sized or styled markers at geographic locations.','Use for point events, sites or counts.','Latitude/longitude or geocoded locations and measure.','Where are sites or events concentrated?','Preserves location and can show magnitude.','Overlapping symbols can mislead.','Branch locations sized by customer visits.'),
  _c('Geographic','Geographic heatmap','Shows spatial concentration using aggregated intensity.','Use for dense point events and hotspot exploration.','Geocoded observations and aggregation or density rule.','Where do events cluster spatially?','Highlights hotspots.','Smoothing radius changes appearance; not a regional rate.','Delivery-request hotspots in a city.'),
  _c('Target and performance','KPI card','Displays a key metric with context such as target, period or change.','Use for headline metrics that need quick scanning.','Defined metric, value, unit, period and comparator.','What is the current value and is it on track?','Fast to read on dashboards.','Without context or comparator the number has little meaning.','Monthly recurring revenue with target and YoY change.'),
  _c('Target and performance','Gauge chart','Shows a value on a bounded arc or dial.','Use sparingly for one bounded progress measure with meaningful thresholds.','Actual, minimum, maximum and optional threshold bands.','Where does the value sit in a defined range?','Familiar status communication.','Consumes space; imprecise for comparisons.','Capacity utilization against safe limits.'),
  _c('Target and performance','Bullet chart','Compares a primary measure with a target and qualitative performance ranges.','Use for compact, precise actual-versus-target reporting.','Actual, target and defined qualitative ranges.','How far is actual performance from target?','Compact and more precise than a gauge.','Threshold bands need meaningful definitions.','Branch revenue actual versus budget.'),
  _c('Target and performance','Actual vs target chart','Displays achieved values alongside planned or target values.','Use to track goal attainment across categories or periods.','Actual and target on a common scale.','Where are targets met, exceeded or missed?','Makes performance gaps explicit.','Targets need consistent scope and definition.','Monthly hiring actuals versus plan.'),
  _c('Advanced analytical charts','Control chart','Plots a process measure over time with a centre line and statistically derived control limits.','Use to distinguish common-cause variation from special-cause signals.','Time-ordered process data and suitable control-chart model.','Is the process statistically stable?','Supports process monitoring.','Control limits are not specification limits or business targets.','Monitor daily packaging defects per batch.'),
  _c('Advanced analytical charts','Run chart','Plots observations in time order, often with a median reference line.','Use as a first step to identify shifts, trends and runs.','Time-ordered observations.','Is the process showing a non-random pattern?','Simple and assumption-light.','No control limits or full stability assessment.','Track daily customer wait time.'),
  _c('Advanced analytical charts','Radar chart','Plots multiple measures on radial axes.','Use for few profiles and consistently scaled dimensions.','Comparable normalized measures per entity.','How does a profile vary across dimensions?','Shows a multi-metric profile.','Area and angle mislead; clutter increases quickly.','Compare branches across service, cost and quality.'),
  _c('Advanced analytical charts','Gantt chart','Shows tasks as bars across a time axis with start, finish and optional dependencies.','Use for project schedules and overlapping workstreams.','Task, start, end and optional dependency.','When does each activity occur and what depends on what?','Communicates schedule and overlap.','Large plans become dense; critical path needs explicit encoding.','Plan discovery, build and rollout activities.'),
  _c('Advanced analytical charts','Calendar heatmap','Uses a calendar grid with colour intensity for daily values.','Use to reveal weekday, seasonal and event patterns.','Date and daily measure.','Which dates or recurring periods stand out?','Connects daily variation with calendar context.','Colour scale and missing days need clear treatment.','Daily order volume across a year.'),
  _c('Advanced analytical charts','Candlestick chart','Shows open, high, low and close values for each interval.','Use for market prices or data with meaningful OHLC structure.','Time interval and open, high, low, close.','What was the price range and direction within each interval?','Encodes intraperiod range and closing direction.','Requires valid OHLC data; can be noisy at unsuitable scales.','Review daily share-price movement.'),
];

_Entry _m(String cat, String title, String meaning, String when, String example, String data, String question) =>
    _Entry(cat, title, meaning, when, example, data: data, question: question);
final _methods = <_Entry>[
  _m('Descriptive analytics','Mean','Arithmetic average of observations.','Use when the mean is representative and outliers are understood.','Average order value was ₹1,850.','Numeric observations','What is the average level?'),
  _m('Descriptive analytics','Median','Middle value in sorted observations.','Use for skewed values or when extremes distort the mean.','Median resolution time was 2.4 hours.','Ordered numeric observations','What is the central observation?'),
  _m('Descriptive analytics','Mode','Most frequently occurring value or category.','Use to identify the most common response.','The most common support issue was password reset.','Categorical or discrete values','What occurs most often?'),
  _m('Descriptive analytics','Minimum and maximum','Smallest and largest observed values.','Use to establish endpoints and inspect extremes.','Monthly sales ranged from ₹4.2 lakh to ₹12.8 lakh.','Numeric observations','What are the observed endpoints?'),
  _m('Descriptive analytics','Range','Maximum minus minimum.','Use for quick total spread alongside robust measures.','Delivery time ranged from 1 to 12 days.','Numeric observations','How wide is the observed span?'),
  _m('Descriptive analytics','Standard deviation','Square root of variance, expressed in original units.','Use when mean-based spread is appropriate.','Demand averaged 500 units with a 42-unit standard deviation.','Numeric observations','How dispersed are values around the mean?'),
  _m('Descriptive analytics','Frequency','Number of times a value, event or category occurs.','Use to count events and build frequency tables.','There were 126 delivery delays this month.','Event or category records','How often does this occur?'),
  _m('Descriptive analytics','Distribution analysis','Examines shape, centre, spread and tails.','Use before choosing summary statistics or thresholds.','Invoice amounts were right-skewed, so median was reported with mean.','Numeric variable','What pattern do observations follow?'),
  _m('Diagnostic analytics','Variance analysis','Compares actual performance with budget, forecast, target or prior period.','Use to quantify a gap and prioritize investigation.','Actual expense exceeded budget by ₹2.4 lakh.','Actual and comparable reference','Where and by how much did actual differ?'),
  _m('Diagnostic analytics','Root cause analysis','Structured investigation to identify underlying mechanisms behind a problem.','Define the problem, validate evidence and test candidate causes.','A 5-Why review traced late dispatches to stock-reconciliation delays.','Process evidence and segmented measures','Which underlying factors explain the failure?'),
  _m('Diagnostic analytics','Correlation analysis','Measures strength and direction of association between variables.','Use for exploration and hypothesis generation, not proof of cause.','Discount rate and gross margin showed a negative association.','Paired observations','Which variables tend to move together?'),
  _m('Diagnostic analytics','Contribution analysis','Quantifies how segments or components contribute to an aggregate result.','Use to prioritize the largest contributors to change or cost.','Three product lines accounted for 72% of incremental revenue.','Total and additive components','Which segments explain most of the total?'),
  _m('Diagnostic analytics','Segmentation','Splits a population into meaningful groups with shared characteristics.','Use to reveal differences hidden by overall averages.','Retention was compared by tenure and acquisition channel.','Records and grouping attributes','Which groups behave differently?'),
  _m('Diagnostic analytics','Drill-down analysis','Moves from aggregate results into progressively detailed dimensions.','Preserve the same metric definition at each level.','A regional sales gap was traced to one branch and product category.','Consistent measure and hierarchical dimensions','Where exactly is the pattern concentrated?'),
  _m('Predictive analytics','Linear regression','Estimates a linear relationship between an outcome and predictors.','Check linearity, residuals, assumptions and validation.','Estimate sales associated with ad spend while controlling for seasonality.','Outcome, predictors and historical observations','How does the outcome vary with predictors?'),
  _m('Predictive analytics','Time-series forecasting','Uses time-ordered history, trend and seasonality to estimate future values.','Use regular or model-supported intervals and sufficient history.','Forecast weekly demand for inventory planning.','Time-stamped observations','What values are likely in future periods?'),
  _m('Predictive analytics','Moving averages','Smooths a series by averaging observations in a rolling window.','Use for short-term smoothing or a simple baseline forecast.','A 4-week moving average reduced weekly demand noise.','Ordered numeric series and window','What is the recent smoothed level?'),
  _m('Predictive analytics','Trend analysis','Identifies long-run direction and structural movement.','Check seasonality, structural breaks and definition changes.','Three years of data showed gradual improvement in repeat purchase rate.','Ordered observations','What broad direction is emerging?'),
  _m('Predictive analytics','Classification','Predicts a discrete class or category, often with a probability score.','Use when outcome classes are defined and labelled consistently.','Classify support tickets by urgency for human review.','Labelled examples and features','Which category is this case likely to belong to?'),
  _m('Predictive analytics','Forecast intervals','Intervals express uncertainty around a future observation or forecast.','Use with a point estimate; disclose coverage and horizon.','Demand forecast was 8,500 units, with an 80% prediction interval of 7,900–9,200.','Forecast model and error assumptions','How uncertain is the future value?'),
  _m('Prescriptive analytics','Optimization','Finds the best feasible decision under an objective and constraints.','Use when trade-offs and constraints can be expressed quantitatively.','Optimize delivery routes within vehicle capacity limits.','Decision variables, objective and constraints','Which feasible choice best meets the objective?'),
  _m('Prescriptive analytics','Scenario planning','Compares coherent alternative futures and their implications.','Use when key drivers are uncertain and contingency plans matter.','Compare base, downside and upside demand before staffing decisions.','Assumptions, scenarios and outcomes','What happens under plausible conditions?'),
  _m('Prescriptive analytics','Sensitivity analysis','Tests how results change when assumptions or inputs vary.','Use to identify assumptions that most influence a decision.','Test profit when material costs rise by 2%, 5% or 8%.','Model inputs and plausible ranges','Which assumptions have the greatest effect?'),
  _m('Prescriptive analytics','Decision analysis','Structures choices, outcomes, probabilities and consequences.','Use for uncertain choices and explicit trade-offs.','Compare supplier contracts using expected cost and delivery risk.','Alternatives, outcomes, likelihoods and criteria','Which option has the best expected outcome?'),
  _m('Prescriptive analytics','Resource allocation','Assigns limited people, time, budget or capacity across competing needs.','Use when demand competes for scarce resources.','Allocate service staff using forecast demand and skill requirements.','Capacity, demand, priorities and constraints','Where should limited resources be assigned?'),
];

const _interpretations = <_Entry>[
  _Entry('Revenue','Revenue growth','Revenue increased from ₹10 lakh to ₹13 lakh.','Calculate (new − old) ÷ old × 100 and retain absolute change.','Revenue increased by ₹3 lakh, representing 30% growth compared with the previous period.',note:'Check whether growth came from volume, price, mix or one-off transactions.'),
  _Entry('Profitability','Revenue up, profit down','Sales increased while profit decreased.','Compare gross margin, discounts, product mix and operating costs before proposing an explanation.','Despite revenue growth, profitability deteriorated, potentially indicating higher operating costs or margin compression.',note:'“Potentially” signals a hypothesis; confirm it with cost and margin analysis.'),
  _Entry('Sales','Sales target variance','Actual sales were ₹92 lakh against a ₹1 crore target.','Quantify the gap in currency and percentage terms using target as denominator.','Sales finished ₹8 lakh below target, achieving 92% of the planned amount.',note:'Segment by branch, product and period to locate the largest contribution.'),
  _Entry('Expenses','Expense overrun','Actual expenses exceeded budget by ₹1.5 lakh.','Compare like-for-like scope and classify the variance by cost type.','Operating expenses recorded an adverse variance of ₹1.5 lakh against budget.',note:'Separate price, volume, timing and exceptional-cost effects.'),
  _Entry('Productivity','Output per input','A team completed 240 cases using 30 staff-days.','Divide comparable output by a clearly defined input unit.','The team processed an average of 8 cases per staff-day.',note:'Check case complexity and quality; higher throughput alone may not mean better performance.'),
  _Entry('Employee performance','Performance against benchmark','An employee completed 42 cases against a team median of 50.','Compare like-for-like workload, time, quality and available hours.','The employee completed 16% fewer cases than the team median; case complexity and quality should be reviewed before drawing a conclusion.',note:'A benchmark difference is not evidence by itself of an individual capability issue.'),
  _Entry('Customer retention','Retention movement','Retention changed from 90% to 93%.','State cohort, observation window and whether change is percentage points or percent.','Customer retention improved by 3 percentage points, from 90% to 93%.',note:'That is a 3.33% relative increase from the starting rate.'),
  _Entry('Operational efficiency','Cycle-time improvement','Average processing time fell from 5 hours to 4 hours.','Compare equivalent case types and report absolute and relative reduction.','Average processing time decreased by 1 hour (20%), indicating improved cycle-time efficiency.',note:'Validate that quality, rework and service levels did not deteriorate.'),
  _Entry('Branch comparison','Branch below benchmark','One branch performs materially below the others.','Use a comparable metric and account for branch size, customer mix and operating conditions.','The branch recorded a substantial negative performance variance against the organizational benchmark.',note:'Drill down to identify the product, period or process behind the gap.'),
  _Entry('Forecasting','Forecast with uncertainty','The model estimates 8,500 orders next month.','Report point estimate, horizon, interval and assumptions together.','The model forecasts 8,500 orders next month, with an 80% prediction interval of 7,900–9,200 under current demand conditions.',note:'Use the range for capacity planning and refresh it as new observations arrive.'),
];

class _Catalog extends StatelessWidget {
  const _Catalog({required this.entries, required this.query, required this.category, required this.empty});
  final List<_Entry> entries;
  final String query, category, empty;

  @override
  Widget build(BuildContext context) {
    final visible = entries.where((e) =>
      (query.isEmpty || e.searchable.contains(query)) &&
      (category == 'All categories' || category == e.category)).toList();
    if (visible.isEmpty) return _Empty(empty);
    final groups = <String, List<_Entry>>{};
    for (final entry in visible) {
      groups.putIfAbsent(entry.category, () => []).add(entry);
    }
    return ListView(padding: const EdgeInsets.only(bottom: 18), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(2, 5, 2, 9),
        child: Text(visible.length.toString() + ' reference entries', style: const TextStyle(color: TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700)),
      ),
      for (final group in groups.entries) ...[
        _Heading(group.key, group.value.length),
        const SizedBox(height: 6),
        for (final entry in group.value) _EntryTile(entry),
        const SizedBox(height: 10),
      ],
    ]);
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile(this.entry);
  final _Entry entry;
  @override
  Widget build(BuildContext context) => Card(
    color: TechColors.panelBg,
    elevation: 0,
    margin: const EdgeInsets.only(bottom: 6),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9), side: const BorderSide(color: TechColors.borderMuted)),
    child: ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 1),
      childrenPadding: const EdgeInsets.fromLTRB(13, 0, 13, 13),
      iconColor: TechColors.borderActive,
      collapsedIconColor: TechColors.textMuted,
      title: Text(entry.title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w800)),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(entry.meaning, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
      ),
      children: [
        _Detail('When to use', entry.when),
        if (entry.data.isNotEmpty) _Detail('Data required', entry.data),
        if (entry.question.isNotEmpty) _Detail('Question answered', entry.question),
        if (entry.strengths.isNotEmpty) _Detail('Strengths', entry.strengths, color: TechColors.statusGreen),
        if (entry.limits.isNotEmpty) _Detail('Limitations', entry.limits, color: TechColors.statusAmber),
        _Detail('Professional example', entry.example, color: TechColors.borderActive),
        if (entry.note.isNotEmpty) _Detail('Interpretation note', entry.note, color: TechColors.statusAmber),
      ],
    ),
  );
}

class _Detail extends StatelessWidget {
  const _Detail(this.label, this.value, {this.color = TechColors.borderActive});
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label.toUpperCase(), style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .7)),
      const SizedBox(height: 4),
      Text(value, style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, height: 1.5)),
    ]),
  );
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, this.count);
  final String title;
  final int count;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(children: [
      Expanded(child: Text(title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w900))),
      Text(count.toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700)),
    ]),
  );
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({required this.question, required this.onQuestionChanged});
  final String question;
  final ValueChanged<String> onQuestionChanged;

  @override
  Widget build(BuildContext context) {
    final chart = _AnalyticsReferenceWorkspaceState.questions[question] ?? 'Bar chart';
    final explanation = _charts.firstWhere((e) => e.title == chart).meaning;
    return ListView(padding: const EdgeInsets.only(bottom: 18), children: [
      const _Panel(title: 'From data to a defensible decision', body: 'A good analysis connects a clearly defined measure to a suitable method, an honest interpretation and an action that can be tested.'),
      const SizedBox(height: 11),
      LayoutBuilder(builder: (context, constraints) {
        const cards = [
          _StepCard('01', 'Describe', 'What happened? Summarize level, movement and distribution.', Icons.query_stats),
          _StepCard('02', 'Diagnose', 'Where did it happen and which factors may explain the pattern?', Icons.manage_search),
          _StepCard('03', 'Predict', 'What could happen next, and how uncertain is the estimate?', Icons.trending_up),
          _StepCard('04', 'Prescribe', 'Which action best meets the objective and constraints?', Icons.task_alt),
        ];
        final columns = constraints.maxWidth > 850 ? 4 : constraints.maxWidth > 520 ? 2 : 1;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: cards.map((card) => SizedBox(
            width: (constraints.maxWidth - (columns - 1) * 8) / columns,
            child: card,
          )).toList(),
        );
      }),
      const SizedBox(height: 17),
      const _Heading('Chart selection helper', 11),
      const SizedBox(height: 7),
      Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(color: TechColors.panelBg, border: Border.all(color: TechColors.borderMuted), borderRadius: BorderRadius.circular(9)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('What are you trying to understand?', style: TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            value: question,
            isExpanded: true,
            dropdownColor: TechColors.panelBg,
            style: const TextStyle(color: TechColors.textPrimary, fontSize: 12),
            decoration: InputDecoration(filled: true, fillColor: TechColors.bgBlack, border: _border, enabledBorder: _border, contentPadding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10)),
            items: _AnalyticsReferenceWorkspaceState.questions.keys.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis))).toList(),
            onChanged: (v) { if (v != null) onQuestionChanged(v); },
          ),
          const SizedBox(height: 11),
          Row(children: [
            const Icon(Icons.lightbulb_outline, color: TechColors.statusAmber, size: 19),
            const SizedBox(width: 8),
            Expanded(child: Text('Recommended: $chart', style: const TextStyle(color: TechColors.borderActive, fontSize: 14, fontWeight: FontWeight.w900))),
          ]),
          const SizedBox(height: 5),
          Text(explanation, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.5)),
        ]),
      ),
      const SizedBox(height: 17),
      const _Heading('Quick chart decisions', 8),
      const SizedBox(height: 7),
      const _Quick('Compare categories', 'Bar chart', 'Use horizontal bars for long labels or ranking.'),
      const _Quick('Track performance over time', 'Line chart', 'Keep time intervals ordered and consistent.'),
      const _Quick('Understand numerical distribution', 'Histogram', 'Inspect skew, spread, clusters and multiple peaks.'),
      const _Quick('Identify outliers', 'Box plot', 'Investigate flagged points; do not automatically delete them.'),
      const _Quick('Examine relationships', 'Scatter plot', 'Association is not proof of causation.'),
      const _Quick('Show contribution to change', 'Waterfall chart', 'Use signed components that reconcile to the ending total.'),
      const _Quick('Compare actual against target', 'Bullet chart', 'Show actual, target and meaningful performance bands.'),
      const _Quick('Prioritize largest contributors', 'Pareto chart', 'Rank contributions and show cumulative share.'),
      const SizedBox(height: 12),
      const _Warning('Interpret with care', 'Correlation does not prove causation. A percentage change needs a stated baseline. Statistical significance is not automatically commercial importance. Disclose period, population, unit and denominator.'),
    ]);
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.body});
  final String title, body;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(color: TechColors.panelBg, border: Border.all(color: TechColors.borderActive.withValues(alpha: .32)), borderRadius: BorderRadius.circular(9)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w900)),
      const SizedBox(height: 6),
      Text(body, style: const TextStyle(color: TechColors.textMuted, fontSize: 12, height: 1.5)),
    ]),
  );
}

class _StepCard extends StatelessWidget {
  const _StepCard(this.number, this.title, this.body, this.icon);
  final String number, title, body;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: TechColors.panelBg, border: Border.all(color: TechColors.borderMuted), borderRadius: BorderRadius.circular(9)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(icon, color: TechColors.borderActive, size: 18),
        const Spacer(),
        Text(number, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.w800)),
      ]),
      const SizedBox(height: 8),
      Text(title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      Text(body, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.45)),
    ]),
  );
}

class _Quick extends StatelessWidget {
  const _Quick(this.question, this.chart, this.note);
  final String question, chart, note;
  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: 6),
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 10),
    decoration: BoxDecoration(color: TechColors.panelBg, border: Border.all(color: TechColors.borderMuted), borderRadius: BorderRadius.circular(8)),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(flex: 3, child: Text(question, style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700))),
        const SizedBox(width: 8),
        Expanded(flex: 2, child: Text(chart, style: const TextStyle(color: TechColors.borderActive, fontSize: 11, fontWeight: FontWeight.w900))),
      ]),
      const SizedBox(height: 4),
      Text(note, style: const TextStyle(color: TechColors.textMuted, fontSize: 10)),
    ]),
  );
}

class _Warning extends StatelessWidget {
  const _Warning(this.title, this.body);
  final String title, body;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(color: TechColors.statusAmber.withValues(alpha: .07), border: Border.all(color: TechColors.statusAmber.withValues(alpha: .3)), borderRadius: BorderRadius.circular(8)),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Icon(Icons.info_outline, color: TechColors.statusAmber, size: 18),
      const SizedBox(width: 8),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: const TextStyle(color: TechColors.statusAmber, fontSize: 12, fontWeight: FontWeight.w900)),
        const SizedBox(height: 4),
        Text(body, style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, height: 1.5)),
      ])),
    ]),
  );
}

class _Interpretations extends StatelessWidget {
  const _Interpretations({required this.query, required this.category});
  final String query, category;
  @override
  Widget build(BuildContext context) {
    final visible = _interpretations.where((e) =>
      (query.isEmpty || e.searchable.contains(query)) &&
      (category == 'All categories' || category == e.category)).toList();
    if (visible.isEmpty) return const _Empty('No interpretation examples match this search.');
    return ListView(padding: const EdgeInsets.only(bottom: 18), children: [
      const _Panel(title: 'Turn an observation into a useful statement', body: 'Separate what the data shows from what you think it means. State evidence first, identify possible explanations as hypotheses, and call a cause confirmed only when the evidence supports that conclusion.'),
      const SizedBox(height: 10),
      for (final entry in visible) ...[
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: TechColors.panelBg, border: Border.all(color: TechColors.borderMuted), borderRadius: BorderRadius.circular(9)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(entry.category.toUpperCase(), style: const TextStyle(color: TechColors.borderActive, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: .8)),
            const SizedBox(height: 5),
            Text(entry.title, style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            _Detail('Observation', entry.meaning),
            _Detail('How to analyse', entry.when),
            _Detail('Professional interpretation', entry.example, color: TechColors.statusGreen),
            if (entry.note.isNotEmpty) _Detail('Next analytical step', entry.note, color: TechColors.statusAmber),
          ]),
        ),
        const SizedBox(height: 7),
      ],
      const _Warning('Four levels of analytical language', 'Observation: the measured fact. Interpretation: what the pattern may indicate. Hypothesis: a testable possible explanation. Confirmed cause: an explanation supported by an appropriate causal investigation or experiment.'),
    ]);
  }
}

class _Empty extends StatelessWidget {
  const _Empty(this.message);
  final String message;
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.search_off, color: TechColors.textMuted, size: 30),
      const SizedBox(height: 8),
      Text(message, textAlign: TextAlign.center, style: const TextStyle(color: TechColors.textMuted, fontSize: 12)),
      const SizedBox(height: 5),
      const Text('Try another keyword or select All categories.', textAlign: TextAlign.center, style: TextStyle(color: TechColors.textMuted, fontSize: 10)),
    ]),
  ));
}
