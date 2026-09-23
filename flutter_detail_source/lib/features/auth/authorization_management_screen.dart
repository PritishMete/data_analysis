import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/insightflow_auth_service.dart';
import 'auth_glass_widgets.dart';

class AuthorizationManagementScreen extends StatefulWidget {
  const AuthorizationManagementScreen({
    super.key,
    this.onStartWorking,
  });

  final Future<void> Function(String datasetId)? onStartWorking;

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

  Future<void> _post(String path, Map<String, dynamic> body) async {
    final headers = await firebaseAuthHeaders();
    final response = await http.post(
      Uri.parse('$insightFlowBackendBaseUrl/v1/authz/$path'),
      headers: {...headers, 'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) {
      dynamic decoded;
      try { decoded = jsonDecode(response.body); } catch (_) {}
      throw StateError(
        decoded is Map && decoded['detail'] != null
            ? decoded['detail'].toString()
            : 'Authorization change was rejected.',
      );
    }
  }

  Future<void> _setMemberStatus(String uid, String status) async {
    await _post(
      'membership/status',
      {
        'workspace_id': insightFlowWorkspaceId,
        'target_uid': uid,
        'status': status,
      },
    );
    await _load();
  }

  Future<void> _setRole(String uid, String role, bool enabled) async {
    await _post(
      'roles/mutate',
      {
        'workspace_id': insightFlowWorkspaceId,
        'target_uid': uid,
        'role_id': role,
        'enabled': enabled,
      },
    );
    await _load();
  }

  Future<void> _approveEmployee(Map<String, dynamic> member) async {
    await _post(
      'approved-employees',
      {
        'workspace_id': insightFlowWorkspaceId,
        'target_uid': member['uid'],
        'employee_id': member['employee_id'],
      },
    );
    await _load();
  }

  List<Widget> _memberRows() {
    final members = (_snapshot['members'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    if (members.isEmpty) return [const _MetaRow('Status', 'No members in this scope.')];
    final owner = List<String>.from(_snapshot['role_ids'] ?? const [])
        .contains('organization_owner');
    return members.expand<Widget>((member) {
      final uid = member['uid']?.toString() ?? '';
      final status = member['membership_status']?.toString() ?? 'active';
      final memberRoles = List<String>.from(member['role_ids'] ?? const []);
      final rows = <Widget>[_MetaRow(member['employee_id']?.toString() ?? uid, '$status · ${memberRoles.isEmpty ? 'employee' : memberRoles.join(', ')}')];
      if (uid != InsightFlowAuthService.currentUser?.uid) {
        rows.add(Wrap(spacing: 6, children: [
          if (status == 'active')
            TextButton(
              onPressed: () => _approveEmployee(member),
              child: const Text('Approve'),
            ),
          if (status == 'active')
            TextButton(
              onPressed: () => _setMemberStatus(uid, 'suspended'),
              child: const Text('Suspend'),
            ),
          if (status == 'suspended')
            TextButton(
              onPressed: () => _setMemberStatus(uid, 'active'),
              child: const Text('Reactivate'),
            ),
          if (status != 'removed')
            TextButton(
              onPressed: () => _setMemberStatus(uid, 'removed'),
              child: const Text('Remove'),
            ),
          if (!memberRoles.contains('team_lead'))
            TextButton(
              onPressed: () => _setRole(uid, 'team_lead', true),
              child: const Text('Promote Team Lead'),
            ),
          if (memberRoles.contains('team_lead'))
            TextButton(
              onPressed: () => _setRole(uid, 'team_lead', false),
              child: const Text('Remove Team Lead'),
            ),
          if (owner && memberRoles.contains('manager'))
            TextButton(
              onPressed: () => _setRole(uid, 'manager', false),
              child: const Text('Remove Manager'),
            ),
        ]));
      }
      return rows;
    }).toList();
  }
  Future<void> _inviteEmployee() async {
    final email = TextEditingController();
    final employeeId = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Invite employee'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: email,
            decoration: const InputDecoration(labelText: 'Company email'),
          ),
          TextField(
            controller: employeeId,
            decoration: const InputDecoration(labelText: 'Employee ID'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Invite')),
        ],
      ),
    );
    if (result != true) { email.dispose(); employeeId.dispose(); return; }
    if (email.text.trim().isEmpty || employeeId.text.trim().isEmpty) {
      email.dispose(); employeeId.dispose();
      throw StateError('Company email and employee ID are required.');
    }
    await _post('invitations', {
      'workspace_id': insightFlowWorkspaceId,
      'email': email.text.trim(),
      'employee_id': employeeId.text.trim(),
      'role_id': 'employee',
    });
    email.dispose(); employeeId.dispose();
    await _load();
  }

  List<Widget> _datasetAccessRows() {
    final roles = List<String>.from(_snapshot['role_ids'] ?? const []);
    final lead = roles.contains('team_lead') &&
        !roles.contains('manager') &&
        !roles.contains('organization_owner');
    final members = (_snapshot[lead ? 'approved_employees' : 'members'] as List? ?? const [])
        .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final datasets = (_snapshot['datasets'] as List? ?? const [])
        .whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    if (datasets.isEmpty) return [const _MetaRow('Status', 'No datasets in this scope.')];
    final rows = <Widget>[];
    for (final dataset in datasets) {
      final datasetId = dataset['dataset_id']?.toString() ?? '';
      rows.add(_MetaRow('Dataset', '$datasetId${dataset['protected_original'] == true ? ' · PROTECTED ORIGINAL' : ''}'));
      for (final member in members) {
        final uid = member['uid']?.toString() ?? '';
        if (uid.isEmpty) continue;
        rows.add(Wrap(spacing: 5, children: [
          Text(member['employee_id']?.toString() ?? uid, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
          TextButton(onPressed: () => _post('datasets/grants', {'workspace_id': insightFlowWorkspaceId, 'dataset_id': datasetId, 'target_uid': uid, 'permissions': ['dataset.view_original']} ).then((_) => _load()), child: const Text('Viewer')),
          if (!lead) TextButton(onPressed: () => _post('datasets/grants', {'workspace_id': insightFlowWorkspaceId, 'dataset_id': datasetId, 'target_uid': uid, 'permissions': ['dataset.view_original', 'dataset.create_working_copy', 'dataset.edit_working_copy']} ).then((_) => _load()), child: const Text('Editor')),
          TextButton(onPressed: () => _post('datasets/grants', {'workspace_id': insightFlowWorkspaceId, 'dataset_id': datasetId, 'target_uid': uid, 'permissions': []}).then((_) => _load()), child: const Text('Revoke')),
        ]));
      }
    }
    return rows;
  }
  Future<void> _createDelegation() async {
    final memberIds = <String>{};
    final datasetIds = <String>{};
    final leads = (_snapshot['members'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .where((m) =>
            m['membership_status']?.toString() == 'active' &&
            m['role_ids'] is List &&
            (m['role_ids'] as List).contains('team_lead'))
        .toList();
    if (leads.isEmpty) {
      throw StateError('No active Team Lead is available.');
    }
    String leadUid = leads.first['uid'].toString();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Manage Team Lead delegation'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                value: leadUid,
                decoration: const InputDecoration(labelText: 'Team Lead'),
                items: leads.map((m) => DropdownMenuItem(
                  value: m['uid'].toString(),
                  child: Text(m['employee_id']?.toString() ?? m['uid'].toString()),
                )).toList(),
                onChanged: (v) => setDialogState(() => leadUid = v ?? leadUid),
              ),
              const SizedBox(height: 10),
              const Text('Approved employees only'),
              ...(_snapshot['approved_employees'] as List? ?? const [])
                  .whereType<Map>()
                  .map((raw) {
                    final m = Map<String, dynamic>.from(raw);
                    final id = m['uid']?.toString() ?? '';
                    return CheckboxListTile(
                      dense: true,
                      value: memberIds.contains(id),
                      title: Text(m['employee_id']?.toString() ?? id),
                      onChanged: (checked) => setDialogState(() {
                        if (checked == true) {
                          memberIds.add(id);
                        } else {
                          memberIds.remove(id);
                        }
                      }),
                    );
                  }),
              const SizedBox(height: 8),
              const Text('Datasets'),
              ...(_snapshot['datasets'] as List? ?? const [])
                  .whereType<Map>()
                  .map((raw) {
                    final dataset = Map<String, dynamic>.from(raw);
                    final id = dataset['dataset_id']?.toString() ?? '';
                    return CheckboxListTile(
                      dense: true,
                      value: datasetIds.contains(id),
                      title: Text(id),
                      onChanged: (checked) => setDialogState(() {
                        if (checked == true) {
                          datasetIds.add(id);
                        } else {
                          datasetIds.remove(id);
                        }
                      }),
                    );
                  }),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
            FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delegate'),
          ),
          ],
        ),
      ),
    );
    if (result != true || memberIds.isEmpty || datasetIds.isEmpty) return;
    await _post('delegations', {
      'workspace_id': insightFlowWorkspaceId,
      'team_lead_uid': leadUid,
      'member_ids': memberIds.toList(),
      'dataset_ids': datasetIds.toList(),
      'permissions': ['dataset.view_original', 'dataset.create_working_copy', 'dataset.share'],
    });
    await _load();
  }
  String _itemLabel(Map<String, dynamic> item) {
    final id = item['dataset_id'] ??
        item['working_copy_id'] ??
        item['employee_id'] ??
        item['email'] ??
        item['event_id'] ??
        'record';
    final status = item['status'] ?? item['outcome'] ?? '';
    final idText = id.toString();
    final statusText = status.toString();
    return '$idText${statusText.isEmpty ? '' : ' · $statusText'}';
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
          children: [
            ..._memberRows(),
            if (isOwner || isManager)
              TextButton(
                onPressed: _inviteEmployee,
                child: const Text('Invite employee'),
              ),
          ],
        ),
      if (isLead)
        _MetadataSection(
          title: 'TEAM LEAD / APPROVED EMPLOYEES',
          children: [
            ..._rows(_snapshot['approved_employees']),
            const SizedBox(height: 6),
            _MetadataSection(title: 'DELEGATION SCOPE', children: _rows(_snapshot['delegations'])),
          ],
        ),
      _MetadataSection(
        title: 'DATASET ACCESS',
        children: [
          ..._datasetAccessRows(),
          if (isOwner || isManager)
            TextButton(
              onPressed: _createDelegation,
              child: const Text('Manage Team Lead delegation'),
            ),
        ],
      ),
      _MetadataSection(
        title: 'WORKING COPIES',
        children: [
          ..._rows(_snapshot['working_copies']),
          if (!isManager && !isLead && !isViewer)
            ...((_snapshot['datasets'] as List? ?? const [])
                .whereType<Map>()
                .where((dataset) => dataset['protected_original'] == true)
                .map((dataset) => TextButton(
                      onPressed: widget.onStartWorking == null
                          ? null
                          : () => widget.onStartWorking!(
                                dataset['dataset_id'].toString(),
                              ),
                      child: Text(
                        'Start working · \${dataset['dataset_id']}',
                      ),
                    ))),
        ],
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
        '$label  $value',
        style: const TextStyle(
          color: TechColors.textMuted,
          fontSize: 11,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}
