import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import 'auth_glass_widgets.dart';

class AuthorizationManagementScreen extends StatefulWidget {
  const AuthorizationManagementScreen({super.key});

  @override
  State<AuthorizationManagementScreen> createState() =>
      _AuthorizationManagementScreenState();
}

class _AuthorizationManagementScreenState
    extends State<AuthorizationManagementScreen> {
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _snapshot = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final headers = await firebaseAuthHeaders();
      if (insightFlowWorkspaceId.isNotEmpty) {
        headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
      }
      final response = await http.get(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/management'),
        headers: headers,
      );
      if (response.statusCode != 200) {
        final decoded = jsonDecode(response.body);
        throw StateError(
          decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : 'Authorization management is unavailable.',
        );
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw StateError('Invalid authorization response.');
      }
      if (mounted) {
        setState(() {
          _snapshot = Map<String, dynamic>.from(decoded);
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = error.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  String _joinRoles(dynamic roles) {
    if (roles is! List || roles.isEmpty) return '—';
    return roles.map((item) => item.toString()).join(', ');
  }

  String _itemLabel(Map<String, dynamic> item) {
    final id = item['dataset_id'] ??
        item['working_copy_id'] ??
        item['employee_id'] ??
        item['email'] ??
        item['event_id'] ??
        'record';
    final status = item['status'] ?? item['outcome'] ?? '';
    return id.toString() + (status.toString().isEmpty ? '' : ' · ' + status.toString());
  }

  List<Widget> _rows(dynamic values) {
    if (values is! List || values.isEmpty) {
      return [const _MetaRow('Status', 'No records in this scope.')];
    }
    final result = <Widget>[];
    for (final raw in values.take(100)) {
      if (raw is Map) {
        result.add(_MetaRow('•', _itemLabel(Map<String, dynamic>.from(raw))));
      }
    }
    return result.isEmpty
        ? [const _MetaRow('Status', 'No records in this scope.')]
        : result;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AuthGlassScaffold(
        title: 'ACCESS / LOADING',
        subtitle: 'READING ORGANIZATION AUTHORIZATION METADATA',
        children: [Center(child: CircularProgressIndicator(strokeWidth: 1.8))],
      );
    }
    if (_error != null) {
      return AuthGlassScaffold(
        title: 'ACCESS / UNAVAILABLE',
        subtitle: 'AUTHORIZATION MANAGEMENT',
        children: [
          AuthGlassMessage(text: _error!, error: true),
          const SizedBox(height: 12),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }

    final roles = List<String>.from(_snapshot['role_ids'] ?? const []);
    final isOwner = roles.contains('organization_owner');
    final isManager = roles.contains('manager');
    final isLead = roles.contains('team_lead');
    final isViewer = roles.contains('external_viewer');

    final sections = <Widget>[
      _MetadataSection(
        title: isOwner || isManager
            ? 'ORGANIZATION / MANAGEMENT'
            : isLead
                ? 'TEAM LEAD / ASSIGNED TEAM'
                : isViewer
                    ? 'VIEWER / SHARED WITH ME'
                    : 'EMPLOYEE / MY DATASETS',
        children: [
          _MetaRow('Organization', _snapshot['organization_id']?.toString() ?? '—'),
          _MetaRow('Workspace', _snapshot['workspace_id']?.toString() ?? '—'),
          _MetaRow('Roles', _joinRoles(_snapshot['role_ids'])),
        ],
      ),
      if (isOwner || isManager)
        _MetadataSection(
          title: 'TEAM / EMPLOYEES',
          children: _rows(_snapshot['members']),
        ),
      if (isLead)
        _MetadataSection(
          title: 'TEAM LEAD / APPROVED EMPLOYEES',
          children: _rows(_snapshot['approved_employees']),
        ),
      _MetadataSection(
        title: 'DATASET ACCESS',
        children: _rows(_snapshot['datasets']),
      ),
      _MetadataSection(
        title: 'WORKING COPIES',
        children: _rows(_snapshot['working_copies']),
      ),
      if (isOwner || isManager)
        _MetadataSection(
          title: 'INVITATIONS',
          children: _rows(_snapshot['invitations']),
        ),
      if (isOwner || isManager)
        _MetadataSection(
          title: 'AUDIT',
          children: _rows(_snapshot['audit']),
        ),
    ];

    return AuthGlassScaffold(
      title: 'ACCESS / AUTHORIZATION',
      subtitle: 'Capability and resource authorization metadata only',
      children: [
        ...sections,
        const SizedBox(height: 10),
        TextButton(onPressed: _load, child: const Text('Refresh')),
      ],
    );
  }
}

class _MetadataSection extends StatelessWidget {
  const _MetadataSection({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: TechColors.textPrimary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Text(
        label + '  ' + value,
        style: const TextStyle(
          color: TechColors.textSecondary,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
