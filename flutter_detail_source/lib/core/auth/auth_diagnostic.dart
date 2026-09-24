import 'dart:math';

class AuthDiagnosticAttempt {
  AuthDiagnosticAttempt({String? id}) : id = id ?? _newId();

  final String id;
  String stage = 'GOOGLE_EVENT_RECEIVED';
  String? code;
  int? httpStatus;
  String? outcome;
  String? currentUserBefore;
  String? currentUserAfter;

  void record(String nextStage, {String? code, int? httpStatus, String? outcome}) {
    stage = nextStage;
    this.code = code;
    this.httpStatus = httpStatus;
    this.outcome = outcome;
  }

  String get failureSummary {
    final parts = <String>['Stage: $stage'];
    if (code != null && code!.isNotEmpty) parts.add('Code: $code');
    if (httpStatus != null) parts.add('HTTP: $httpStatus');
    if (currentUserBefore != null) parts.add('CurrentUserBefore: $currentUserBefore');
    if (currentUserAfter != null) parts.add('CurrentUserAfter: $currentUserAfter');
    parts.add('Attempt: $id');
    return parts.join('\n');
  }

  static String _newId() {
    final value = Random.secure().nextInt(0x10000);
    return 'AUTH-${value.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  }
}
