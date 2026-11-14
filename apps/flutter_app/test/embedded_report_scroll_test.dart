import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/embedded_report_scroll.dart';

void main() {
  test('accepts only finite, non-zero deltas for the active report token', () {
    expect(
      parseEmbeddedReportScrollDelta('detail-analysis-scroll|s1|120', 's1'),
      120,
    );
    expect(
      parseEmbeddedReportScrollDelta('detail-analysis-scroll|s1|-40.5', 's1'),
      -40.5,
    );
    expect(
      parseEmbeddedReportScrollDelta('detail-analysis-scroll|s2|120', 's1'),
      isNull,
    );
    expect(parseEmbeddedReportScrollDelta('other|s1|120', 's1'), isNull);
    expect(
      parseEmbeddedReportScrollDelta('detail-analysis-scroll|s1|0', 's1'),
      isNull,
    );
    expect(
      parseEmbeddedReportScrollDelta('detail-analysis-scroll|s1|NaN', 's1'),
      isNull,
    );
  });
}
