import 'package:web/web.dart' as web;

String detailAnalysisBuildId() {
  final element = web.document.querySelector('meta[name="detail-analysis-build-id"]');
  return element?.getAttribute('content') ?? '';
}
