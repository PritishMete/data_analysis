import 'package:flutter/material.dart';
import '../dashboard/data_screen.dart';
import 'management_shell.dart';

void openInsightFlowAnalysis(
  BuildContext context, {
  String? managedDatasetId,
  String? managedVersionId,
  String? managedWorkingCopyId,
  String initialView = "ALL_SYSTEMS",
  required bool authorized,
}) {
  if (!authorized) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('AI Analytics is not available for this account.')),
    );
    return;
  }
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DataScreen(
        managedDatasetId: managedDatasetId,
        managedVersionId: managedVersionId,
        managedWorkingCopyId: managedWorkingCopyId,
        initialView: initialView,
        analysisAuthorized: authorized,
      ),
    ),
  );
}

void openInsightFlowManagement(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManagementShell()));
}
