import 'package:flutter/widgets.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

bool isDetailAnalysisTestMode(Uri uri) =>
    uri.queryParameters['testMode'] == '1';

Widget applyDetailAnalysisTestMotionMode(
  BuildContext context, {
  required bool enabled,
  required Widget child,
}) {
  if (!enabled) return child;

  return MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: true),
    child: GlassAccessibilityScope(reduceMotion: true, child: child),
  );
}
