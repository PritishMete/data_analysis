import 'package:flutter/material.dart';
import '../dashboard/data_screen.dart';
import 'management_shell.dart';

void openInsightFlowAnalysis(
  BuildContext context, {
  String? managedDatasetId,
  String? managedVersionId,
  String? managedWorkingCopyId,
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DataScreen(
        managedDatasetId: managedDatasetId,
        managedVersionId: managedVersionId,
        managedWorkingCopyId: managedWorkingCopyId,
      ),
    ),
  );
}

void openInsightFlowManagement(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManagementShell()));
}
