import 'package:flutter/material.dart';
import '../dashboard/data_screen.dart';
import 'management_shell.dart';

void openInsightFlowAnalysis(
  BuildContext context, {
  String? managedDatasetId,
  String? managedVersionId,
  String? managedWorkingCopyId,
  String initialView = "ALL_SYSTEMS",
}) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => DataScreen(
        managedDatasetId: managedDatasetId,
        managedVersionId: managedVersionId,
        managedWorkingCopyId: managedWorkingCopyId,
        initialView: initialView,
      ),
    ),
  );
}

void openInsightFlowManagement(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ManagementShell()));
}
