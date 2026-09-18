import 'package:flutter_test/flutter_test.dart';

import '../lib/widgets/overlays/ranking_limit_dialog.dart';

void main() {
  test('ranking choices preserve explicit count and All state', () {
    const topTen = RankingLimitChoice.count(10);
    const all = RankingLimitChoice.all();

    expect(topTen.limit, 10);
    expect(topTen.all, isFalse);
    expect(all.limit, isNull);
    expect(all.all, isTrue);
  });

  test('custom ranking count accepts positive integers and rejects invalid values', () {
    expect(RankingLimitDialog.parseCustomCount('1'), 1);
    expect(RankingLimitDialog.parseCustomCount('37'), 37);
    expect(RankingLimitDialog.parseCustomCount('0'), isNull);
    expect(RankingLimitDialog.parseCustomCount('-5'), isNull);
    expect(RankingLimitDialog.parseCustomCount('1.5'), isNull);
    expect(RankingLimitDialog.parseCustomCount('abc'), isNull);
    expect(RankingLimitDialog.parseCustomCount(''), isNull);
    expect(RankingLimitDialog.parseCustomCount(null), isNull);
  });
}
