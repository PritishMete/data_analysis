import 'package:flutter/material.dart';
import '../dashboard/data_screen.dart';
import 'management_shell.dart';

void openInsightFlowAnalysis(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const DataScreen()));
}

void openInsightFlowManagement(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManagementShell()));
}
