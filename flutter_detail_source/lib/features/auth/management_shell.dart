import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../tech_background.dart';
import '../../widgets/shared/dock_glass_material.dart';
import 'management_navigation.dart';
import '../dashboard/navigation_tabs.dart' show kInsightFlowNavigationGlassSettings;
import 'authorization_management_screen.dart';
import 'managed_dataset_access_workspace.dart';

enum ManagementSection { overview, organization, people, invitations, dataAccess, audit }

class _ManagementGlassDialog extends StatelessWidget {
  const _ManagementGlassDialog({
    required this.title,
    required this.content,
    required this.actions,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: kAppBackgroundColor,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.standard,
          settings: TechColors.panelGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 20),
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 14),
          child: DefaultTextStyle(
            style: const TextStyle(color: TechColors.textPrimary),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.tune,
                      size: 16,
                      color: TechColors.borderActive,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: DefaultTextStyle.merge(
                        style: const TextStyle(
                          color: TechColors.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        child: title,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.62,
                  ),
                  child: SingleChildScrollView(
                    child: content,
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    alignment: WrapAlignment.end,
                    runAlignment: WrapAlignment.end,
                    spacing: 8,
                    runSpacing: 8,
                    children: actions,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


class ManagementShell extends StatefulWidget {
  const ManagementShell({super.key});
  @override
  State<ManagementShell> createState() => _ManagementShellState();
}

class _ManagementShellState extends State<ManagementShell> {
  ManagementSection section = ManagementSection.overview;
  bool loading = true;
  String? error;
  Map<String, dynamic> overview = const {};
  List<Map<String, dynamic>> locations = [];
  List<Map<String, dynamic>> sections = [];
  List<Map<String, dynamic>> people = [];
  List<Map<String, dynamic>> assignments = [];
  List<Map<String, dynamic>> audit = [];
  List<Map<String, dynamic>> invitations = [];
  String auditSearch = '';
  String? auditCategory;
  String invitationSearch = '';
  String? invitationStatus;
  String search = '';
  String? selectedLocation;
  String? selectedSection;
  String? selectedRole;
  Map<String, dynamic>? _selectedAssignmentProfile;
  Future<Map<String, dynamic>>? _assignmentProfileFuture;
  bool _showIdProof = false;
  bool _isCurrentUserProfile = false;

  @override
  void initState() { super.initState(); loadAll(); }

  List<Map<String, dynamic>> maps(dynamic v) => v is List
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : <Map<String, dynamic>>[];

  static const _managementRequestTimeout = Duration(seconds: 45);
  Future<void>? _refreshFuture;

  Future<http.Response> _sendManagementRequest(
    Uri uri,
    Map<String, String> headers, {
    required String method,
    Map<String, dynamic>? body,
  }) async {
    Future<http.Response> send() => method == 'POST'
        ? http.post(uri, headers: headers, body: jsonEncode(body))
        : http.get(uri, headers: headers);

    try {
      return await send().timeout(_managementRequestTimeout);
    } on TimeoutException catch (error) {
      // A Future.timeout only bounds the caller; it does not cancel the
      // underlying browser request. Do not start a second 45-second request
      // here: that used to turn one slow request into two overlapping
      // management calls and could amplify a cold-start/session problem.
      debugPrint(
        '[management] timeout ${method.toUpperCase()} ${uri.path}: ${error.runtimeType}',
      );
      throw StateError(
        'Management service timed out while loading ${uri.path}. '
        'The backend may be starting or temporarily unavailable. Please retry.',
      );
    }
  }

  Future<Map<String, dynamic>> request(
    String path, {
    String method = 'GET',
    Map<String, dynamic>? body,
  }) async {
    final session = await InsightFlowSupabaseAuthService.ensureSession(
      timeout: const Duration(seconds: 8),
    );
    if (session == null || session.accessToken.isEmpty) {
      throw StateError('Your authenticated session could not be restored. Please retry.');
    }
    // ensureSession() already resolved the authoritative session above.
    // Build the bearer header from that exact session instead of resolving the
    // session a second time for every one of the six startup requests.
    final headers = <String, String>{
      'Authorization': 'Bearer ${session.accessToken}',
    };
    if (insightFlowWorkspaceId.isNotEmpty) {
      headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
    }
    if (body != null) {
      headers['Content-Type'] = 'application/json';
    }
    final uri = Uri.parse('$insightFlowBackendBaseUrl/v1/authz/management$path');
    final response = await _sendManagementRequest(
      uri,
      headers,
      method: method,
      body: body,
    );
    dynamic data;
    try { data = jsonDecode(response.body); } catch (_) {}
    if (response.statusCode == 401) {
      await InsightFlowSupabaseAuthService.signOut();
      throw StateError('Your session is no longer authorized.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        data is Map && data['detail'] != null
            ? data['detail'].toString()
            : 'Management request failed.',
      );
    }
    if (data is! Map) {
      throw StateError('Management service returned an invalid response.');
    }
    return Map<String, dynamic>.from(data);
  }

  Future<void> loadAll() {
    final active = _refreshFuture;
    if (active != null) {
      return active;
    }
    final future = _loadAll();
    _refreshFuture = future;
    return future.whenComplete(() {
      if (identical(_refreshFuture, future)) {
        _refreshFuture = null;
      }
    });
  }

  Future<void> _loadAll() async {
    if (mounted) {
      setState(() { loading = true; error = null; });
    }
    try {
      final r = await Future.wait([
        request('/overview'), request('/locations'), request('/sections'),
        request('/people'), request('/assignments'), request(''),
      ]);
      if (!mounted) return;
      setState(() {
        overview = r[0];
        locations = maps(r[1]['locations']);
        sections = maps(r[2]['sections']);
        people = maps(r[3]['people']);
        assignments = maps(r[4]['assignments']);
        audit = maps(r[5]['audit']);
        invitations = maps(r[5]['invitations']);
        loading = false;
        if (!_sectionAllowed(section)) {
          section = ManagementSection.overview;
        }
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  String _managementRole() {
    final actor = overview['actor'];
    return actor is Map ? actor['role_id']?.toString().trim() ?? '' : '';
  }

  bool get _isOrganizationOwner => _managementRole() == 'organization_owner';

  Map<String, dynamic> _uiPolicy() {
    final raw = overview['ui_policy'];
    return raw is Map ? Map<String, dynamic>.from(raw) : const {};
  }

  bool _canUi(String capability) {
    final capabilities = _uiPolicy()['capabilities'];
    return capabilities is List &&
        capabilities.map((value) => value.toString()).contains(capability);
  }

  String _uiRoleLabel() {
    final value = _uiPolicy()['role_label']?.toString().trim() ?? '';
    return value.isNotEmpty ? value : _roleLabel(_managementRole());
  }

  String _uiScopeLabel() {
    final value = _uiPolicy()['scope_label']?.toString().trim() ?? '';
    return value.isNotEmpty ? value : 'Assigned workspace';
  }

  List<ManagementSection> _allowedSections() {
    final policy = overview['ui_policy'];
    if (policy is Map && policy['sections'] is List) {
      final sections = <ManagementSection>[];
      for (final raw in policy['sections'] as List) {
        switch (raw.toString()) {
          case 'overview':
            sections.add(ManagementSection.overview);
            break;
          case 'organization':
            sections.add(ManagementSection.organization);
            break;
          case 'people':
            sections.add(ManagementSection.people);
            break;
          case 'dataAccess':
            sections.add(ManagementSection.dataAccess);
            break;
          case 'invitations':
            sections.add(ManagementSection.invitations);
            break;
          case 'audit':
            sections.add(ManagementSection.audit);
            break;
        }
      }
      if (sections.isNotEmpty) return sections;
    }

    switch (_managementRole()) {
      case 'organization_owner':
      case 'branch_head':
        return const [
          ManagementSection.overview,
          ManagementSection.organization,
          ManagementSection.people,
          ManagementSection.dataAccess,
          ManagementSection.invitations,
          ManagementSection.audit,
        ];
      case 'manager':
        return const [
          ManagementSection.overview,
          ManagementSection.people,
          ManagementSection.dataAccess,
          ManagementSection.invitations,
        ];
      case 'team_lead':
        return const [
          ManagementSection.overview,
          ManagementSection.people,
          ManagementSection.dataAccess,
        ];
      default:
        return const [ManagementSection.overview];
    }
  }

  bool _sectionAllowed(ManagementSection value) =>
      _allowedSections().contains(value);

  InputDecoration input(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: TechColors.textMuted, fontSize: 12),
    floatingLabelStyle: const TextStyle(color: TechColors.borderActive, fontSize: 12),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: TechColors.textMuted.withValues(alpha: 0.28)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: TechColors.textMuted.withValues(alpha: 0.22)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(14),
      borderSide: BorderSide(color: TechColors.borderActive.withValues(alpha: 0.65)),
    ),
  );

  Widget surface(Widget child) => GlassCard(
    margin: EdgeInsets.zero,
    padding: const EdgeInsets.all(16),
    shape: const LiquidRoundedSuperellipse(borderRadius: 16),
    child: child,
  );

  void feedback(Object e) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    }
  }

  Future<void> _inviteEmployee() async {
    final emailController = TextEditingController();
    // Generic `employee` is intentionally not a valid invitation role.
    const roleOptions = <String>[
      'manager',
      'team_lead',
      'data_analyst',
      'senior_data_analyst',
      'business_analyst',
      'data_scientist',
      'data_engineer',
      'ml_engineer',
      'analytics_engineer',
      'bi_developer',
      'data_architect',
      'data_quality_analyst',
      'data_governance_analyst',
      'external_viewer',
    ];
    String role = 'data_analyst';
    if (locations.isEmpty) { feedback(StateError('Create an active branch/location before inviting an employee.')); return; }
    String locationId = selectedLocation ?? locations.first['location_id'].toString();
    int expiryDays = 7;

    final result = await GlassDialog.show<Map<String, dynamic>>(
      context: context,
      title: 'Invite employee',
      message: '',
      content: StatefulBuilder(
        builder: (dialogContext, setDialogState) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Send an InsightFlow invitation to an email address. '
              'The server will apply the current workspace authorization and role rules.',
              style: TextStyle(
                color: TechColors.textMuted,
                fontSize: 12,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              autofillHints: const [AutofillHints.email],
              decoration: input('Employee email'),
            ),
            if (_isOrganizationOwner) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: locationId,
                decoration: input('Branch / Location'),
                items: locations.map((value) => DropdownMenuItem<String>(value: value['location_id'].toString(), child: Text(value['name'].toString()))).toList(),
                onChanged: (value) { if (value != null) setDialogState(() => locationId = value); },
              ),
            ],
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: role,
              decoration: input('Role'),
              items: roleOptions
                  .map(
                    (value) => DropdownMenuItem<String>(
                      value: value,
                      child: Text(_roleLabel(value)),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setDialogState(() => role = value);
              },
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: expiryDays,
              decoration: input('Invitation expiry'),
              items: const [3, 7, 14, 30]
                  .map(
                    (days) => DropdownMenuItem<int>(
                      value: days,
                      child: Text('$days days'),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) setDialogState(() => expiryDays = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context, null),
        ),
        GlassDialogAction(
          label: 'Send invitation',
          isPrimary: true,
          onPressed: () {
            final email = emailController.text.trim();
            if (email.isEmpty || !email.contains('@')) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Enter a valid employee email.')),
              );
              return;
            }
            Navigator.pop(context, {
              'email': email,
              'role_id': role,
              'location_id': locationId,
              'expires_at': DateTime.now()
                  .add(Duration(days: expiryDays))
                  .toUtc()
                  .millisecondsSinceEpoch,
            });
          },
        ),
      ],
    );

    emailController.dispose();
    if (result == null || !mounted) return;

    if (insightFlowWorkspaceId.trim().isEmpty) {
      feedback(
        StateError(
          'Workspace authorization context is unavailable. Please refresh the management workspace.',
        ),
      );
      return;
    }

    try {
      final headers = await supabaseAuthHeaders();
      headers['Content-Type'] = 'application/json';
      final response = await http
          .post(
            Uri.parse('$insightFlowBackendBaseUrl/v1/authz/invitations'),
            headers: headers,
            body: jsonEncode({
              'workspace_id': insightFlowWorkspaceId,
              'email': result['email'],
              'role_id': result['role_id'],
              'location_id': result['location_id'],
              'expires_at': result['expires_at'],
            }),
          )
          .timeout(_managementRequestTimeout);

      dynamic data;
      try {
        data = jsonDecode(response.body);
      } catch (_) {}

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          data is Map && data['detail'] != null
              ? data['detail'].toString()
              : 'Employee invitation could not be sent.',
        );
      }

      final deliveryStatus =
          data is Map ? data['email_delivery_status']?.toString() : null;
      if (deliveryStatus == 'initiated') {
        feedback(StateError('Invitation email initiated successfully.'));
      } else if (deliveryStatus == 'existing_account') {
        feedback(
          StateError(
            'The email already belongs to an existing confirmed account; '
            'no duplicate Auth account was created.',
          ),
        );
      } else {
        feedback(StateError('Invitation created.'));
      }
      await loadAll();
    } catch (e) {
      feedback(e);
    }
  }
  Future<void> createLocation() async {
    final name = TextEditingController(), id = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => _ManagementGlassDialog(
      title: const Text('Create location'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, decoration: input('Location name')),
        const SizedBox(height: 12),
        TextField(controller: id, decoration: input('Branch identifier')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, name.text.trim().isNotEmpty && id.text.isNotEmpty), child: const Text('Create')),
      ],
    )) ?? false;
    if (!ok) { name.dispose(); id.dispose(); return; }
    try {
      await request('/locations', method: 'POST', body: {'name': name.text.trim(), 'branch_identifier': id.text});
      feedback('Location created.');
      await loadAll();
    } catch (e) { feedback(e); }
    name.dispose(); id.dispose();
  }

  Future<void> createSection() async {
    if (locations.isEmpty) { feedback(StateError('Create a location first.')); return; }
    final name = TextEditingController();
    var location = selectedLocation ?? locations.first['location_id'].toString();
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => _ManagementGlassDialog(
      title: const Text('Create section'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(
          initialValue: location, decoration: const InputDecoration(labelText: 'Location'),
          items: locations.map((x) => DropdownMenuItem(value: x['location_id'].toString(), child: Text(x['name'].toString()))).toList(),
          onChanged: (v) => set(() => location = v ?? location)),
        const SizedBox(height: 12),
        TextField(controller: name, decoration: input('Section name')),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, name.text.trim().isNotEmpty), child: const Text('Create')),
      ],
    ))) ?? false;
    if (!ok) { name.dispose(); return; }
    try {
      await request('/sections', method: 'POST', body: {'location_id': location, 'name': name.text.trim()});
      feedback('Section created.');
      await loadAll();
    } catch (e) { feedback(e); }
    name.dispose();
  }

  Future<void> assignManager({bool replace = false}) async {
    if (locations.isEmpty || people.isEmpty) { feedback(StateError('An active location and person are required.')); return; }
    var location = selectedLocation ?? locations.first['location_id'].toString();
    var principal = people.first['principal_id'].toString();
    final active = people.where((p) => p['status'] == 'active').toList();
    if (active.isEmpty) { feedback(StateError('No active people are available.')); return; }
    principal = active.first['principal_id'].toString();
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => _ManagementGlassDialog(
      title: Text(replace ? 'Replace Manager' : 'Assign Manager'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(initialValue: location, decoration: const InputDecoration(labelText: 'Location'),
          items: locations.map((x) => DropdownMenuItem(value: x['location_id'].toString(), child: Text(x['name'].toString()))).toList(),
          onChanged: (v) => set(() => location = v ?? location)),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(initialValue: principal, decoration: const InputDecoration(labelText: 'Person'),
          items: active.map((x) => DropdownMenuItem(value: x['principal_id'].toString(), child: Text(x['employee_id'].toString()))).toList(),
          onChanged: (v) => set(() => principal = v ?? principal)),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
      ],
    ))) ?? false;
    if (!ok) return;
    try {
      await request(replace ? '/assignments/manager/change' : '/assignments/manager',
        method: 'POST', body: {'location_id': location, 'principal_id': principal});
      feedback(replace ? 'Manager replaced.' : 'Manager assigned.');
      await loadAll();
    } catch (e) { feedback(e); }
  }

  Future<void> assignTeamLead() async {
    final active = people.where((p) => p['status'] == 'active').toList();
    final managerRequest = _managementRole() == 'manager';
    if (locations.isEmpty || sections.isEmpty || active.isEmpty) { feedback(StateError('An active location, section, and person are required.')); return; }
    var location = selectedLocation ?? locations.first['location_id'].toString();
    var sectionId = selectedSection ?? sections.first['section_id'].toString();
    var principal = active.first['principal_id'].toString();
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) {
      final matching = sections.where((x) => x['location_id'].toString() == location).toList();
      if (matching.isNotEmpty && !matching.any((x) => x['section_id'].toString() == sectionId)) sectionId = matching.first['section_id'].toString();
      return _ManagementGlassDialog(
        title: const Text('Assign Team Lead'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(initialValue: location, decoration: const InputDecoration(labelText: 'Location'),
            items: locations.map((x) => DropdownMenuItem(value: x['location_id'].toString(), child: Text(x['name'].toString()))).toList(),
            onChanged: (v) => set(() => location = v ?? location)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: matching.isEmpty ? null : sectionId, decoration: const InputDecoration(labelText: 'Section'),
            items: matching.map((x) => DropdownMenuItem(value: x['section_id'].toString(), child: Text(x['name'].toString()))).toList(),
            onChanged: (v) => set(() => sectionId = v ?? sectionId)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(initialValue: principal, decoration: const InputDecoration(labelText: 'Person'),
            items: active.map((x) => DropdownMenuItem(value: x['principal_id'].toString(), child: Text(x['employee_id'].toString()))).toList(),
            onChanged: (v) => set(() => principal = v ?? principal)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: matching.isEmpty ? null : () => Navigator.pop(c, true), child: const Text('Save')),
        ],
      );
    })) ?? false;
    if (!ok) return;
    try {
      await request(
        managerRequest ? '/assignments/team-lead/request' : '/assignments/team-lead',
        method: 'POST',
        body: {'location_id': location, 'section_id': sectionId, 'principal_id': principal},
      );
      feedback(managerRequest
          ? 'Team Lead assignment request sent to the Branch Head.'
          : 'Team Lead assigned.');

      await loadAll();
    } catch (e) { feedback(e); }
  }

  int level(dynamic role) => {'external_viewer': 10, 'data_analyst': 20, 'senior_data_analyst': 20, 'business_analyst': 20, 'data_scientist': 20, 'data_engineer': 20, 'ml_engineer': 20, 'analytics_engineer': 20, 'bi_developer': 20, 'data_architect': 20, 'data_quality_analyst': 20, 'data_governance_analyst': 20, 'team_lead': 30, 'manager': 40, 'branch_head': 45, 'organization_owner': 50}[role?.toString()] ?? 0;

  Future<void> reporting(Map<String, dynamic> a) async {
    final candidates = assignments.where((x) =>
      x['status'] == 'active' && x['location_id'] == a['location_id'] &&
      x['assignment_id'] != a['assignment_id'] && level(x['role_id']) > level(a['role_id'])).toList();
    String? parent = a['reports_to_assignment_id']?.toString();
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => _ManagementGlassDialog(
      title: const Text('Reporting relationship'),
      content: DropdownButtonFormField<String?>(
        initialValue: candidates.any((x) => x['assignment_id'].toString() == parent) ? parent : null,
        decoration: const InputDecoration(labelText: 'Reports to'),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('No direct reporting target')),
          ...candidates.map((x) => DropdownMenuItem<String?>(value: x['assignment_id'].toString(), child: Text('${x['employee_id']} · ${x['role_id']}'))),
        ],
        onChanged: (v) => set(() => parent = v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Save')),
      ],
    ))) ?? false;
    if (!ok) return;
    try {
      await request('/assignments/reporting', method: 'POST',
        body: {'assignment_id': a['assignment_id'], 'reports_to_assignment_id': parent});
      feedback('Reporting relationship updated.');
      await loadAll();
    } catch (e) { feedback(e); }
  }

  Widget _eyebrow(String text) => Text(
    text.toUpperCase(),
    style: const TextStyle(color: TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 1.0),
  );

  Widget _title(String text, {String? detail, IconData? icon}) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (icon != null) ...[
        Icon(icon, size: 18, color: TechColors.borderActive),
        const SizedBox(width: 10),
      ],
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: const TextStyle(color: TechColors.textPrimary, fontSize: 18, fontWeight: FontWeight.w700)),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(detail, style: const TextStyle(color: TechColors.textMuted, fontSize: 12, height: 1.4)), 
        ],
      ])),
    ],
  );

  Widget _statusDot(String status) {
    final s = status.toLowerCase();
    final color = s == 'active' || s == 'accepted' || s == 'success'
        ? TechColors.statusGreen
        : s == 'pending' || s == 'invited'
            ? TechColors.statusAmber
            : s == 'suspended' || s == 'revoked' || s == 'error'
                ? TechColors.statusRed
                : TechColors.statusBlue;
    return Container(width: 7, height: 7, decoration: BoxDecoration(
      shape: BoxShape.circle, color: color,
      boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 8)],
    ));
  }

  Widget _glassRow({
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
    LiquidGlassSettings? settings,
  }) => GlassCard(
    margin: EdgeInsets.zero,
    padding: padding,
    settings: settings,
    child: child,
  );

  Widget _actionChip(String label, IconData icon, VoidCallback? onPressed, {bool accent = false}) {
    final fillColor = accent ? TechColors.borderActive : TechColors.panelBg;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.24),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: SizedBox(
        height: 48,
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(28),
                  color: fillColor,
                ),
              ),
            ),
            Positioned.fill(
              child: GlassButton.custom(
                onTap: onPressed ?? () {},
                enabled: onPressed != null,
                height: 48,
                width: double.infinity,
                shape: const LiquidRoundedSuperellipse(borderRadius: 12),
                useOwnLayer: true,
                quality: GlassQuality.minimal,
                settings: dockGlassSettings(glassColor: fillColor.withValues(alpha: 0.85)),
                glowColor: kDockWhiteGlow.withValues(alpha: kDockGlowAlpha),
                glowRadius: kDockGlowRadius,
                interactionScale: 1.02,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 22, color: CupertinoColors.white),
                    const SizedBox(width: 8),
                    Text(label, style: const TextStyle(
                      color: CupertinoColors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    )),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget metric(String label, dynamic value, {IconData? icon}) => GlassCard(
    margin: EdgeInsets.zero,
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    shape: const LiquidRoundedSuperellipse(borderRadius: 14),
    child: Row(
      children: [
        Container(
          width: 6,
          height: 34,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: TechColors.borderActive.withValues(alpha: 0.75),
            boxShadow: [
              BoxShadow(
                color: TechColors.borderActive.withValues(alpha: 0.20),
                blurRadius: 10,
              ),
            ],
          ),
        ),
        const SizedBox(width: 11),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow(label),
            const SizedBox(height: 5),
            Text((value ?? 0).toString(), style: const TextStyle(
              color: TechColors.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            )),
          ],
        )),
        if (icon != null) Icon(icon, size: 15, color: TechColors.textMuted),
      ],
    ),
  );

  int _overviewCount(dynamic summaryValue, int fallback) {
    if (summaryValue is num) return summaryValue.toInt();
    final parsed = int.tryParse(summaryValue?.toString() ?? '');
    return parsed ?? fallback;
  }

  String _humanizeAuditAction(String action) {
    final normalized = action
        .replaceAll(RegExp(r'^[A-Z_]+\\.'), '')
        .replaceAll('_', ' ')
        .trim()
        .toLowerCase();
    if (normalized.isEmpty) return 'Management activity';
    return normalized[0].toUpperCase() + normalized.substring(1);
  }

  String _relativeActivityTime(String value) {
    final timestamp = DateTime.tryParse(value)?.toLocal();
    if (timestamp == null) return '';
    final difference = DateTime.now().difference(timestamp);
    if (difference.isNegative || difference.inMinutes < 1) return 'Just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes} min ago';
    if (difference.inHours < 24) return '${difference.inHours} hr ago';
    if (difference.inDays < 7) return '${difference.inDays} days ago';
    return '${timestamp.day}/${timestamp.month}/${timestamp.year}';
  }

  Widget _overviewActivityItem(Map<String, dynamic> event) {
    final action = event['action']?.toString() ?? '';
    final outcome = event['outcome']?.toString() ?? '';
    final timestamp = event['created_at']?.toString() ?? '';
    final actor = event['actor_name']?.toString().trim();
    final description = actor != null && actor.isNotEmpty
        ? '$actor · ${_humanizeAuditAction(action)}'
        : _humanizeAuditAction(action);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _glassRow(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
        child: Row(
          children: [
            _statusDot(outcome),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 3),
                  Text(outcome.isEmpty ? 'Management activity' : outcome, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textMuted, fontSize: 10)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(_relativeActivityTime(timestamp), style: const TextStyle(color: TechColors.textMuted, fontSize: 9)),
          ],
        ),
      ),
    );
  }

    Widget _overviewSkeleton() {
    Widget block({double height = 12, double? width, double radius = 7}) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: TechColors.textMuted.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: TechColors.textMuted.withValues(alpha: 0.07)),
      ),
    );
    Widget panel({required Widget child, EdgeInsets padding = const EdgeInsets.all(15)}) => Container(
      padding: padding,
      decoration: BoxDecoration(
        color: const Color(0xB8051727),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF0B4164).withValues(alpha: .88)),
        boxShadow: const [BoxShadow(color: Color(0x1600BCEB), blurRadius: 18, offset: Offset(0, 4))],
      ),
      child: child,
    );
    Widget metricCard() => Container(
      constraints: const BoxConstraints(minHeight: 116),
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0x251B8AC0), Color(0xB8041727)]),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0x5539BFEF)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 43, height: 43, decoration: BoxDecoration(color: const Color(0x2227C9F4), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0x4439BFEF))), child: Center(child: block(width: 17, height: 17, radius: 5))),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          block(width: 88, height: 10), const SizedBox(height: 9), block(width: 54, height: 24), const SizedBox(height: 8), block(width: 104, height: 10),
        ])),
      ]),
    );
    Widget panelContent({int rows = 3}) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [block(width: 26, height: 26, radius: 8), const SizedBox(width: 9), block(width: 120, height: 13)]),
      const SizedBox(height: 14),
      ...List.generate(rows, (i) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [
        if (i == 0) block(width: 30, height: 30, radius: 20),
        if (i == 0) const SizedBox(width: 9),
        Expanded(child: block(height: 11, width: i == 1 ? 155 : null)),
        const SizedBox(width: 12),
        block(width: 56, height: 10),
      ]))),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xE8113551), Color(0xC8061727), Color(0xB8051727)]),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF1374A2).withValues(alpha: .75)),
          boxShadow: const [BoxShadow(color: Color(0x1800CFFF), blurRadius: 24, offset: Offset(0, 6))],
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF0D3854), borderRadius: BorderRadius.circular(12)), child: Center(child: block(width: 20, height: 20, radius: 6))),
          const SizedBox(width: 13),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            block(width: 142, height: 10), const SizedBox(height: 10), block(width: 218, height: 23), const SizedBox(height: 8), block(width: 270, height: 12),
          ])),
        ]),
      ),
      const SizedBox(height: 14),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 560 ? 1 : constraints.maxWidth < 980 ? 2 : 4;
        final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(spacing: 10, runSpacing: 10, children: List.generate(4, (_) => SizedBox(width: width, child: metricCard())));
      }),
      const SizedBox(height: 14),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 820 ? 1 : 2;
        final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
        return Wrap(spacing: 12, runSpacing: 12, children: List.generate(4, (i) => SizedBox(width: width, child: panel(child: panelContent(rows: i == 0 ? 4 : 3)))));
      }),
    ]);
  }

  Widget overviewView() {
    final summary = overview['summary'] is Map
        ? Map<String, dynamic>.from(overview['summary'] as Map)
        : <String, dynamic>{};
    final peopleCount = _overviewCount(summary['people_count'], people.length);
    final locationCount = _overviewCount(summary['location_count'], locations.length);
    final sectionCount = _overviewCount(summary['section_count'], sections.length);
    final activeCount = assignments
        .where((item) => (item['status']?.toString() ?? '').toLowerCase() == 'active')
        .length;
    final pendingCount = invitations
        .where((item) => (item['status']?.toString() ?? '').toLowerCase() == 'pending')
        .length;
    final branch = locations.cast<Map<String, dynamic>?>().firstWhere(
      (item) => item?['location_id']?.toString() == selectedLocation,
      orElse: () => locations.isEmpty ? null : locations.first,
    );
    final branchName = branch?['name']?.toString().trim().isNotEmpty == true
        ? branch!['name'].toString()
        : _uiScopeLabel();
    final actor = overview['actor'];
    final actorName = actor is Map
        ? (actor['full_name'] ?? actor['name'] ?? actor['email'] ?? _uiRoleLabel()).toString()
        : _uiRoleLabel();
    final latest = audit.take(5).toList();

    Widget panel(String title, IconData icon, Widget child, {Widget? action}) =>
        Container(
          decoration: BoxDecoration(
            color: const Color(0xB8051727),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF0B4164).withValues(alpha: .88)),
            boxShadow: const [
              BoxShadow(color: Color(0x1600BCEB), blurRadius: 18, offset: Offset(0, 4)),
            ],
          ),
          padding: const EdgeInsets.all(15),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Icon(icon, color: const Color(0xFF4BCBFF), size: 21),
                const SizedBox(width: 9),
                Expanded(child: Text(title, style: const TextStyle(
                  color: Color(0xFFDCEEFF), fontSize: 14, fontWeight: FontWeight.w700,
                ))),
                ?action,
              ]),
              const SizedBox(height: 13),
              child,
            ],
          ),
        );

    Widget metric(String label, String value, String detail, IconData icon, Color accent) =>
        Container(
          constraints: const BoxConstraints(minHeight: 116),
          padding: const EdgeInsets.all(15),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent.withValues(alpha: .13), const Color(0xB8041727)],
            ),
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: accent.withValues(alpha: .9)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 43, height: 43,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: .15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent.withValues(alpha: .35)),
              ),
              child: Icon(icon, color: accent, size: 23),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFB9D8F6), fontSize: 11)),
                const SizedBox(height: 8),
                Text(value, style: const TextStyle(
                  color: Colors.white, fontSize: 24, height: 1, fontWeight: FontWeight.w800,
                )),
                const SizedBox(height: 8),
                Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: accent, fontSize: 10, fontWeight: FontWeight.w600)),
              ],
            )),
          ]),
        );

    final teamRows = people.take(5).map((person) {
      final name = person['full_name']?.toString().trim().isNotEmpty == true
          ? person['full_name'].toString()
          : (person['email']?.toString() ?? 'Profile incomplete');
      final role = _roleLabel(person['role_id']?.toString() ?? '');
      final status = person['status']?.toString() ?? 'Unknown';
      final active = status.toLowerCase() == 'active';
      final initials = name.split(RegExp(r'\s+')).take(2)
          .map((part) => part.isEmpty ? '' : part[0]).join().toUpperCase();
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 7),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0x332C6385))),
        ),
        child: Row(children: [
          Container(
            width: 30, height: 30, alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [Color(0xFF1B6CB2), Color(0xFF0CBACB)]),
            ),
            child: Text(initials.isEmpty ? '?' : initials,
              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 9),
          Expanded(flex: 4, child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFFD9ECFF), fontSize: 11))),
          Expanded(flex: 3, child: Text(role, maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Color(0xFF9DBDDC), fontSize: 10))),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (active ? const Color(0xFF00D5A0) : const Color(0xFFFFBE55)).withValues(alpha: .12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(status, style: TextStyle(
              color: active ? const Color(0xFF00E6B0) : const Color(0xFFFFC96B),
              fontSize: 9, fontWeight: FontWeight.w700,
            )),
          ),
        ]),
      );
    }).toList();

    final teamPanel = panel(
      'Team Overview',
      Icons.groups_2_outlined,
      people.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No team members are available in your authorized scope.',
                style: TextStyle(color: Color(0xFF9DBDDC), fontSize: 11)),
            )
          : Column(children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF0A2942),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Row(children: [
                  Expanded(flex: 4, child: Text('NAME', style: TextStyle(color: Color(0xFF8FB9DF), fontSize: 9, fontWeight: FontWeight.w700))),
                  Expanded(flex: 3, child: Text('ROLE', style: TextStyle(color: Color(0xFF8FB9DF), fontSize: 9, fontWeight: FontWeight.w700))),
                  Text('STATUS', style: TextStyle(color: Color(0xFF8FB9DF), fontSize: 9, fontWeight: FontWeight.w700)),
                ]),
              ),
              ...teamRows,
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerLeft,
                child: Text('Showing ${teamRows.length} of $peopleCount team members',
                  style: const TextStyle(color: Color(0xFF8CB8DF), fontSize: 10)),
              ),
            ]),
      action: TextButton(
        onPressed: _sectionAllowed(ManagementSection.people)
            ? () => setState(() => section = ManagementSection.people)
            : null,
        child: const Text('View all →', style: TextStyle(color: Color(0xFF12CFF4), fontSize: 11)),
      ),
    );

    final branchPanel = panel(
      'Branch Info',
      Icons.apartment_rounded,
      Column(children: [
        _overviewDetailLine('Branch Name', branchName),
        _overviewDetailLine('Locations', locationCount.toString()),
        _overviewDetailLine('Sections', sectionCount.toString()),
        _overviewDetailLine('Total Members', peopleCount.toString()),
        _overviewDetailLine('Active Access', activeCount.toString()),
        _overviewDetailLine('Pending Invitations', pendingCount.toString()),
        const SizedBox(height: 8),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: _sectionAllowed(ManagementSection.organization)
              ? () => setState(() => section = ManagementSection.organization)
              : null,
          icon: const Icon(Icons.settings_outlined, size: 16),
          label: const Text('Edit Branch Settings'),
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFD4E9FF),
            side: const BorderSide(color: Color(0xFF2376A7)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        )),
      ]),
    );

    final quickActions = panel(
      'Quick Actions',
      Icons.bolt_rounded,
      Column(children: [
        if (_canUi('invitation.create') || _canUi('people.invite') || _canUi('manager.assign') || _managementRole() == 'branch_head' || _managementRole() == 'organization_owner')
          _dashboardAction('Invite Team Member', Icons.person_add_alt_1_rounded, _inviteEmployee, primary: true),
        const SizedBox(height: 8),
        _dashboardAction('Manage People', Icons.groups_outlined,
          () => setState(() => section = ManagementSection.people)),
        const SizedBox(height: 8),
        _dashboardAction('Manage Permissions', Icons.shield_outlined,
          () => setState(() => section = ManagementSection.dataAccess)),
        const SizedBox(height: 8),
        _dashboardAction('Review Audit Activity', Icons.query_stats_rounded,
          () => setState(() => section = ManagementSection.audit)),
      ]),
    );

    final activityPanel = panel(
      'Recent Activity',
      Icons.schedule_rounded,
      latest.isEmpty
          ? const Text('Recent management activity will appear here when available.',
              style: TextStyle(color: Color(0xFF9DBDDC), fontSize: 11))
          : Column(children: latest.map(_overviewActivityItem).toList()),
      action: TextButton(
        onPressed: _sectionAllowed(ManagementSection.audit)
            ? () => setState(() => section = ManagementSection.audit)
            : null,
        child: const Text('View all →', style: TextStyle(color: Color(0xFF12CFF4), fontSize: 11)),
      ),
    );

    final hierarchyPanel = panel(
      'Organization Hierarchy',
      Icons.account_tree_outlined,
      Column(children: [
        _overviewStructureStep('Organization Owner', 'Organization-wide access', Icons.workspace_premium_outlined),
        _overviewStructureConnector(),
        _overviewStructureStep(_uiRoleLabel(), branchName, Icons.hub_outlined),
        _overviewStructureConnector(),
        _overviewStructureStep('Team Members', '$peopleCount members in authorized scope', Icons.groups_outlined),
      ]),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          final welcome = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Welcome back, $actorName!',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: compact ? 23 : 26,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.5,
                )),
              const SizedBox(height: 5),
              const Text("Here's what's happening in your branch.",
                style: TextStyle(color: Color(0xFFAED2F4), fontSize: 13)),
            ],
          );
          final filters = Wrap(
            spacing: 8, runSpacing: 8,
            children: [
              if (_isOrganizationOwner && locations.isNotEmpty)
                SizedBox(
                  width: compact ? constraints.maxWidth : 210,
                  child: DropdownButtonFormField<String>(
                    initialValue: locations.any((item) => item['location_id']?.toString() == selectedLocation)
                        ? selectedLocation
                        : locations.first['location_id']?.toString(),
                    isExpanded: true,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.hub_outlined, color: Color(0xFF18D5F3), size: 18),
                      filled: true, fillColor: const Color(0xB8051727),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(9),
                        borderSide: const BorderSide(color: Color(0xFF0C456B)),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                    dropdownColor: const Color(0xFF061727),
                    style: const TextStyle(color: Color(0xFFD9ECFF), fontSize: 11),
                    items: locations.map((item) => DropdownMenuItem<String>(
                      value: item['location_id']?.toString(),
                      child: Text(item['name']?.toString() ?? 'Branch', overflow: TextOverflow.ellipsis),
                    )).toList(),
                    onChanged: (value) => setState(() => selectedLocation = value),
                  ),
                ),
              OutlinedButton.icon(
                onPressed: loadAll,
                icon: const Icon(Icons.refresh_rounded, size: 15),
                label: const Text('Refresh'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFD9ECFF),
                  side: const BorderSide(color: Color(0xFF0C456B)),
                ),
              ),
            ],
          );
          if (compact) {
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              welcome, const SizedBox(height: 14), filters,
            ]);
          }
          return Row(children: [
            Expanded(child: welcome), const SizedBox(width: 18), filters,
          ]);
        }),
        const SizedBox(height: 18),
        LayoutBuilder(builder: (context, constraints) {
          final gap = 12.0;
          final columns = constraints.maxWidth < 570 ? 2 : 4;
          final width = (constraints.maxWidth - (columns - 1) * gap) / columns;
          return Wrap(spacing: gap, runSpacing: gap, children: [
            SizedBox(width: width, child: metric('Team Members', peopleCount.toString(), 'People in your scope', Icons.groups_rounded, const Color(0xFF00CFFF))),
            SizedBox(width: width, child: metric('Locations', locationCount.toString(), 'Configured branches', Icons.storage_rounded, const Color(0xFF168BFF))),
            SizedBox(width: width, child: metric('Sections', sectionCount.toString(), 'Operational groups', Icons.article_outlined, const Color(0xFF00DDB7))),
            SizedBox(width: width, child: metric('Active Access', activeCount.toString(), 'Authorized assignments', Icons.verified_user_outlined, const Color(0xFF00D89A))),
          ]);
        }),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth >= 1080) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 7, child: teamPanel),
              const SizedBox(width: 14),
              Expanded(flex: 3, child: branchPanel),
            ]);
          }
          if (constraints.maxWidth >= 720) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: teamPanel), const SizedBox(width: 12), Expanded(child: branchPanel),
            ]);
          }
          return Column(children: [teamPanel, const SizedBox(height: 12), branchPanel]);
        }),
        const SizedBox(height: 14),
        LayoutBuilder(builder: (context, constraints) {
          if (constraints.maxWidth >= 1080) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 5, child: activityPanel),
              const SizedBox(width: 14),
              Expanded(flex: 4, child: hierarchyPanel),
              const SizedBox(width: 14),
              Expanded(flex: 4, child: quickActions),
            ]);
          }
          if (constraints.maxWidth >= 720) {
            return Column(children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: activityPanel), const SizedBox(width: 12), Expanded(child: hierarchyPanel),
              ]),
              const SizedBox(height: 12), quickActions,
            ]);
          }
          return Column(children: [
            activityPanel, const SizedBox(height: 12), quickActions, const SizedBox(height: 12), hierarchyPanel,
          ]);
        }),
        const SizedBox(height: 18),
        const Divider(color: Color(0x332C6385)),
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 9),
          child: Row(children: [
            Text('InsightFlow', style: TextStyle(color: Color(0xFF5CA4D8), fontSize: 10, fontWeight: FontWeight.w700)),
            Text('  —  Empowering data-driven decisions', style: TextStyle(color: Color(0xFF8FB9DF), fontSize: 10)),
            Spacer(),
            Icon(Icons.circle, color: Color(0xFF00D89A), size: 8),
            SizedBox(width: 6),
            Text('Management data loaded', style: TextStyle(color: Color(0xFF8FB9DF), fontSize: 9)),
          ]),
        ),
      ],
    );
  }

  Widget _dashboardAction(String label, IconData icon, VoidCallback onPressed, {bool primary = false}) =>
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: Icon(icon, size: 17),
          label: Align(alignment: Alignment.centerLeft, child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          style: OutlinedButton.styleFrom(
            alignment: Alignment.centerLeft,
            foregroundColor: primary ? const Color(0xFF001522) : const Color(0xFFD7EBFF),
            backgroundColor: primary ? const Color(0xFF00D4E8) : const Color(0x44105A82),
            side: BorderSide(color: primary ? const Color(0xFF00D4E8) : const Color(0xFF1D6086)),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      );

  Widget _overviewDetailLine(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(children: [
      Expanded(child: Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 11))),
      const SizedBox(width: 10),
      Flexible(child: Text(value.isEmpty ? '—' : value, textAlign: TextAlign.end, maxLines: 2, overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700))),
    ]),
  );

  Widget _overviewStructureStep(String label, String detail, IconData icon) => _glassRow(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      children: [
        Icon(icon, size: 16, color: TechColors.borderActive),
        const SizedBox(width: 9),
        Expanded(child: Text(label, style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700))),
        Text(detail, style: const TextStyle(color: TechColors.textMuted, fontSize: 10)),
      ],
    ),
  );

  Widget _overviewStructureConnector() => const Padding(
    padding: EdgeInsets.symmetric(vertical: 3),
    child: Center(child: Icon(Icons.arrow_downward_rounded, size: 13, color: TechColors.textMuted)),
  );

  Widget organizationView() {
    Widget leadershipRow(
      String label,
      IconData icon,
      Map<String, dynamic>? person, {
      required String emptyText,
    }) {
      final name = person?['full_name']?.toString().trim() ?? '';
      final employeeId = person?['employee_id']?.toString().trim() ?? '';
      final display = person == null
          ? emptyText
          : name.isEmpty
              ? (employeeId.isEmpty ? 'Profile incomplete' : employeeId)
              : employeeId.isEmpty ? name : '$name · $employeeId';
      return _glassRow(
        child: Row(
          children: [
            Icon(icon, size: 15, color: TechColors.textMuted),
            const SizedBox(width: 8),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: TechColors.textMuted,
                fontSize: 10,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                display,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xE8113551), Color(0xC8061727), Color(0xB8051727)]),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF1374A2).withValues(alpha: .75)),
            boxShadow: const [BoxShadow(color: Color(0x1800CFFF), blurRadius: 24, offset: Offset(0, 6))],
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _eyebrow('ORGANIZATION / STRUCTURE'),
            const SizedBox(height: 8),
            const Text('Organization structure', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.4)),
            const SizedBox(height: 6),
            const Text('Map branches, leadership, and operational sections from one clear workspace.', style: TextStyle(color: Color(0xFF9DBDDC), fontSize: 12, height: 1.45)),
            const SizedBox(height: 16),
            Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (_canUi('organization.structure.manage')) _actionChip('CREATE LOCATION', Icons.add_location_alt_outlined, createLocation),
              if (_canUi('organization.structure.manage') || _canUi('organization.section.create')) _actionChip('CREATE SECTION', Icons.account_tree_outlined, createSection, accent: true),
              _actionChip('REFRESH', Icons.refresh_rounded, loadAll),
            ])),
          ]),
        ),
        const SizedBox(height: 13),
        LayoutBuilder(builder: (context, constraints) {
          final gap = 10.0, columns = constraints.maxWidth < 500 ? 2 : 4;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          Widget stat(String label, int value, IconData icon, Color accent) => Container(
            width: width, padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(color: const Color(0xB8051727), borderRadius: BorderRadius.circular(12), border: Border.all(color: accent.withValues(alpha: .4))),
            child: Row(children: [
              Icon(icon, color: accent, size: 19), const SizedBox(width: 9),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(value.toString(), style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
                const SizedBox(height: 3), Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF9DBDDC), fontSize: 10)),
              ])),
            ]),
          );
          return Wrap(spacing: gap, runSpacing: gap, children: [
            stat('Branches / locations', locations.length, Icons.apartment_rounded, const Color(0xFF00CFFF)),
            stat('Operational sections', sections.length, Icons.account_tree_outlined, const Color(0xFF168BFF)),
            stat('Active assignments', assignments.where((a) => a['status'] == 'active').length, Icons.verified_user_outlined, const Color(0xFF00D89A)),
            stat('Team members', people.length, Icons.groups_2_outlined, const Color(0xFF00DDB7)),
          ]);
        }),
        const SizedBox(height: 16),
        Row(children: [
          const Expanded(child: Text('Branches and teams', style: TextStyle(color: Color(0xFFE5F2FF), fontSize: 16, fontWeight: FontWeight.w800))),
          Text(locations.length.toString() + ' locations', style: const TextStyle(color: Color(0xFF8FB9DF), fontSize: 10)),
        ]),
        const SizedBox(height: 9),
        // Keep the heading and actions in separate rows at every width.
        // In the desktop Row layout, the action Wrap can consume most of the
        // available width and leave the heading so narrow that Flutter wraps
        // "ORGANIZATION STRUCTURE" one character per line.
        const SizedBox(height: 2),
        if (locations.isEmpty)
          surface(
            const Padding(
              padding: EdgeInsets.all(28),
              child: Center(
                child: Text(
                  'No organizational structure is configured yet.',
                  style: TextStyle(color: TechColors.textMuted),
                ),
              ),
            ),
          ),
        ...locations.map((l) {
        final id = l['location_id'].toString();
        final secs =
            sections.where((s) => s['location_id'].toString() == id).toList();
        final asg = assignments
            .where(
              (a) =>
                  a['location_id'].toString() == id &&
                  a['status'] == 'active',
            )
            .toList();
        final managers =
            asg.where((a) => a['role_id'] == 'manager').toList();
        final branchHeads =
            asg.where((a) => a['role_id'] == 'branch_head').toList();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GlassCard(
            margin: EdgeInsets.zero,
            padding: const EdgeInsets.all(14),
            shape: const LiquidRoundedSuperellipse(borderRadius: 16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => setState(() {
                selectedLocation = id;
                selectedSection = null;
              }),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                  children: [
                    const Icon(
                      Icons.location_on_outlined,
                      size: 17,
                      color: TechColors.borderActive,
                    ),
                    const SizedBox(width: 9),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l['name'].toString(),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l['branch_identifier'].toString(),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: TechColors.textMuted,
                              fontSize: 10,
                              fontFamily: 'monospace',
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (selectedLocation == id)
                      const Padding(
                        padding: EdgeInsets.only(left: 8),
                        child: Icon(
                          Icons.check_circle_outline,
                          size: 15,
                          color: TechColors.borderActive,
                        ),
                      ),
                    _statusDot(l['status']?.toString() ?? 'active'),
                  ],
                ),
                const SizedBox(height: 10),
                leadershipRow(
                  'BRANCH HEAD',
                  Icons.badge_outlined,
                  branchHeads.isEmpty ? null : branchHeads.first,
                  emptyText: 'No active Branch Head assignment',
                ),
                const SizedBox(height: 7),
                leadershipRow(
                  'MANAGER',
                  Icons.manage_accounts_outlined,
                  managers.isEmpty ? null : managers.first,
                  emptyText: 'No separate manager assigned',
                ),
                if (secs.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _eyebrow('Sections'),
                  const SizedBox(height: 7),
                  ...secs.map((s) {
                    final members = asg
                        .where(
                          (a) =>
                              a['section_id']?.toString() ==
                                  s['section_id']?.toString() &&
                              a['role_id'] == 'team_lead',
                        )
                        .toList();
                    final sectionId = s['section_id']?.toString() ?? '';
                    final sectionSelected = selectedSection == sectionId;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _glassRow(
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() {
                            selectedLocation = id;
                            selectedSection = sectionId;
                          }),
                          child: Row(
                            children: [
                            const Icon(
                              Icons.account_tree_outlined,
                              size: 14,
                              color: TechColors.statusBlue,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    s['name'].toString(),
                                    maxLines: 1,
                                    softWrap: false,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Text(
                                    '${s['member_count'] ?? 0} members',
                                    style: const TextStyle(
                                      color: TechColors.textMuted,
                                      fontSize: 10,
                                      fontFamily: 'monospace',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (sectionSelected)
                              const Padding(
                                padding: EdgeInsets.only(left: 8),
                                child: Icon(
                                  Icons.check_circle_outline,
                                  size: 15,
                                  color: TechColors.borderActive,
                                ),
                              ),
                            if (members.isNotEmpty)
                              Text(
                                members.length.toString(),
                                style: const TextStyle(
                                  color: TechColors.textMuted,
                                  fontFamily: 'monospace',
                                  fontSize: 10,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          ),
        );
      }),
      ],
    );
  }
  Widget peopleView() {
    final query = search.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final roleOptions = people.map((p) => p['role_id']?.toString() ?? '').where((v) => v.isNotEmpty).toSet().toList()..sort();
    final locationOptions = List<Map<String, dynamic>>.from(locations)..sort((a,b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    final sectionOptions = sections.where((item) => selectedLocation == null || item['location_id']?.toString() == selectedLocation).toList()..sort((a,b) => (a['name']?.toString() ?? '').compareTo(b['name']?.toString() ?? ''));
    final activeCount = people.where((p) => (p['status']?.toString().toLowerCase() ?? '') == 'active').length;
    final assignedCount = people.where((p) {
      final l = p['location_name']?.toString().trim() ?? '', sec = p['section_name']?.toString().trim() ?? '';
      return l.isNotEmpty && l.toLowerCase() != 'unassigned' && sec.isNotEmpty && sec.toLowerCase() != 'unassigned';
    }).length;
    final pendingCount = invitations.where((item) {
      final status = item['status']?.toString().trim().toLowerCase() ?? '';
      final expiry = DateTime.tryParse(item['expires_at']?.toString() ?? '');
      return status == 'invited' && (expiry == null || !expiry.isBefore(DateTime.now()));
    }).length;
    final filtered = people.where((p) {
      final fields = [p['full_name'],p['email'],p['employee_id'],p['role_id'],p['location_name'],p['section_name'],p['status']].whereType<Object>().map((v) => v.toString().toLowerCase().trim());
      if (query.isNotEmpty && !fields.any((v) => v.contains(query))) return false;
      if (selectedLocation != null && p['location_id']?.toString() != selectedLocation) return false;
      if (selectedSection != null && p['section_id']?.toString() != selectedSection) return false;
      if (selectedRole != null && p['role_id']?.toString() != selectedRole) return false;
      return true;
    }).toList();
    final hasFilters = search.trim().isNotEmpty || selectedLocation != null || selectedSection != null || selectedRole != null;

    Widget metric(String label, int value, IconData icon, Color accent) => Container(
      constraints: const BoxConstraints(minHeight: 88), padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(gradient: LinearGradient(colors: [accent.withValues(alpha: .14), const Color(0xB8051727)]), borderRadius: BorderRadius.circular(12), border: Border.all(color: accent.withValues(alpha: .48))),
      child: Row(children: [
        Container(width: 38,height:38,alignment:Alignment.center,decoration:BoxDecoration(color:accent.withValues(alpha:.14),borderRadius:BorderRadius.circular(11)),child:Icon(icon,color:accent,size:20)),
        const SizedBox(width:10),
        Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.center,children:[
          Text(value.toString(),style:const TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w800)),
          const SizedBox(height:4),Text(label,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFF9DBDDC),fontSize:10,fontWeight:FontWeight.w600)),
        ])),
      ]),
    );

    Widget personCard(Map<String,dynamic> p) {
      final name=p['full_name']?.toString().trim()??'', email=p['email']?.toString().trim()??'', employeeId=p['employee_id']?.toString().trim()??'';
      final roleId=p['role_id']?.toString()??'', role=_roleLabel(roleId.isEmpty?'—':roleId);
      final location=p['location_name']?.toString().trim()??'', sectionName=p['section_name']?.toString().trim()??'', status=p['status']?.toString().trim()??'Unknown';
      final assignmentId=p['assignment_id']?.toString()??'';
      final target=assignments.where((a)=>assignmentId.isNotEmpty&&a['assignment_id']?.toString()==assignmentId).firstOrNull ??
        assignments.where((a)=>employeeId.isNotEmpty&&a['employee_id']?.toString()==employeeId).firstOrNull ?? (assignmentId.isNotEmpty?p:null);
      final displayName=name.isEmpty?'Profile incomplete':name;
      final initials=displayName.split(RegExp(r'\s+')).where((v)=>v.isNotEmpty).take(2).map((v)=>v[0]).join().toUpperCase();
      final active=status.toLowerCase()=='active';
      return Container(
        padding:const EdgeInsets.all(14),
        decoration:BoxDecoration(color:const Color(0xA8061B2C),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFF164564).withValues(alpha:.8))),
        child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Container(width:44,height:44,alignment:Alignment.center,decoration:BoxDecoration(gradient:const LinearGradient(colors:[Color(0xFF176CB3),Color(0xFF08AFC3)]),borderRadius:BorderRadius.circular(13)),child:Text(initials.isEmpty?'?':initials,style:const TextStyle(color:Colors.white,fontSize:13,fontWeight:FontWeight.w800))),
            const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(displayName,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFFE5F2FF),fontSize:14,fontWeight:FontWeight.w700)),
              const SizedBox(height:4),Text(email.isEmpty?'Email not available':email,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFF9DBDDC),fontSize:11)),
              if(employeeId.isNotEmpty)...[const SizedBox(height:4),Text(employeeId,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFF76A9D0),fontSize:10,fontFamily:'monospace'))],
            ])),const SizedBox(width:8),_statusDot(status),
          ]),
          const SizedBox(height:12),Wrap(spacing:7,runSpacing:7,children:[_verificationBadge(role,true),_verificationBadge(status,active)]),
          const SizedBox(height:11),
          Container(padding:const EdgeInsets.all(10),decoration:BoxDecoration(color:const Color(0xFF061522),borderRadius:BorderRadius.circular(10)),child:Column(children:[
            Row(children:[const Icon(Icons.location_on_outlined,size:15,color:Color(0xFF43C8F3)),const SizedBox(width:7),Expanded(child:Text(location.isEmpty?'Unassigned location':location,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFFB8D5EF),fontSize:11)))]),
            const SizedBox(height:7),Row(children:[const Icon(Icons.account_tree_outlined,size:15,color:Color(0xFF43C8F3)),const SizedBox(width:7),Expanded(child:Text(sectionName.isEmpty?'Unassigned section':sectionName,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFFB8D5EF),fontSize:11)))]),
          ])),
          if(target!=null)...[const SizedBox(height:7),Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>_showAssignmentProfile(target),icon:const Icon(Icons.open_in_new_rounded,size:15),label:const Text('View profile')))],
        ]),
      );
    }

    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      LayoutBuilder(builder:(context,c){
        final compact=c.maxWidth<640;
        final heading=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          _eyebrow('PEOPLE DIRECTORY'),const SizedBox(height:7),
          const Text('People',style:TextStyle(color:Color(0xFFE8F4FF),fontSize:25,fontWeight:FontWeight.w800,letterSpacing:-.4)),
          const SizedBox(height:5),const Text('A clear view of your team, roles, and branch assignments.',style:TextStyle(color:Color(0xFF9DBDDC),fontSize:12,height:1.45)),
        ]);
        final actions=Wrap(spacing:8,runSpacing:8,children:[
          OutlinedButton.icon(onPressed:loadAll,icon:const Icon(Icons.refresh_rounded,size:16),label:const Text('Refresh'),style:OutlinedButton.styleFrom(foregroundColor:const Color(0xFFD8ECFF),side:const BorderSide(color:Color(0xFF1D6086)))),
          if(_canUi('invitation.manage')||_canUi('invitation.create')||_canUi('people.invite'))
            FilledButton.icon(onPressed:_inviteEmployee,icon:const Icon(Icons.person_add_alt_1_rounded,size:17),label:const Text('Invite member'),style:FilledButton.styleFrom(backgroundColor:const Color(0xFF00CFE8),foregroundColor:const Color(0xFF001522))),
        ]);
        if(compact)return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[heading,const SizedBox(height:14),Align(alignment:Alignment.centerLeft,child:actions)]);
        return Row(crossAxisAlignment:CrossAxisAlignment.end,children:[Expanded(child:heading),const SizedBox(width:16),actions]);
      }),
      const SizedBox(height:17),
      LayoutBuilder(builder:(context,c){
        final columns=c.maxWidth<520?2:4,gap=10.0,width=(c.maxWidth-gap*(columns-1))/columns;
        return Wrap(spacing:gap,runSpacing:gap,children:[
          SizedBox(width:width,child:metric('Total people',people.length,Icons.groups_2_outlined,const Color(0xFF00CFFF))),
          SizedBox(width:width,child:metric('Active members',activeCount,Icons.verified_user_outlined,const Color(0xFF00D89A))),
          SizedBox(width:width,child:metric('Assigned',assignedCount,Icons.account_tree_outlined,const Color(0xFF168BFF))),
          SizedBox(width:width,child:metric('Pending invitations',pendingCount,Icons.mark_email_unread_outlined,const Color(0xFF00DDB7))),
        ]);
      }),
      const SizedBox(height:15),
      Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:const Color(0xB8051727),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFF164564).withValues(alpha:.9))),child:Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
        TextField(onChanged:(v)=>setState(()=>search=v),style:const TextStyle(color:Color(0xFFE5F2FF),fontSize:13),decoration:InputDecoration(hintText:'Search name, email, employee ID, or role',hintStyle:const TextStyle(color:Color(0xFF7399B8),fontSize:12),prefixIcon:const Icon(Icons.search_rounded,size:19,color:Color(0xFF43C8F3)),suffixIcon:search.isEmpty?null:IconButton(tooltip:'Clear search',onPressed:()=>setState(()=>search=''),icon:const Icon(Icons.close_rounded,size:18)),filled:true,fillColor:const Color(0xFF061522),isDense:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(11)))),
        const SizedBox(height:11),
        LayoutBuilder(builder:(context,c){
          final narrow=c.maxWidth<680;
          final filters=<Widget>[
            if (_isOrganizationOwner)
              DropdownButtonFormField<String?>(key:ValueKey('people-location-$selectedLocation'),initialValue:selectedLocation,isExpanded:true,decoration:input('Branch / location').copyWith(isDense:true),dropdownColor:const Color(0xFF061727),items:[const DropdownMenuItem<String?>(value:null,child:Text('All locations')),...locationOptions.map((v)=>DropdownMenuItem<String?>(value:v['location_id']?.toString(),child:Text(v['name']?.toString()??'Unnamed location',overflow:TextOverflow.ellipsis)))],onChanged:(v) => setState(() { selectedLocation = v; if (selectedSection != null && !sections.any((item) => item['section_id']?.toString() == selectedSection && (v == null || item['location_id']?.toString() == v))) { selectedSection = null; } })),
            DropdownButtonFormField<String?>(key:ValueKey('people-section-$selectedSection'),initialValue:selectedSection,isExpanded:true,decoration:input('Section').copyWith(isDense:true),dropdownColor:const Color(0xFF061727),items:[const DropdownMenuItem<String?>(value:null,child:Text('All sections')),...sectionOptions.map((v)=>DropdownMenuItem<String?>(value:v['section_id']?.toString(),child:Text(v['name']?.toString()??'Unnamed section',overflow:TextOverflow.ellipsis)))],onChanged:(v)=>setState(()=>selectedSection=v)),
            DropdownButtonFormField<String?>(key:ValueKey('people-role-$selectedRole'),initialValue:selectedRole,isExpanded:true,decoration:input('Role').copyWith(isDense:true),dropdownColor:const Color(0xFF061727),items:[const DropdownMenuItem<String?>(value:null,child:Text('All roles')),...roleOptions.map((v)=>DropdownMenuItem<String?>(value:v,child:Text(_roleLabel(v),overflow:TextOverflow.ellipsis)))],onChanged:(v)=>setState(()=>selectedRole=v)),
          ];
          if(narrow)return Column(children:[for(var i=0;i<filters.length;i++)... [filters[i],if(i+1<filters.length)const SizedBox(height:9)]]);
          return Row(children:[for(var i=0;i<filters.length;i++)...[Expanded(child:filters[i]),if(i+1<filters.length)const SizedBox(width:10)]]);
        }),
        if(hasFilters)Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed: () => setState(() { search = ''; selectedLocation = null; selectedSection = null; selectedRole = null; }),icon:const Icon(Icons.filter_alt_off_rounded,size:16),label:const Text('Clear search and filters'))),
      ])),
      const SizedBox(height:14),Row(children:[const Expanded(child:Text('Team members',style:TextStyle(color:Color(0xFFE0F0FF),fontSize:15,fontWeight:FontWeight.w700))),Text('\${filtered.length} shown',style:const TextStyle(color:Color(0xFF8FB9DF),fontSize:11))]),const SizedBox(height:10),
      if(people.isEmpty)surface(const Padding(padding:EdgeInsets.symmetric(vertical:32,horizontal:16),child:Column(children:[Icon(Icons.groups_outlined,size:32,color:Color(0xFF43C8F3)),SizedBox(height:11),Text('No people yet',style:TextStyle(color:Color(0xFFE5F2FF),fontWeight:FontWeight.w700)),SizedBox(height:6),Text('Invited team members will appear here after they join your workspace.',textAlign:TextAlign.center,style:TextStyle(color:Color(0xFF9DBDDC),fontSize:12,height:1.5))])))
      else if(filtered.isEmpty)surface(Padding(padding:const EdgeInsets.all(28),child:Column(children:[const Icon(Icons.search_off_rounded,size:29,color:Color(0xFF43C8F3)),const SizedBox(height:10),Text(query.isNotEmpty?'No people match your search':'No people match these filters',style:const TextStyle(color:Color(0xFFE5F2FF),fontWeight:FontWeight.w700)),const SizedBox(height:6),const Text('Try a different search or update your branch, section, and role filters.',textAlign:TextAlign.center,style:TextStyle(color:Color(0xFF9DBDDC),fontSize:12),),TextButton.icon(onPressed: () => setState(() { search = ''; selectedLocation = null; selectedSection = null; selectedRole = null; }),icon:const Icon(Icons.filter_alt_off_rounded,size:16),label:const Text('Clear search and filters'))])))
      else LayoutBuilder(builder:(context,c){
        final columns=c.maxWidth<900?1:2;
        if(columns==1)return Column(children:filtered.map((p)=>Padding(padding:const EdgeInsets.only(bottom:9),child:personCard(p))).toList());
        final width=(c.maxWidth-12)/2;
        return Wrap(spacing:12,runSpacing:12,children:filtered.map((p)=>SizedBox(width:width,child:personCard(p))).toList());
      }),
    ]);
  }

  String _auditActionLabel(String raw) {
    const labels = <String, String>{'management.location.created':'Location created','management.section.created':'Section created','management.manager.assigned':'Manager assigned','management.manager.changed':'Manager changed','management.team_lead.assigned':'Team Lead assigned','management.assignment.changed':'Assignment changed'};
    return labels[raw] ?? raw.replaceAll(RegExp(r'[._-]+'), ' ').split(RegExp(r'\s+')).where((part)=>part.isNotEmpty).map((part)=>part[0].toUpperCase()+part.substring(1)).join(' ');
  }
  String _auditActor(Map<String,dynamic> event) {
    final id=event['actor_principal_id']?.toString().trim()??'';
    for(final person in people){if((person['principal_id']?.toString().trim()??'')==id){final name=person['full_name']?.toString().trim()??'';final emp=person['employee_id']?.toString().trim()??'';if(name.isNotEmpty)return name;if(emp.isNotEmpty)return emp;}}
    return id.isEmpty?'Organization activity':'Organization member';
  }
  String _auditContext(Map<String,dynamic> event) {
    final metadata=event['metadata'];if(metadata is! Map)return '';
    final parts=<String>[];
    for(final key in ['employee_id','branch_identifier']){final v=metadata[key]?.toString().trim()??'';if(v.isNotEmpty)parts.add(v);}
    for(final key in ['location_id','section_id','assignment_id','principal_id']){
      final v=metadata[key]?.toString().trim()??'';if(v.isEmpty)continue;
      final collection=key=='location_id'?locations:key=='section_id'?sections:key=='assignment_id'?assignments:people;
      final idKey=key=='location_id'?'location_id':key=='section_id'?'section_id':key=='assignment_id'?'assignment_id':'principal_id';
      Map<String,dynamic>? match;for(final item in collection){if(item[idKey]?.toString()==v){match=item;break;}}
      final label=match==null?'':(match['name']??match['full_name']??match['employee_id'])?.toString()??'';
      parts.add(label.isNotEmpty?label:key.replaceAll('_id','').replaceAll('_',' '));
    }
    return parts.toSet().join(' · ');
  }
  String _auditTimestamp(dynamic value){final raw=value?.toString().trim()??'';if(raw.isEmpty)return 'Time unavailable';final formatted=_formatEmployeeTimestamp(raw);return formatted=='—'?raw:formatted.replaceFirst('\n',' · ');}
  String _auditCategory(Map<String,dynamic> event){
    final a=event['action']?.toString().toLowerCase()??'';
    if(a.contains('location')||a.contains('section'))return 'Organization';
    if(a.contains('member')||a.contains('assignment')||a.contains('manager')||a.contains('team_lead'))return 'People';
    if(a.contains('access')||a.contains('permission'))return 'Access';
    if(a.contains('invitation'))return 'Invitations';if(a.contains('dataset'))return 'Data';return 'Other';
  }
  Widget auditView(){
    final categories=audit.map(_auditCategory).toSet().toList()..sort();final query=auditSearch.trim().toLowerCase();
    final filtered=audit.where((e){if(auditCategory!=null&&_auditCategory(e)!=auditCategory)return false;if(query.isEmpty)return true;return [_auditActionLabel(e['action']?.toString()??'Activity'),_auditActor(e),_auditContext(e),e['outcome']?.toString()??'',e['action']?.toString()??''].join(' ').toLowerCase().contains(query);}).toList();
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xE8113551), Color(0xB8051727)]),
        borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF164F70)),
      ), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 44, height: 44, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF0D3854), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.history_rounded, color: Color(0xFF43C8F3), size: 23)),
        const SizedBox(width: 13), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _eyebrow('GOVERNANCE / TRACEABILITY'),
          const SizedBox(height: 7),
          const Text('Audit Activity', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -.4)),
          const SizedBox(height: 5),
          const Text('Review who changed what, when it happened, and the outcome of each management action.', style: TextStyle(color: Color(0xFF9DBDDC), fontSize: 12, height: 1.45)),
        ])),
        IconButton(tooltip: 'Refresh activity', onPressed: loadAll, icon: const Icon(Icons.refresh_rounded, color: Color(0xFFBFEAFF))),
      ])),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final gap = 10.0, columns = constraints.maxWidth < 520 ? 1 : 3;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        Widget stat(String label, int value, IconData icon, Color accent) => Container(
          width: width, padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(color: const Color(0xB8051727), borderRadius: BorderRadius.circular(12), border: Border.all(color: accent.withValues(alpha: .4))),
          child: Row(children: [Icon(icon, color: accent, size: 19), const SizedBox(width: 9), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value.toString(), style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 3), Text(label, style: const TextStyle(color: Color(0xFF9DBDDC), fontSize: 10)),
          ]))]),
        );
        final successful = audit.where((e) => ['success', 'succeeded'].contains(e['outcome']?.toString().toLowerCase())).length;
        final peopleEvents = audit.where((e) => _auditCategory(e) == 'People').length;
        return Wrap(spacing: gap, runSpacing: gap, children: [
          stat('Recorded activities', audit.length, Icons.receipt_long_outlined, const Color(0xFF00CFFF)),
          stat('People & role events', peopleEvents, Icons.groups_outlined, const Color(0xFF168BFF)),
          stat('Successful outcomes', successful, Icons.verified_outlined, const Color(0xFF00D89A)),
        ]);
      }),
      const SizedBox(height: 14),
      LayoutBuilder(builder:(context,c){final search=TextField(key:const ValueKey('audit-search'),onChanged:(v)=>setState(()=>auditSearch=v),decoration:input('Search activity').copyWith(prefixIcon:const Icon(Icons.search_rounded,color:TechColors.textMuted),suffixIcon:auditSearch.isEmpty?null:IconButton(tooltip:'Clear search',onPressed:()=>setState(()=>auditSearch=''),icon:const Icon(Icons.close_rounded))));final filter=DropdownButtonFormField<String?>(key:ValueKey('audit-category-$auditCategory'),initialValue:auditCategory,decoration:input('Activity area'),items:[const DropdownMenuItem<String?>(value:null,child:Text('All activity')),...categories.map((v)=>DropdownMenuItem<String?>(value:v,child:Text(v)))],onChanged:(v)=>setState(()=>auditCategory=v));return c.maxWidth<560?Column(children:[search,const SizedBox(height:10),filter]):Row(children:[Expanded(flex:3,child:search),const SizedBox(width:10),Expanded(flex:2,child:filter)]);}),
      if(auditSearch.isNotEmpty||auditCategory!=null)Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed:()=>setState(() { auditSearch = ''; auditCategory = null; }),icon:const Icon(Icons.filter_alt_off_rounded,size:16),label:const Text('Clear search and filters'))),
      const SizedBox(height:8),
      if(audit.isEmpty)surface(const Padding(padding:EdgeInsets.symmetric(vertical:22,horizontal:12),child:Column(children:[Icon(Icons.history_toggle_off_rounded,color:TechColors.textMuted,size:30),SizedBox(height:10),Text('No activity to show yet',style:TextStyle(color:TechColors.textPrimary,fontWeight:FontWeight.w700)),SizedBox(height:5),Text('Important organization activity will appear here when available.',textAlign:TextAlign.center,style:TextStyle(color:TechColors.textMuted,fontSize:12))])))
      else if(filtered.isEmpty)surface(Padding(padding:const EdgeInsets.all(22),child:Column(children:[const Text('No activity matches your search or filters.',textAlign:TextAlign.center,style:TextStyle(color:TechColors.textMuted)),TextButton(onPressed:()=>setState(() { auditSearch = ''; auditCategory = null; }),child:const Text('Clear search and filters'))])))
      else Column(children:filtered.map((e){final action=e['action']?.toString()??'Activity';final outcome=e['outcome']?.toString().trim()??'';final contextLabel=_auditContext(e);return Padding(padding:const EdgeInsets.only(bottom:9),child:Material(color:Colors.transparent,child:InkWell(borderRadius:BorderRadius.circular(15),onTap:()=>_showAuditDetails(e),child:_glassRow(padding:const EdgeInsets.all(14),child:LayoutBuilder(builder:(context,c){final primary=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[Text(_auditActionLabel(action),style:const TextStyle(color:TechColors.textPrimary,fontSize:14,fontWeight:FontWeight.w700)),const SizedBox(height:6),Text('By \${_auditActor(e)}',style:const TextStyle(color:TechColors.textMuted,fontSize:12)),if(contextLabel.isNotEmpty)...[const SizedBox(height:4),Text(contextLabel,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:TechColors.textMuted,fontSize:11))]]);final time=Text(_auditTimestamp(e['created_at']),style:const TextStyle(color:TechColors.textMuted,fontSize:11));final result=Text(outcome.isEmpty?'Result unavailable':_auditActionLabel(outcome),style:TextStyle(color:outcome.toLowerCase()=='succeeded'?TechColors.statusGreen:TechColors.textMuted,fontSize:11,fontWeight:FontWeight.w600));return c.maxWidth<480?Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[primary,const SizedBox(height:9),time,const SizedBox(height:4),result,const SizedBox(height:5),const Align(alignment:Alignment.centerRight,child:Icon(Icons.chevron_right_rounded,color:TechColors.textMuted))]):Row(children:[Expanded(child:primary),const SizedBox(width:14),SizedBox(width:145,child:Column(crossAxisAlignment:CrossAxisAlignment.end,children:[time,const SizedBox(height:5),result]))]);})))));}).toList()),
      const SizedBox(height:4),Text('\${filtered.length} of \${audit.length} activities',textAlign:TextAlign.end,style:const TextStyle(color:TechColors.textMuted,fontSize:10)),
    ]);
  }
    Widget _auditSkeleton() {
    Widget block({double height = 12, double? width, double radius = 7}) => Container(
      height: height, width: width,
      decoration: BoxDecoration(color: TechColors.textMuted.withValues(alpha: .12), borderRadius: BorderRadius.circular(radius)),
    );
    Widget hero() => Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xE8113551), Color(0xB8051727)]),
        borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFF164F70)),
      ),
      child: Row(children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: const Color(0xFF0D3854), borderRadius: BorderRadius.circular(12)), child: Center(child: block(width: 20, height: 20, radius: 6))),
        const SizedBox(width: 13), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          block(width: 150, height: 10), const SizedBox(height: 9), block(width: 190, height: 23), const SizedBox(height: 7), block(width: 290, height: 12),
        ])),
      ]),
    );
    Widget metric(double width) => Container(
      width: width, padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(color: const Color(0xB8051727), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0x5539BFEF))),
      child: Row(children: [block(width: 20, height: 20, radius: 6), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [block(width: 45, height: 21), const SizedBox(height: 5), block(width: 105, height: 10)]))]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      hero(),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final gap = 10.0, columns = constraints.maxWidth < 520 ? 1 : 3;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: gap, children: List.generate(3, (_) => metric(width)));
      }),
      const SizedBox(height: 14),
      Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: const Color(0xB8051727), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF164564))),
        child: LayoutBuilder(builder: (context, constraints) {
          final search = block(height: 46);
          final filter = block(height: 46);
          return constraints.maxWidth < 560 ? Column(children: [search, const SizedBox(height: 10), filter]) : Row(children: [Expanded(flex: 3, child: search), const SizedBox(width: 10), Expanded(flex: 2, child: filter)]);
        }),
      ),
      const SizedBox(height: 12),
      Row(children: [block(width: 130, height: 15), const Spacer(), block(width: 70, height: 10)]),
      const SizedBox(height: 9),
      ...List.generate(4, (_) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: _glassRow(padding: const EdgeInsets.all(14), child: LayoutBuilder(builder: (context, constraints) {
          final identity = Row(children: [block(width: 36, height: 36, radius: 10), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [block(width: 190, height: 13), const SizedBox(height: 7), block(width: 120, height: 10), const SizedBox(height: 6), block(width: 215, height: 10)]))]);
          final metadata = Column(crossAxisAlignment: CrossAxisAlignment.end, children: [block(width: 105, height: 10), const SizedBox(height: 7), block(width: 72, height: 18, radius: 20)]);
          return constraints.maxWidth < 480 ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [identity, const SizedBox(height: 12), metadata]) : Row(children: [Expanded(child: identity), const SizedBox(width: 14), metadata]);
        })),
      )),
    ]);
  }

  void _showAuditDetails(Map<String,dynamic> event){
    final eventId=event['event_id']?.toString()??'';
    showDialog<void>(context:context,builder:(context)=>_ManagementGlassDialog(title:const Text('Activity details'),content:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisSize:MainAxisSize.min,children:[Text(_auditActionLabel(event['action']?.toString()??'Activity'),style:const TextStyle(fontSize:16,fontWeight:FontWeight.w700)),const SizedBox(height:12),_detailLine('Actor',_auditActor(event)),_detailLine('When',_auditTimestamp(event['created_at'])),_detailLine('Result',event['outcome']?.toString()??'—'),if(_auditContext(event).isNotEmpty)_detailLine('Context',_auditContext(event)),const SizedBox(height:8),const Text('Reference details',style:TextStyle(color:TechColors.textMuted,fontSize:11,fontWeight:FontWeight.w700)),if(eventId.isNotEmpty)_detailLine('Event reference',eventId),if(event['actor_principal_id']!=null)_detailLine('Actor reference',event['actor_principal_id'].toString()),]),actions:[TextButton(onPressed:()=>Navigator.pop(context),child:const Text('Close'))]));
  }
  Widget _detailLine(String label,String value)=>Padding(padding:const EdgeInsets.symmetric(vertical:5),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[SizedBox(width:112,child:Text(label,style:const TextStyle(color:TechColors.textMuted,fontSize:11))),Expanded(child:SelectableText(value,style:const TextStyle(color:TechColors.textPrimary,fontSize:12)))]));

  Widget legacyView(String title, String text, {String actionLabel = 'OPEN LEGACY TOOLS'}) => surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _eyebrow(title), const SizedBox(height: 7),
    Text(text, style: const TextStyle(color: TechColors.textMuted, height: 1.45)),
    const SizedBox(height: 14),
    _actionChip(
      actionLabel,
      Icons.open_in_new,
      () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AuthorizationManagementScreen(
            onStartWorking: (datasetId) async {
              final headers = await supabaseAuthHeaders();
              final response = await http.post(
                Uri.parse('$insightFlowBackendBaseUrl/v1/managed-datasets/$datasetId/working-copies'),
                headers: {
                  ...headers,
                  if (insightFlowWorkspaceId.isNotEmpty)
                    'X-InsightFlow-Workspace-ID': insightFlowWorkspaceId,
                },
              );
              if (response.statusCode < 200 || response.statusCode >= 300) {
                throw StateError('Unable to create a managed dataset working copy.');
              }
              if (!mounted) return;
              final decoded = jsonDecode(response.body);
              final workingCopy = decoded is Map && decoded['working_copy'] is Map
                  ? Map<String, dynamic>.from(decoded['working_copy'] as Map)
                  : <String, dynamic>{};
              Navigator.of(context).pop();
              openInsightFlowAnalysis(
                context,
                managedDatasetId: datasetId,
                managedVersionId: workingCopy['structured_version_id']?.toString() ??
                    workingCopy['source_version']?.toString(),
                managedWorkingCopyId: workingCopy['working_copy_id']?.toString(),
              );
            },
          ),
        ),
      ),
      accent: true,
    ),
  ]));


  Map<String, dynamic>? _invitationPerson(Map<String, dynamic> invitation) {
    final employeeId = invitation['employee_id']?.toString().trim() ?? '';
    if (employeeId.isEmpty) return null;
    for (final person in people) {
      if ((person['employee_id']?.toString().trim() ?? '') == employeeId) return person;
    }
    return null;
  }

  String _invitationStatusLabel(String rawStatus, {bool expiredByDate = false}) {
    final status = rawStatus.trim().toLowerCase();
    if (expiredByDate) return 'Expired';
    if (status.isEmpty) return 'Unknown';
    if (status == 'invited') return 'Pending';
    return status.split(RegExp(r'[_\\-\\s]+')).where((part) => part.isNotEmpty)
        .map((part) => part[0].toUpperCase() + part.substring(1)).join(' ');
  }

  String _formatInvitationExpiry(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '—';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    final local = parsed.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
    final minute = local.minute.toString().padLeft(2, '0');
    final period = local.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/${local.year} · $hour:$minute $period';
  }

  Widget _invitationStatusChip(String label, String rawStatus) {
    final normalized = rawStatus.trim().toLowerCase();
    final foreground = normalized == 'accepted'
        ? TechColors.statusGreen
        : normalized == 'invited'
            ? TechColors.statusBlue
            : normalized == 'expired' || normalized == 'revoked'
                ? TechColors.statusRed
                : TechColors.textPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.28)),
      ),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
        style: TextStyle(color: foreground, fontSize: 10, fontWeight: FontWeight.w700)),
    );
  }

    Widget _invitationSkeleton() {
    Widget block({double height = 12, double? width, double radius = 7}) => Container(
      height: height, width: width,
      decoration: BoxDecoration(color: TechColors.textMuted.withValues(alpha: .12), borderRadius: BorderRadius.circular(radius)),
    );
    Widget metric(double width) => Container(
      width: width, constraints: const BoxConstraints(minHeight: 86), padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0x221B8AC0), Color(0xB8051727)]), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0x5539BFEF))),
      child: Row(children: [Container(width: 36, height: 36, decoration: BoxDecoration(color: const Color(0x2227C9F4), borderRadius: BorderRadius.circular(10)), child: Center(child: block(width: 18, height: 18, radius: 5))), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [block(width: 48, height: 22), const SizedBox(height: 5), block(width: 98, height: 10)]))]),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xE8113551), Color(0xB8051727)]), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF164F70))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 40, height: 40, decoration: BoxDecoration(color: const Color(0xFF0D3854), borderRadius: BorderRadius.circular(11)), child: Center(child: block(width: 19, height: 19, radius: 5))),
          const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [block(width: 118, height: 10), const SizedBox(height: 9), block(width: 160, height: 25), const SizedBox(height: 7), block(width: 265, height: 12)])),
        ]),
      ),
      const SizedBox(height: 17),
      LayoutBuilder(builder: (context, constraints) {
        final gap = 10.0, columns = constraints.maxWidth < 520 ? 2 : 4;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: gap, children: List.generate(4, (_) => metric(width)));
      }),
      const SizedBox(height: 15),
      Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: const Color(0xB8051727), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF164564).withValues(alpha: .9))),
        child: LayoutBuilder(builder: (context, constraints) {
          final search = block(height: 46), status = block(height: 46);
          return constraints.maxWidth < 620 ? Column(children: [search, const SizedBox(height: 9), status]) : Row(children: [Expanded(flex: 3, child: search), const SizedBox(width: 10), Expanded(flex: 2, child: status)]);
        }),
      ),
      const SizedBox(height: 14),
      Row(children: [block(width: 135, height: 15), const Spacer(), block(width: 62, height: 11)]),
      const SizedBox(height: 10),
      ...List.generate(3, (_) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: const Color(0xA8061B2C), borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFF164564).withValues(alpha: .8))),
          child: LayoutBuilder(builder: (context, constraints) {
            final identity = Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: const Color(0x2227C9F4), borderRadius: BorderRadius.circular(12)), child: Center(child: block(width: 19, height: 19, radius: 5))), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [block(width: 180, height: 13), const SizedBox(height: 7), block(width: 215, height: 10), const SizedBox(height: 7), Row(children: [block(width: 68, height: 19, radius: 20), const SizedBox(width: 7), block(width: 86, height: 19, radius: 20)])]))]);
            final metadata = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [block(width: 95, height: 10), const SizedBox(height: 7), block(width: 150, height: 12), const SizedBox(height: 8), block(width: 110, height: 10)]);
            return constraints.maxWidth < 650 ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [identity, const SizedBox(height: 13), metadata, const SizedBox(height: 10), Align(alignment: Alignment.centerLeft, child: block(width: 150, height: 34, radius: 8))]) : Row(children: [Expanded(flex: 5, child: identity), const SizedBox(width: 14), Expanded(flex: 4, child: metadata), const SizedBox(width: 10), block(width: 150, height: 34, radius: 8)]);
          }),
        ),
      )),
    ]);
  }

  void _showInvitationDetails(Map<String, dynamic> item) {
    final rawStatus = item['status']?.toString() ?? '';
    final expiry = item['expires_at']?.toString() ?? '';
    final expiryDate = DateTime.tryParse(expiry);
    final expiredByDate = rawStatus.trim().toLowerCase() == 'invited' &&
        expiryDate != null && expiryDate.isBefore(DateTime.now());
    final sender = item['sender_name']?.toString().trim() ?? '';
    final senderRole = item['sender_role_id']?.toString().trim() ?? '';
    final recipient = item['recipient_display']?.toString().trim() ?? '';
    final recipientRole = item['recipient_role_id']?.toString().trim() ?? '';
    final branch = item['location_name']?.toString().trim() ?? '';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => _ManagementGlassDialog(
        title: const Text('Invitation details'),
        content: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _profileDetailRow(
            'FROM',
            sender.isEmpty
                ? 'Unknown sender'
                : '$sender${senderRole.isEmpty ? '' : ' · ${_roleLabel(senderRole)}'}',
          ),
          _profileDetailRow(
            'TO',
            recipient.isEmpty ? (item['email']?.toString() ?? '—') : recipient,
          ),
          if (recipientRole.isNotEmpty)
            _profileDetailRow('DESIGNATION', _roleLabel(recipientRole)),
          if (branch.isNotEmpty) _profileDetailRow('BRANCH', branch),
          _profileDetailRow('EMAIL', item['email']?.toString()),
          _profileDetailRow('STATUS', _invitationStatusLabel(rawStatus, expiredByDate: expiredByDate)),
          _profileDetailRow('EXPIRY', _formatInvitationExpiry(expiry)),
          if ((item['invitation_id']?.toString() ?? '').isNotEmpty)
            _profileDetailRow('INVITATION ID', item['invitation_id']?.toString()),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
        ],
      ),
    );
  }
  Widget invitationView() {
    final query=invitationSearch.trim().toLowerCase(), now=DateTime.now();
    final observedStatuses=invitations.map((item)=>item['status']?.toString().trim().toLowerCase()??'').where((v)=>v.isNotEmpty).toSet();
    bool isExpired(Map<String,dynamic> item) {
      final status=item['status']?.toString().trim().toLowerCase()??'', expiry=DateTime.tryParse(item['expires_at']?.toString()??'');
      return status=='expired'||(status=='invited'&&expiry!=null&&expiry.isBefore(now));
    }
    final pending=invitations.where((item){final status=item['status']?.toString().trim().toLowerCase()??'',expiry=DateTime.tryParse(item['expires_at']?.toString()??'');return status=='invited'&&(expiry==null||!expiry.isBefore(now));}).length;
    final accepted=invitations.where((item)=>item['status']?.toString().trim().toLowerCase()=='accepted').length;
    final expired=invitations.where(isExpired).length;
    final revoked=invitations.where((item)=>item['status']?.toString().trim().toLowerCase()=='revoked').length;
    final filtered=invitations.where((item){
      final raw=item['status']?.toString()??'',status=raw.trim().toLowerCase(),person=_invitationPerson(item);
      final role=item['recipient_role_id']?.toString()??item['role_id']?.toString()??'',expiry=DateTime.tryParse(item['expires_at']?.toString()??'');
      final label=_invitationStatusLabel(raw,expiredByDate:status=='invited'&&expiry!=null&&expiry.isBefore(now));
      if(invitationStatus!=null){final matches=invitationStatus=='expired'?isExpired(item):status==invitationStatus;if(!matches)return false;}
      final searchable=[item['email'],item['recipient_display'],person?['full_name'],item['employee_id'],role,_roleLabel(role),item['sender_name'],item['location_name'],label].whereType<Object>().join(' ').toLowerCase();
      return query.isEmpty||searchable.contains(query);
    }).toList();
    final cards=< (String,int,IconData,Color) >[
      ('Total invitations',invitations.length,Icons.mail_outline_rounded,const Color(0xFF00CFFF)),
      ('Pending',pending,Icons.schedule_rounded,const Color(0xFF168BFF)),
      ('Accepted',accepted,Icons.check_circle_outline_rounded,const Color(0xFF00D89A)),
      ('Expired / revoked',expired+revoked,Icons.timer_off_outlined,const Color(0xFFFFB454)),
    ];
    Widget metric(String label,int value,IconData icon,Color accent)=>Container(
      constraints:const BoxConstraints(minHeight:86),padding:const EdgeInsets.all(13),
      decoration:BoxDecoration(gradient:LinearGradient(colors:[accent.withValues(alpha:.13),const Color(0xB8051727)]),borderRadius:BorderRadius.circular(12),border:Border.all(color:accent.withValues(alpha:.48))),
      child:Row(children:[Container(width:36,height:36,alignment:Alignment.center,decoration:BoxDecoration(color:accent.withValues(alpha:.13),borderRadius:BorderRadius.circular(10)),child:Icon(icon,color:accent,size:19)),const SizedBox(width:10),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,mainAxisAlignment:MainAxisAlignment.center,children:[Text(value.toString(),style:const TextStyle(color:Colors.white,fontSize:22,fontWeight:FontWeight.w800)),const SizedBox(height:3),Text(label,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFF9DBDDC),fontSize:10,fontWeight:FontWeight.w600))]))]),
    );
    return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
      LayoutBuilder(builder:(context,c){
        final compact=c.maxWidth<640;
        final heading=Container(padding:const EdgeInsets.all(17),decoration:BoxDecoration(gradient:const LinearGradient(begin:Alignment.topLeft,end:Alignment.bottomRight,colors:[Color(0xE8113551),Color(0xB8051727)]),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFF164F70))),child:Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Container(width:40,height:40,alignment:Alignment.center,decoration:BoxDecoration(color:const Color(0xFF0D3854),borderRadius:BorderRadius.circular(11)),child:const Icon(Icons.mark_email_unread_outlined,color:Color(0xFF43C8F3),size:21)),const SizedBox(width:12),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[_eyebrow('TEAM ONBOARDING'),const SizedBox(height:7),const Text('Invitations',style:TextStyle(color:Color(0xFFE8F4FF),fontSize:25,fontWeight:FontWeight.w800,letterSpacing:-.4)),const SizedBox(height:5),const Text('Track every invitation from send to acceptance, with clear status and expiry details.',style:TextStyle(color:Color(0xFF9DBDDC),fontSize:12,height:1.45))]))]));
        final actions=Wrap(spacing:8,runSpacing:8,children:[
          OutlinedButton.icon(onPressed:loadAll,icon:const Icon(Icons.refresh_rounded,size:16),label:const Text('Refresh'),style:OutlinedButton.styleFrom(foregroundColor:const Color(0xFFD8ECFF),side:const BorderSide(color:Color(0xFF1D6086)))),
          if(_canUi('invitation.manage')||_canUi('invitation.create')||_canUi('people.invite'))FilledButton.icon(onPressed:_inviteEmployee,icon:const Icon(Icons.send_rounded,size:16),label:const Text('Send invitation'),style:FilledButton.styleFrom(backgroundColor:const Color(0xFF00CFE8),foregroundColor:const Color(0xFF001522))),
        ]);
        if(compact)return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[heading,const SizedBox(height:14),Align(alignment:Alignment.centerLeft,child:actions)]);
        return Row(crossAxisAlignment:CrossAxisAlignment.end,children:[Expanded(child:heading),const SizedBox(width:16),actions]);
      }),
      const SizedBox(height:17),
      LayoutBuilder(builder:(context,c){final gap=10.0,columns=c.maxWidth<520?2:4,width=(c.maxWidth-gap*(columns-1))/columns;return Wrap(spacing:gap,runSpacing:gap,children:cards.map((v)=>SizedBox(width:width,child:metric(v.$1,v.$2,v.$3,v.$4))).toList());}),
      const SizedBox(height:15),
      Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:const Color(0xB8051727),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFF164564).withValues(alpha:.9))),child:LayoutBuilder(builder:(context,c){
        final compact=c.maxWidth<620;
        final searchField=TextField(onChanged:(v)=>setState(()=>invitationSearch=v),style:const TextStyle(color:Color(0xFFE5F2FF),fontSize:13),decoration:InputDecoration(hintText:'Search email, person, role, or branch',hintStyle:const TextStyle(color:Color(0xFF7399B8),fontSize:12),prefixIcon:const Icon(Icons.search_rounded,size:19,color:Color(0xFF43C8F3)),suffixIcon:invitationSearch.isEmpty?null:IconButton(tooltip:'Clear search',onPressed:()=>setState(()=>invitationSearch=''),icon:const Icon(Icons.close_rounded,size:18)),filled:true,fillColor:const Color(0xFF061522),isDense:true,border:OutlineInputBorder(borderRadius:BorderRadius.circular(11))));
        final statusFilter=DropdownButtonFormField<String?>(key:ValueKey('invitation-status-$invitationStatus'),initialValue:invitationStatus,isExpanded:true,decoration:input('Invitation status').copyWith(isDense:true),dropdownColor:const Color(0xFF061727),items:[
          const DropdownMenuItem<String?>(value:null,child:Text('All statuses')),const DropdownMenuItem<String?>(value:'invited',child:Text('Pending')),const DropdownMenuItem<String?>(value:'accepted',child:Text('Accepted')),
          if(observedStatuses.contains('expired')||expired>0)const DropdownMenuItem<String?>(value:'expired',child:Text('Expired')),
          if(observedStatuses.contains('revoked'))const DropdownMenuItem<String?>(value:'revoked',child:Text('Revoked')),
        ],onChanged:(v)=>setState(()=>invitationStatus=v));
        return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[
          if(compact)...[searchField,const SizedBox(height:9),statusFilter] else Row(children:[Expanded(flex:3,child:searchField),const SizedBox(width:10),Expanded(flex:2,child:statusFilter)]),
          if(invitationSearch.isNotEmpty||invitationStatus!=null)Align(alignment:Alignment.centerRight,child:TextButton.icon(onPressed: () => setState(() { invitationSearch = ''; invitationStatus = null; }),icon:const Icon(Icons.filter_alt_off_rounded,size:16),label:const Text('Clear search and filters'))),
        ]);
      })),
      const SizedBox(height:14),Row(children:[const Expanded(child:Text('Invitation activity',style:TextStyle(color:Color(0xFFE0F0FF),fontSize:15,fontWeight:FontWeight.w700))),Text('\${filtered.length} shown',style:const TextStyle(color:Color(0xFF8FB9DF),fontSize:11))]),const SizedBox(height:10),
      if(invitations.isEmpty)surface(const Padding(padding:EdgeInsets.symmetric(vertical:32,horizontal:16),child:Column(children:[Icon(Icons.mark_email_unread_outlined,size:32,color:Color(0xFF43C8F3)),SizedBox(height:11),Text('No invitations yet',style:TextStyle(color:Color(0xFFE5F2FF),fontWeight:FontWeight.w700)),SizedBox(height:6),Text('New invitations will appear here with their role, sender, and expiry details.',textAlign:TextAlign.center,style:TextStyle(color:Color(0xFF9DBDDC),fontSize:12,height:1.5))])))
      else if(filtered.isEmpty)surface(Padding(padding:const EdgeInsets.all(28),child:Column(children:[const Icon(Icons.search_off_rounded,size:29,color:Color(0xFF43C8F3)),const SizedBox(height:10),Text(invitationSearch.isNotEmpty?'No invitations match your search':'No invitations match the selected status',style:const TextStyle(color:Color(0xFFE5F2FF),fontWeight:FontWeight.w700)),const SizedBox(height:6),const Text('Try a different search or clear the selected filters.',textAlign:TextAlign.center,style:TextStyle(color:Color(0xFF9DBDDC),fontSize:12),),TextButton.icon(onPressed: () => setState(() { invitationSearch = ''; invitationStatus = null; }),icon:const Icon(Icons.filter_alt_off_rounded,size:16),label:const Text('Clear search and filters'))])))
      else ...filtered.map((item){
        final raw=item['status']?.toString()??'',status=raw.trim().toLowerCase(),expiry=item['expires_at']?.toString()??'',expiryDate=DateTime.tryParse(expiry);
        final expiredByDate=status=='invited'&&expiryDate!=null&&expiryDate.isBefore(now),label=_invitationStatusLabel(raw,expiredByDate:expiredByDate),person=_invitationPerson(item);
        final recipient=item['recipient_display']?.toString().trim().isNotEmpty==true?item['recipient_display']!.toString().trim():(person?['full_name']?.toString().trim()??'');
        final email=item['email']?.toString().trim()??'',role=item['recipient_role_id']?.toString()??item['role_id']?.toString()??'',sender=item['sender_name']?.toString().trim()??'',senderRole=item['sender_role_id']?.toString().trim()??'',branch=item['location_name']?.toString().trim()??'';
        final displayName=recipient.isEmpty?(email.isEmpty?'Invitee details unavailable':email):recipient;
        final stateColor=expiredByDate||status=='expired'||status=='revoked'?const Color(0xFFFF8A8A):status=='accepted'?const Color(0xFF00D89A):const Color(0xFF54C8FF);
        return Padding(padding:const EdgeInsets.only(bottom:9),child:Container(padding:const EdgeInsets.all(14),decoration:BoxDecoration(color:const Color(0xA8061B2C),borderRadius:BorderRadius.circular(14),border:Border.all(color:const Color(0xFF164564).withValues(alpha:.8))),child:LayoutBuilder(builder:(context,c){
          final compact=c.maxWidth<650;
          final identity=Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
            Container(width:42,height:42,alignment:Alignment.center,decoration:BoxDecoration(color:stateColor.withValues(alpha:.14),borderRadius:BorderRadius.circular(12),border:Border.all(color:stateColor.withValues(alpha:.3))),child:Icon(Icons.mail_outline_rounded,color:stateColor,size:20)),
            const SizedBox(width:11),Expanded(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
              Text(displayName,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFFE5F2FF),fontSize:13,fontWeight:FontWeight.w700)),
              const SizedBox(height:4),Text(email.isEmpty?'Email unavailable':email,maxLines:1,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFF9DBDDC),fontSize:11)),
              const SizedBox(height:6),Wrap(spacing:7,runSpacing:6,children:[_invitationStatusChip(label,expiredByDate?'expired':raw),if(role.isNotEmpty)_verificationBadge(_roleLabel(role),true)]),
            ])),
          ]);
          final metadata=Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            if(branch.isNotEmpty)_invitationMeta(Icons.location_on_outlined,'BRANCH',branch),
            if(sender.isNotEmpty)...[const SizedBox(height:7),_invitationMeta(Icons.person_outline_rounded,'SENT BY',sender+(senderRole.isEmpty?'':' · '+_roleLabel(senderRole)))],
            const SizedBox(height:7),_invitationMeta(Icons.schedule_rounded,'EXPIRES',_formatInvitationExpiry(expiry)),
          ]);
          final details=OutlinedButton.icon(onPressed:()=>_showInvitationDetails(item),icon:const Icon(Icons.info_outline_rounded,size:15),label:const Text('View invitation details'),style:OutlinedButton.styleFrom(foregroundColor:const Color(0xFFD8ECFF),side:const BorderSide(color:Color(0xFF1D6086))));
          if(compact)return Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[identity,const SizedBox(height:13),metadata,const SizedBox(height:10),Align(alignment:Alignment.centerLeft,child:details)]);
          return Row(crossAxisAlignment:CrossAxisAlignment.center,children:[Expanded(flex:5,child:identity),const SizedBox(width:14),Expanded(flex:4,child:metadata),const SizedBox(width:10),details]);
        })));
      }),
    ]);
  }

  Widget _invitationMeta(IconData icon,String label,String value)=>Row(crossAxisAlignment:CrossAxisAlignment.start,children:[
    Icon(icon,size:14,color:const Color(0xFF43C8F3)),const SizedBox(width:7),SizedBox(width:62,child:Text(label,style:const TextStyle(color:Color(0xFF6FA3C9),fontSize:9,fontWeight:FontWeight.w700,letterSpacing:.4))),const SizedBox(width:6),Expanded(child:Text(value.isEmpty?'—':value,maxLines:2,overflow:TextOverflow.ellipsis,style:const TextStyle(color:Color(0xFFB8D5EF),fontSize:10))),
  ]);

  String _sectionLabel(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'Management Overview',
    ManagementSection.organization => 'Organization',
    ManagementSection.people => 'People Registry',
    ManagementSection.invitations => 'Invitations',
    ManagementSection.dataAccess => 'Access',
    ManagementSection.audit => 'Audit',
  };

  String _sectionDetail(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'ORGANIZATION OVERVIEW',
    ManagementSection.organization => 'LOCATION → BRANCH HEAD / MANAGER → SECTION → TEAM LEAD → EMPLOYEE',
    ManagementSection.people => 'IDENTITY / ROLE / PLACEMENT',
    ManagementSection.invitations => 'Manage invitations sent to people in your organization and review their current status.',
    ManagementSection.dataAccess => 'DATASET / RESOURCE AUTHORIZATION',
    ManagementSection.audit => 'Review recent organization activity and understand who performed important management actions.',
  };

  IconData _sectionIcon(ManagementSection value) => switch (value) {
    ManagementSection.overview => Icons.dashboard_outlined,
    ManagementSection.organization => Icons.account_tree_outlined,
    ManagementSection.people => Icons.people_outline,
    ManagementSection.invitations => Icons.mail_outline,
    ManagementSection.dataAccess => Icons.lock_outline,
    ManagementSection.audit => Icons.history_rounded,
  };

  Widget body() {
    switch (section) {
      case ManagementSection.overview: return overviewView();
      case ManagementSection.organization: return organizationView();
      case ManagementSection.people: return peopleView();
      case ManagementSection.invitations: return invitationView();
      case ManagementSection.dataAccess: return const ManagedDatasetAccessWorkspace();
      case ManagementSection.audit: return auditView();
    }
  }

  Widget actions() {
    final canManagePeople = _canUi('manager.assign') ||
        _canUi('team_lead.assign') ||
        _canUi('team_lead.request');
    if (!canManagePeople) return const SizedBox.shrink();
    final canManageManagers = _canUi('manager.assign') || _canUi('manager.replace');
    return GlassCard(
      margin: EdgeInsets.zero, padding: const EdgeInsets.all(14),
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _eyebrow('Contextual controls'), const SizedBox(height: 9),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (canManageManagers)
            _actionChip('ASSIGN MANAGER', Icons.manage_accounts, () => assignManager(), accent: true),
          if (canManageManagers)
            _actionChip('REPLACE MANAGER', Icons.swap_horiz, () => assignManager(replace: true)),
          if (_canUi('team_lead.approve'))
            _actionChip('TEAM LEAD REQUESTS', Icons.fact_check, reviewTeamLeadRequests, accent: true),
          if (_canUi('team_lead.assign') || _canUi('team_lead.request'))
            _actionChip(
              _canUi('team_lead.request') ? 'REQUEST TEAM LEAD' : 'ASSIGN TEAM LEAD',
              Icons.supervisor_account,
              assignTeamLead,
            ),
        ]),
      ]),
    );
  }

  Future<void> reviewTeamLeadRequests() async {
    try {
      final response = await request('/assignments/team-lead/requests');
      final requests = maps(response['requests']);
      if (!mounted) return;
      if (requests.isEmpty) { feedback('No Team Lead authorization requests.'); return; }
      for (final item in requests.where((x) => x['status'] == 'pending')) {
        if (!mounted) return;
        final approve = await showDialog<bool>(
          context: context,
          builder: (c) => _ManagementGlassDialog(
            title: Text('Team Lead authorization · ${item['location_name'] ?? 'Branch'}'),
            content: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('REQUESTER  ${item['requester_name'] ?? item['requester_employee_id'] ?? '—'}'),
              const SizedBox(height: 8),
              Text('CANDIDATE  ${item['target_name'] ?? item['target_employee_id'] ?? '—'}'),
              const SizedBox(height: 8),
              Text('SECTION  ${item['section_name'] ?? '—'}'),
              const SizedBox(height: 12),
              const Text('Approving this request creates the Team Lead assignment in this branch.',
                style: TextStyle(color: TechColors.textMuted, height: 1.4)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Reject')),
              FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Approve')),
            ],
          ),
        );
        if (approve == null) continue;
        await request(
          '/assignments/team-lead/requests/${item['request_id']}/decision?approve=$approve',
          method: 'POST',
        );
        feedback(approve ? 'Team Lead request approved.' : 'Team Lead request rejected.');
      }
      await loadAll();
    } catch (e) { feedback(e); }
  }

  String _roleLabel(String value) {
    final normalized = value.trim().toLowerCase();
    switch (normalized) {
      case 'organization_owner':
        return 'Organization Owner';
      case 'branch_head':
        return 'Branch Head';
      case 'team_lead':
        return 'Team Lead';
      case 'manager':
        return 'Manager';
      default:
        return normalized
            .split(RegExp(r'[._-]+'))
            .where((part) => part.isNotEmpty)
            .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
            .join(' ');
    }
  }

  Widget _verificationBadge(String label, bool verified) => Text(
        label.toUpperCase() + (verified ? ' ✓' : ' —'),
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: verified ? TechColors.statusGreen : TechColors.textMuted,
          fontSize: 8,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
        ),
      );

  static String _formatEmployeeTimestamp(dynamic value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '—';

    try {
      final normalized = raw.endsWith('Z') || raw.contains('+') ||
              (raw.length > 10 && raw.substring(10).contains('-'))
          ? raw
          : '${raw}Z';
      final ist = DateTime.parse(normalized)
          .toUtc()
          .add(const Duration(hours: 5, minutes: 30));
      final hour = ist.hour % 12 == 0 ? 12 : ist.hour % 12;
      final period = ist.hour >= 12 ? 'PM' : 'AM';
      final minute = ist.minute.toString().padLeft(2, '0');
      final month = ist.month.toString().padLeft(2, '0');
      final day = ist.day.toString().padLeft(2, '0');
      return '$month/$day/${ist.year}\n$hour:$minute $period';
    } catch (_) {
      return '—';
    }
  }
  void _showAssignmentProfile(Map<String, dynamic> assignment) {
    final assignmentId = assignment['assignment_id']?.toString().trim() ?? '';
    if (assignmentId.isEmpty) {
      feedback(StateError('This assignment has no readable profile target.'));
      return;
    }

    final future =
        request('/assignments/${Uri.encodeComponent(assignmentId)}/profile');
    setState(() {
      _selectedAssignmentProfile = Map<String, dynamic>.from(assignment);
      _assignmentProfileFuture = future;
      _showIdProof = false;
      _isCurrentUserProfile = false;
    });
  }

  Future<Map<String, dynamic>> _loadCurrentUserProfile() async {
    final session = await InsightFlowSupabaseAuthService.ensureSession(
      timeout: const Duration(seconds: 8),
    );
    if (session == null || session.accessToken.isEmpty) {
      throw StateError('Your authenticated session could not be restored. Please retry.');
    }
    final headers = <String, String>{
      'Authorization': 'Bearer ${session.accessToken}',
      if (insightFlowWorkspaceId.isNotEmpty)
        'X-InsightFlow-Workspace-ID': insightFlowWorkspaceId,
    };

    Future<Map<String, dynamic>> getSelf(String path) async {
      final response = await _sendManagementRequest(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz$path'),
        headers,
        method: 'GET',
      );
      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : 'Your profile could not be loaded.',
        );
      }
      if (decoded is! Map) {
        throw StateError('Profile service returned an invalid response.');
      }
      return Map<String, dynamic>.from(decoded);
    }

    final values = await Future.wait([
      getSelf('/me'),
      getSelf('/profile/me'),
    ]);
    final contextData = values[0];
    final profile = values[1];
    final principalId =
        (profile['principal_id'] ?? contextData['principal_id'])?.toString() ?? '';
    final ownAssignments = assignments.where(
      (item) => item['principal_id']?.toString() == principalId,
    ).toList();
    ownAssignments.sort((a, b) {
      final aActive = a['status'] == 'active' ? 0 : 1;
      final bActive = b['status'] == 'active' ? 0 : 1;
      return aActive.compareTo(bActive);
    });
    final assignment = ownAssignments.isEmpty ? <String, dynamic>{} : ownAssignments.first;
    final person = people.where(
      (item) => item['principal_id']?.toString() == principalId,
    ).firstOrNull;
    final roleIds = contextData['role_ids'] is List
        ? (contextData['role_ids'] as List).map((value) => value.toString()).toList()
        : <String>[];
    final role = roleIds.contains('organization_owner')
        ? 'organization_owner'
        : (assignment['role_id'] ??
              person?['role_id'] ??
              (roleIds.isEmpty ? null : roleIds.first));
    final parent = assignments.where(
      (item) => item['assignment_id']?.toString() ==
          assignment['reports_to_assignment_id']?.toString(),
    ).firstOrNull;

    return <String, dynamic>{
      ...profile,
      'principal_id': principalId,
      'employee_id': profile['employee_id'] ?? contextData['employee_id'],
      'email': profile['email'] ?? contextData['email'],
      'role_id': role,
      'organization_name': contextData['organization_name'] ??
          overview['organization']?['name'],
      'location_name': assignment['location_name'],
      'section_name': assignment['section_name'],
      'status': assignment['status'],
      'reports_to_employee_id': assignment['reports_to_employee_id'] ??
          parent?['employee_id'],
      'reports_to_role_id': assignment['reports_to_role_id'] ??
          parent?['role_id'],
      'profile_created_at': profile['created_at'],
      'profile_updated_at': profile['updated_at'],
    };
  }

  Future<void> _confirmSignOut() async {
    final confirmed = await GlassDialog.show<bool>(
      context: context,
      title: 'Sign out?',
      message: 'Are you sure you want to sign out?',
      actions: [
        GlassDialogAction(
          label: 'Cancel',
          onPressed: () => Navigator.pop(context, false),
        ),
        GlassDialogAction(
          label: 'Sign Out',
          isPrimary: true,
          onPressed: () => Navigator.pop(context, true),
        ),
      ],
    );
    if (confirmed == true && mounted) {
      await InsightFlowSupabaseAuthService.signOut();
    }
  }

  void _showCurrentUserProfile() {
    setState(() {
      _selectedAssignmentProfile = <String, dynamic>{
        'full_name': InsightFlowSupabaseAuthService.currentSupabaseUser
                ?.userMetadata?['display_name'] ??
            '',
      };
      _assignmentProfileFuture = _loadCurrentUserProfile();
      _showIdProof = false;
      _isCurrentUserProfile = true;
    });
  }

  void _closeAssignmentProfile() {
    if (!mounted) return;
    setState(() {
      _selectedAssignmentProfile = null;
      _assignmentProfileFuture = null;
      _showIdProof = false;
      _isCurrentUserProfile = false;
    });
  }

  static const double _profileFieldHeight = 72;

  Widget _profileDetailRow(String label, String? value, {bool multiline = false}) {
    final text = (value ?? '').trim();
    final settings = TechColors.panelGlass.copyWith(
      glowIntensity: 0,
      shadowElevation: 0,
      shadow: const <BoxShadow>[],
    );
    return SizedBox(
      height: _profileFieldHeight,
      child: GlassContainer(
        useOwnLayer: true,
        quality: GlassQuality.standard,
        settings: settings,
        shape: const LiquidRoundedSuperellipse(borderRadius: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: TechColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 5),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  text.isEmpty ? '—' : text,
                  maxLines: multiline ? 3 : 2,
                  softWrap: true,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAssignmentProfileOverlay() {
    final future = _assignmentProfileFuture;
    if (_selectedAssignmentProfile == null || future == null) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Material(
        type: MaterialType.transparency,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _closeAssignmentProfile,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.38),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: FutureBuilder<Map<String, dynamic>>(
                  future: future,
                  builder: (context, snapshot) {
                    final dialogHeight =
                        (MediaQuery.sizeOf(context).height - 48)
                            .clamp(220.0, 1000.0)
                            .toDouble();
                    final profile = snapshot.data;
                    final loading = snapshot.connectionState ==
                        ConnectionState.waiting;
                    final profileError = snapshot.hasError
                        ? snapshot.error.toString().replaceFirst('Bad state: ', '')
                        : null;
                    final source = profile ??
                        _selectedAssignmentProfile ??
                        const <String, dynamic>{};
                    final fullName =
                        source['full_name']?.toString().trim() ?? '';
                    final employeeId =
                        source['employee_id']?.toString().trim() ?? '';

                    Widget body() {
                      if (loading) {
                        return const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 36),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: TechColors.borderActive,
                                  ),
                                ),
                                SizedBox(height: 14),
                                Text(
                                  'Loading profile…',
                                  style: TextStyle(
                                    color: TechColors.textPrimary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      if (profileError != null || profile == null) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 30),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.error_outline_rounded,
                                  color: TechColors.statusRed,
                                  size: 24,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  profileError ?? 'Profile data is unavailable.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: TechColors.textPrimary,
                                    fontSize: 12,
                                    height: 1.4,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed: _selectedAssignmentProfile == null
                                      ? null
                                      : (_isCurrentUserProfile
                                          ? _showCurrentUserProfile
                                          : () => _showAssignmentProfile(
                                                _selectedAssignmentProfile!,
                                              )),
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text('Retry profile'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      final proofNumber =
                          profile['id_proof_number']?.toString().trim() ?? '';
                      final proofType =
                          profile['id_proof_type']?.toString().trim() ?? '';
                      final maskedProof = proofNumber.isEmpty
                          ? (profile['id_proof_number_masked']?.toString() ?? '')
                          : proofNumber.length <= 4
                              ? 'X' * proofNumber.length
                              : ('X' * (proofNumber.length - 4)) +
                                  proofNumber.substring(proofNumber.length - 4);
                      final completion = num.tryParse(
                        profile['profile_completeness_percent']?.toString() ?? '',
                      );
                      final reportsToParts = <String>[];
                      final reportsEmployee =
                          profile['reports_to_employee_id']?.toString().trim() ?? '';
                      final reportsRole =
                          profile['reports_to_role_id']?.toString().trim() ?? '';
                      final reportsPerson = people.where((person) =>
                        reportsEmployee.isNotEmpty &&
                        person['employee_id']?.toString() == reportsEmployee,
                      ).firstOrNull;
                      final reportsName =
                          reportsPerson?['full_name']?.toString().trim() ?? '';
                      if (reportsName.isNotEmpty) {
                        reportsToParts.add(reportsName);
                      }
                      if (reportsEmployee.isNotEmpty) {
                        reportsToParts.add(reportsEmployee);
                      }
                      if (reportsRole.isNotEmpty) {
                        reportsToParts.add(_roleLabel(reportsRole));
                      }

                      Widget detail(
                        String label,
                        String? value, {
                        bool multiline = false,
                      }) =>
                          _profileDetailRow(
                            label,
                            value,
                            multiline: multiline,
                          );

                      final details = <Widget>[
                        detail('ROLE', _roleLabel(
                          profile['role_id']?.toString().trim() ?? '—',
                        )),
                        detail('ORGANIZATION', profile['organization_name']?.toString(), multiline: true),
                        detail('PRINCIPAL ID', profile['principal_id']?.toString(), multiline: true),
                        detail('EMAIL', profile['email']?.toString()),
                        detail(
                          'EMAIL VERIFIED',
                          profile['email_verified'] == null
                              ? null
                              : (profile['email_verified'] == true ? 'YES' : 'NO'),
                        ),
                        detail('PHONE', profile['phone_e164']?.toString()),
                        detail(
                          'PHONE VERIFIED',
                          profile['phone_verified'] == null
                              ? null
                              : (profile['phone_verified'] == true ? 'YES' : 'NO'),
                        ),
                        detail(
                          'ADDRESS LINE 1',
                          profile['address_line1']?.toString(),
                          multiline: true,
                        ),
                        detail(
                          'ADDRESS LINE 2',
                          profile['address_line2']?.toString(),
                          multiline: true,
                        ),
                        detail('STATE', profile['state']?.toString()),
                        detail('COUNTRY', profile['country']?.toString()),
                        detail(
                          'PIN / POSTAL CODE',
                          profile['postal_code']?.toString(),
                        ),
                        detail('ID PROOF TYPE', proofType),
                        detail(
                          'ID PROOF NUMBER',
                          !_isCurrentUserProfile && _showIdProof
                              ? proofNumber
                              : maskedProof,
                        ),
                        detail(
                          'BRANCH',
                          profile['location_name']?.toString(),
                        ),
                        detail(
                          'SECTION',
                          profile['section_name']?.toString(),
                        ),
                        detail(
                          'REPORTS TO',
                          reportsToParts.isEmpty
                              ? null
                              : reportsToParts.join(' · '),
                        ),
                        detail(
                          'ASSIGNMENT STATUS',
                          profile['status']?.toString(),
                        ),
                        detail(
                          'CREATED',
                          _formatEmployeeTimestamp(
                            profile['profile_created_at'] ??
                                profile['assignment_created_at'],
                          ),
                          multiline: true,
                        ),
                        detail(
                          'UPDATED',
                          _formatEmployeeTimestamp(
                            profile['profile_updated_at'] ??
                                profile['assignment_updated_at'],
                          ),
                          multiline: true,
                        ),
                      ];

                      final profileCompletion = completion != 100
                          ? detail(
                              'PROFILE COMPLETENESS',
                              completion == null
                                  ? null
                                  : '${completion.toStringAsFixed(0)}%',
                            )
                          : null;

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final twoColumns = constraints.maxWidth >= 560;
                          final gridChildren = <Widget>[...details];
                          if (twoColumns && gridChildren.length.isOdd) {
                            gridChildren.add(const SizedBox.shrink());
                          }

                          if (!twoColumns) {
                            return SingleChildScrollView(
                              padding: const EdgeInsets.only(bottom: 2),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (var i = 0; i < gridChildren.length; i++) ...[
                                    gridChildren[i],
                                    if (i + 1 < gridChildren.length)
                                      const SizedBox(height: 8),
                                  ],
                                ],
                              ),
                            );
                          }

                          return SingleChildScrollView(
                            padding: const EdgeInsets.only(bottom: 2),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                GridView.count(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  crossAxisCount: 2,
                                  crossAxisSpacing: 8,
                                  mainAxisSpacing: 8,
                                  mainAxisExtent: _profileFieldHeight,
                                  children: gridChildren,
                                ),
                                if (profileCompletion != null) ...[
                                  const SizedBox(height: 8),
                                  profileCompletion,
                                ],
                              ],
                            ),
                          );
                        },
                      );
                    }

                    return ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: SizedBox(
                        width: double.infinity,
                        height: dialogHeight,
                        child: InsightFlowDialogSurface(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  Expanded(
                                    child: Text(
                                      fullName.isEmpty
                                          ? 'Profile incomplete'
                                          : fullName,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: TechColors.textPrimary,
                                        fontSize: 19,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Flexible(
                                    child: Text(
                                      employeeId.isEmpty ? '—' : employeeId,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.right,
                                      style: const TextStyle(
                                        color: TechColors.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: TechColors.textMuted.withValues(alpha: 0.22),
                              ),
                              const SizedBox(height: 8),
                              Expanded(child: body()),
                              const SizedBox(height: 8),
                              Align(
                                alignment: Alignment.centerRight,
                                child: GlassButton.custom(
                                  onTap: _closeAssignmentProfile,
                                  height: 42,
                                  shape: const LiquidRoundedSuperellipse(
                                    borderRadius: 14,
                                  ),
                                  glowColor: Colors.transparent,
                                  glowRadius: 0,
                                  child: const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16),
                                    child: Text(
                                      'Close',
                                      style: TextStyle(
                                        color: CupertinoColors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        fontFamily: 'monospace',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _assignmentRegistryValue(
    String value, {
    TextStyle style = const TextStyle(
      color: TechColors.textPrimary,
      fontSize: 11,
      fontWeight: FontWeight.w600,
      fontFamily: 'monospace',
    ),
  }) => Text(
    value,
    style: style,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
  );

  Widget _assignmentRegistryMeta(String label, String value) => Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: [
      SizedBox(
        width: 76,
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            fontFamily: 'monospace',
          ),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: _assignmentRegistryValue(value)),
    ],
  );

  Widget _assignmentRegistryRow(Map<String, dynamic> a) => LayoutBuilder(
    builder: (context, constraints) {
      final compact = constraints.maxWidth < 620;
      final employeeId = a['employee_id']?.toString() ?? '—';
      final fullName = a['full_name']?.toString().trim() ?? '';
      final role = a['role_id']?.toString() ?? '—';
      final location = a['location_name']?.toString() ?? '—';
      final section = a['section_name']?.toString() ?? '—';
      final status = a['status']?.toString() ?? '—';
      final emailVerified = a['email_verified'] == true;
      final phoneVerified = a['phone_verified'] == true;
      final isActive = a['status'] == 'active';
      final reportingAction = SizedBox(
        width: 132,
        child: _actionChip(
          'REPORTING',
          Icons.account_tree_outlined,
          () => reporting(a),
        ),
      );

      final person = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fullName.isEmpty ? 'Profile incomplete' : fullName,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          _assignmentRegistryValue(
            employeeId,
            style: const TextStyle(
              color: TechColors.textMuted,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
        ],
      );

      if (compact) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                const Icon(Icons.link, size: 15, color: TechColors.statusBlue),
                const SizedBox(width: 8),
                Expanded(child: person),
                const SizedBox(width: 10),
                SizedBox(
                  width: 72,
                  child: Text(
                    status,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: TechColors.textMuted,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 9),
            _assignmentRegistryMeta('ROLE', _roleLabel(role)),
            const SizedBox(height: 6),
            _assignmentRegistryMeta('LOCATION', location),
            const SizedBox(height: 6),
            _assignmentRegistryMeta('SECTION', section),
            const SizedBox(height: 7),
            Row(
              children: [
                Expanded(child: _verificationBadge('EMAIL', emailVerified)),
                Expanded(child: _verificationBadge('PHONE', phoneVerified)),
                if (a['id_proof_supplied'] == true)
                  const Expanded(
                    child: Text(
                      'ID PROOF ✓',
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: TechColors.statusGreen,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
              ],
            ),
            if (a['profile_completeness_percent'] != null) ...[
              const SizedBox(height: 5),
              _assignmentRegistryMeta(
                'PROFILE',
                '${a['profile_completeness_percent']}% complete',
              ),
            ],
            if (a['reports_to_employee_id'] != null) ...[
              const SizedBox(height: 5),
              _assignmentRegistryMeta(
                'REPORTS TO',
                a['reports_to_employee_id'].toString(),
              ),
            ],
            if (isActive) ...[
              const SizedBox(height: 10),
              Align(alignment: Alignment.centerRight, child: reportingAction),
            ],
          ],
        );
      }

      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(Icons.link, size: 15, color: TechColors.statusBlue),
          const SizedBox(width: 8),
          SizedBox(width: 150, child: person),
          const SizedBox(width: 10),
          SizedBox(width: 92, child: _assignmentRegistryValue(_roleLabel(role))),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: _assignmentRegistryValue(location, style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 10,
            fontFamily: 'monospace',
          ))),
          const SizedBox(width: 10),
          Expanded(flex: 2, child: _assignmentRegistryValue(section, style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 10,
            fontFamily: 'monospace',
          ))),
          const SizedBox(width: 10),
          SizedBox(
            width: 78,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _verificationBadge('EMAIL', emailVerified),
                const SizedBox(height: 3),
                _verificationBadge('PHONE', phoneVerified),
              ],
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 72,
            child: Text(
              status,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: TechColors.textMuted,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
              ),
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 12),
            reportingAction,
          ],
        ],
      );
    },
  );

  Widget assignmentList() => GlassCard(
    margin: EdgeInsets.zero,
    padding: const EdgeInsets.all(14),
    shape: const LiquidRoundedSuperellipse(borderRadius: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _eyebrow('Assignment registry'),
        const SizedBox(height: 9),
        if (assignments.isEmpty)
          const Text('NO ASSIGNMENTS', style: TextStyle(color: TechColors.textMuted, fontFamily: 'monospace', fontSize: 11)),
        ...assignments.map((a) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Tooltip(
              message: 'View details',
              child: _glassRow(
                child: InkWell(
                  onTap: () => _showAssignmentProfile(a),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: _assignmentRegistryRow(a),
                  ),
                ),
              ),
            ),
          );
        }),
      ],
    ),
  );

  Widget _buildManagementHeader() {
    final actor = overview['actor'];
    final actorName = actor is Map
        ? (actor['full_name'] ?? actor['name'] ?? actor['email'] ?? 'Account').toString()
        : 'Account';
    final email = actor is Map ? (actor['email']?.toString() ?? '') : '';
    return Container(
      height: MediaQuery.sizeOf(context).width < 720 ? 124 : 76,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: const BoxDecoration(
        color: Color(0xF0031222),
        border: Border(bottom: BorderSide(color: Color(0x44215A7A))),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        final brand = Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: [Color(0xFF168BFF), Color(0xFF00DDF5)]),
              boxShadow: const [BoxShadow(color: Color(0x3300BCEB), blurRadius: 12)],
            ),
            child: const Icon(Icons.hub_rounded, color: Colors.white, size: 25),
          ),
          const SizedBox(width: 11),
          const Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
            Text('InsightFlow', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
            Text('Data. Insights. Action.', style: TextStyle(color: Color(0xFF86B4D8), fontSize: 10)),
          ]),
        ]);
        final searchField = SizedBox(
          width: compact ? constraints.maxWidth : constraints.maxWidth * .43,
          height: 42,
          child: TextField(
            textInputAction: TextInputAction.search,
            onSubmitted: (value) {
              setState(() {
                search = value.trim();
                section = ManagementSection.people;
              });
            },
            style: const TextStyle(color: Color(0xFFD9ECFF), fontSize: 12),
            decoration: InputDecoration(
              hintText: 'Search people, datasets, or insights…',
              hintStyle: const TextStyle(color: Color(0xFF8FB3D4), fontSize: 11),
              prefixIcon: const Icon(Icons.search_rounded, color: Color(0xFFBBD8F2), size: 20),
              filled: true, fillColor: const Color(0xB7051A2B),
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF1A5075)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFF168BFF)),
              ),
            ),
          ),
        );
        final account = Row(mainAxisSize: MainAxisSize.min, children: [
          IconButton(
            tooltip: 'Audit activity',
            onPressed: _sectionAllowed(ManagementSection.audit)
                ? () => setState(() => section = ManagementSection.audit)
                : null,
            icon: const Icon(Icons.notifications_none_rounded, color: Color(0xFF24D6F5), size: 23),
          ),
          const SizedBox(width: 6),
          Container(
            width: 38, height: 38, alignment: Alignment.center,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [Color(0xFF1764A5), Color(0xFF00A9D2)]),
            ),
            child: Text(actorName.trim().isEmpty ? 'IF' : actorName.trim().split(RegExp(r'\s+')).take(2).map((part) => part.isEmpty ? '' : part[0]).join().toUpperCase(),
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 9),
          if (!compact) ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 145),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(actorName, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
              Text(email.isEmpty ? _uiRoleLabel() : _uiRoleLabel(),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Color(0xFF9DBDDC), fontSize: 10)),
            ]),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _confirmSignOut,
            icon: const Icon(Icons.logout_rounded, color: Color(0xFFD9ECFF)),
          ),
          IconButton(
            tooltip: 'Profile',
            onPressed: _showCurrentUserProfile,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: Color(0xFFD9ECFF)),
          ),
        ]);
        if (compact) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(children: [
                brand, const Spacer(),
                IconButton(tooltip: 'Sign out', onPressed: _confirmSignOut,
                  icon: const Icon(Icons.logout_rounded, color: Color(0xFFD9ECFF))),
                IconButton(tooltip: 'Profile', onPressed: _showCurrentUserProfile,
                  icon: const Icon(Icons.account_circle_outlined, color: Color(0xFFD9ECFF))),
              ]),
              const SizedBox(height: 5),
              searchField,
            ],
          );
        }
        return Row(children: [
          SizedBox(width: 270, child: brand),
          const SizedBox(width: 20),
          Expanded(child: Align(alignment: Alignment.centerLeft, child: searchField)),
          const Spacer(),
          account,
        ]);
      }),
    );
  }

  Widget _buildManagementNavigation() {
    final tabs = <MapEntry<ManagementSection, String>>[
      const MapEntry(ManagementSection.overview, 'OVERVIEW'),
      const MapEntry(ManagementSection.organization, 'ORGANIZATION'),
      const MapEntry(ManagementSection.people, 'PEOPLE'),
      const MapEntry(ManagementSection.dataAccess, 'ACCESS'),
      const MapEntry(ManagementSection.invitations, 'INVITATIONS'),
      const MapEntry(ManagementSection.audit, 'AUDIT'),
    ].where((tab) => _sectionAllowed(tab.key)).toList();
    // Same geometry and glass settings as DataScreen.NavigationTabs.
    return AdaptiveLiquidGlassLayer(
      settings: kInsightFlowNavigationGlassSettings,
      quality: GlassQuality.minimal,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: SafeArea(
          top: false,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(vertical: 10),
            itemCount: tabs.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              final tab = tabs[index];
              final selected = section == tab.key;
              return GlassChip(
                label: tab.value,
                selected: selected,
                selectedColor: TechColors.borderActive.withValues(alpha: 0.22),
                padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 9),
                labelStyle: TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.45,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? TechColors.textPrimary : TechColors.textMuted,
                ),
                onTap: () => setState(() => section = tab.key),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDashboardSidebar() {
    final nav = <(ManagementSection, String, IconData)>[
      (ManagementSection.overview, 'Dashboard', Icons.home_rounded),
      (ManagementSection.people, 'People & Invitations', Icons.people_alt_outlined),
      (ManagementSection.organization, 'Organization', Icons.account_tree_outlined),
      (ManagementSection.dataAccess, 'Branch Data & Access', Icons.storage_rounded),
      (ManagementSection.invitations, 'Invitations', Icons.mark_email_unread_outlined),
      (ManagementSection.audit, 'Audit Activity', Icons.query_stats_outlined),
    ];
    return Container(
      width: 256,
      decoration: const BoxDecoration(
        color: Color(0xF0031222),
        border: Border(right: BorderSide(color: Color(0x44215A7A))),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: 17),
        Expanded(child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          children: [
            for (final item in nav)
              if (_sectionAllowed(item.$1))
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: () => setState(() => section = item.$1),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 160),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                      decoration: BoxDecoration(
                        color: section == item.$1 ? const Color(0xFF062C43) : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: section == item.$1 ? const Color(0xFF00C9F2) : Colors.transparent,
                        ),
                      ),
                      child: Row(children: [
                        Icon(item.$3, size: 19,
                          color: section == item.$1 ? const Color(0xFF1BD6F6) : const Color(0xFFA3C5E4)),
                        const SizedBox(width: 12),
                        Expanded(child: Text(item.$2, maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: section == item.$1 ? Colors.white : const Color(0xFFD0E5FA),
                            fontWeight: section == item.$1 ? FontWeight.w700 : FontWeight.w500,
                          ))),
                      ]),
                    ),
                  ),
                ),
            const SizedBox(height: 17),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Text(_isOrganizationOwner ? 'ORGANIZATION' : 'MY BRANCH', style: const TextStyle(
                color: Color(0xFF81ACD2), fontSize: 10, fontWeight: FontWeight.w700,
              )),
            ),
            const SizedBox(height: 9),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0x8810273B),
                border: Border.all(color: const Color(0xFF174F73)),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(children: [
                const Icon(Icons.hub_outlined, color: Color(0xFF1BD6F6), size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(_uiScopeLabel(), maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFFD9ECFF), fontSize: 11))),
              ]),
            ),
          ],
        )),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 10, 13, 15),
          child: Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: const Color(0xAA071B2B),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF15714F)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Icon(Icons.workspace_premium_rounded, color: Color(0xFF00D89A), size: 21),
                const SizedBox(width: 8),
                Expanded(child: Text(_uiRoleLabel(), style: const TextStyle(
                  color: Color(0xFFE0F2FF), fontSize: 12, fontWeight: FontWeight.w700,
                ))),
              ]),
              const SizedBox(height: 8),
              Text('Manage your authorized team, organization structure, and data access.',
                style: const TextStyle(color: Color(0xFF9DBDDC), fontSize: 10, height: 1.4)),
            ]),
          ),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 13),
          child: Text('InsightFlow v1.0.0', style: TextStyle(color: Color(0xFF5D92BE), fontSize: 10)),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFF020D18),
    body: LiquidGlassScope(
      child: Stack(children: [
        Positioned.fill(child: GlassBackgroundSource(child: const TechAnimatedBackground())),
        Positioned.fill(child: SafeArea(child: LayoutBuilder(builder: (context, viewport) {
          final desktop = viewport.maxWidth >= 1000;
          final header = _buildManagementHeader();
          final content = Column(children: [
            if (!desktop) _buildManagementNavigation(),
            Expanded(child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(desktop ? 24 : 15, desktop ? 16 : 12, desktop ? 24 : 15, 26),
              child: Center(child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1500),
                child: loading
                  ? (section == ManagementSection.invitations ? _invitationSkeleton()
                    : section == ManagementSection.audit ? _auditSkeleton() : _overviewSkeleton())
                  : error != null
                    ? Container(
                        padding: const EdgeInsets.all(18),
                        decoration: BoxDecoration(
                          color: const Color(0xE8061727),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFF0C456B)),
                        ),
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.error_outline_rounded, color: Color(0xFFFFB65E), size: 24),
                          const SizedBox(height: 9),
                          const Text('Management service unavailable', style: TextStyle(
                            color: Colors.white, fontWeight: FontWeight.w700,
                          )),
                          const SizedBox(height: 6),
                          Text(error!, textAlign: TextAlign.center,
                            style: const TextStyle(color: Color(0xFFB6D3EC), height: 1.4)),
                          const SizedBox(height: 14),
                          _actionChip('RETRY', Icons.refresh_rounded, loadAll, accent: true),
                        ]),
                      )
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (section != ManagementSection.overview && section != ManagementSection.dataAccess) ...[
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: const Color(0xB8051727),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFF0B4164)),
                            ),
                            child: _title(_sectionLabel(section), detail: _sectionDetail(section), icon: _sectionIcon(section)),
                          ),
                          const SizedBox(height: 14),
                        ],
                        body(),
                        if (section == ManagementSection.organization) ...[
                          const SizedBox(height: 16), actions(), const SizedBox(height: 16), assignmentList(),
                        ],
                      ]),
              )),
            )),
          ]);
          if (!desktop) {
            return Column(children: [header, Expanded(child: content)]);
          }
          return Column(children: [
            header,
            Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _buildDashboardSidebar(),
              Expanded(child: content),
            ])),
          ]);
        }))),
        if (_selectedAssignmentProfile != null) _buildAssignmentProfileOverlay(),
      ]),
    ),
  );
}

