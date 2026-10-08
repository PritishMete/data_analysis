import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../tech_background.dart';
import '../../widgets/shared/dock_glass_material.dart';
import '../../widgets/insightflow_floating_brand.dart';
import 'management_navigation.dart';
import '../dashboard/navigation_tabs.dart' show kInsightFlowNavigationGlassSettings;
import 'authorization_management_screen.dart';
import 'managed_dataset_access_workspace.dart';

enum ManagementSection { overview, organization, people, invitations, dataAccess, companySettings, audit }

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
          case 'companySettings':
            sections.add(ManagementSection.companySettings);
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
          ManagementSection.companySettings,
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

  String _roleWorkspaceTitle() =>
      _uiRoleLabel().toUpperCase() + ' / MANAGEMENT';

  String _roleWorkspaceSubtitle() =>
      _uiScopeLabel() + ' management workspace';

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

  Future<Map<String, dynamic>> _companySettings(String locationId) async =>
      request('/company-settings?location_id=' + Uri.encodeQueryComponent(locationId));

  Future<void> _saveCompanySettings(String locationId, Map<String, dynamic> values) async {
    await request(
      '/company-settings?location_id=' + Uri.encodeQueryComponent(locationId),
      method: 'PUT',
      body: values,
    );
  }

  Future<Map<String, dynamic>> _emailSettings(String locationId) async {
    return request('/email-settings?location_id=' + Uri.encodeQueryComponent(locationId));
  }

  Future<void> _connectBranchGmail(String locationId) async {
    final response = await request(
      '/email-settings/connect?location_id=' + Uri.encodeQueryComponent(locationId),
      method: 'POST',
    );
    final url = response['authorization_url']?.toString() ?? '';
    if (url.isEmpty || !await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication)) {
      throw StateError('Google Gmail authorization could not be opened.');
    }
    feedback(StateError('Gmail authorization opened in a new browser tab. Complete it, then return to InsightFlow.'));
  }

  Future<void> _saveBranchSenderName(String locationId, String senderName) async {
    await request(
      '/email-settings?location_id=' + Uri.encodeQueryComponent(locationId),
      method: 'PUT',
      body: {'sender_name': senderName},
    );
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
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: locationId,
              decoration: input('Branch / Location'),
              items: locations.map((value) => DropdownMenuItem<String>(value: value['location_id'].toString(), child: Text(value['name'].toString()))).toList(),
              onChanged: (value) { if (value != null) setDialogState(() => locationId = value); },
            ),
            FutureBuilder<Map<String, dynamic>>(
              future: _emailSettings(locationId),
              builder: (context, snapshot) {
                final data = snapshot.data ?? const <String, dynamic>{};
                final connected = data['connected'] == true;
                final senderIdentity = data['sender_identity']?.toString() ?? 'Not configured';
                final sendingAccount = data['sender_email']?.toString() ?? 'Not connected';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'EMAIL SENDER',
                      style: TextStyle(
                        color: TechColors.textMuted,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sender identity: $senderIdentity',
                      style: const TextStyle(
                        color: TechColors.textPrimary,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Sending account: $sendingAccount',
                      style: const TextStyle(
                        color: TechColors.textMuted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      connected
                          ? 'Status: Connected'
                          : 'Status: Not connected',
                      style: TextStyle(
                        color: connected
                            ? TechColors.statusGreen
                            : TechColors.statusRed,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Configure this from Company Settings → Email & Invitations.',
                      style: TextStyle(
                        color: TechColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                    if (!connected) ...[
                      const SizedBox(height: 8),
                      GlassButton.custom(
                        onTap: () async {
                          try {
                            await _connectBranchGmail(locationId);
                            setDialogState(() {});
                          } catch (e) {
                            feedback(e);
                          }
                        },
                        height: 40,
                        shape: const LiquidRoundedSuperellipse(borderRadius: 12),
                        child: const Text(
                          'Configure Email',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
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
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: CupertinoColors.black.withValues(alpha: 0.24),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: SizedBox(
        height: 56,
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
                height: 56,
                width: double.infinity,
                shape: const LiquidRoundedSuperellipse(borderRadius: 28),
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

  String _overviewOrganizationName() {
    final org = overview['organization'];
    if (org is Map && org['name'] != null) {
      final name = org['name'].toString().trim();
      if (name.isNotEmpty) return name;
    }
    return 'Your organization';
  }

  int _overviewCount(dynamic summaryValue, int fallback) {
    if (summaryValue is num) return summaryValue.toInt();
    final parsed = int.tryParse(summaryValue?.toString() ?? '');
    return parsed ?? fallback;
  }

  List<Map<String, dynamic>> _unassignedPeople() {
    final assignedPrincipalIds = assignments
        .where((a) => a['status'] == 'active')
        .map((a) => a['principal_id']?.toString())
        .whereType<String>()
        .toSet();
    return people.where((p) {
      final principalId = p['principal_id']?.toString();
      return principalId == null ||
          principalId.isEmpty ||
          !assignedPrincipalIds.contains(principalId);
    }).toList();
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

  Widget _overviewSummaryCard(
    String label,
    String value,
    String detail,
    IconData icon,
  ) {
    return GlassCard(
      margin: EdgeInsets.zero,
      padding: const EdgeInsets.all(16),
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: TechColors.borderActive.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: TechColors.borderActive.withValues(alpha: 0.18),
              ),
            ),
            child: Icon(icon, size: 19, color: TechColors.borderActive),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(value, style: const TextStyle(color: TechColors.textPrimary, fontSize: 22, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.35)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _overviewQuickAction(
    String label,
    String detail,
    IconData icon,
    ManagementSection destination,
  ) {
    return GlassCard(
      margin: EdgeInsets.zero,
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() => section = destination),
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Row(
            children: [
              Icon(icon, size: 20, color: TechColors.borderActive),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.35)),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(Icons.arrow_forward_ios_rounded, size: 12, color: TechColors.textMuted),
            ],
          ),
        ),
      ),
    );
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
    Widget block(double height, {double? width}) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: TechColors.panelBg.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: TechColors.textMuted.withValues(alpha: 0.10)),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        block(126),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 620 ? 2 : 4;
            final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: List.generate(4, (_) => block(118, width: width)),
            );
          },
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 820 ? 1 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: List.generate(4, (_) => block(88, width: width)),
            );
          },
        ),
      ],
    );
  }

  Widget overviewView() {
    final org = Map<String, dynamic>.from(overview['organization'] ?? const {});
    final sum = Map<String, dynamic>.from(overview['summary'] ?? const {});
    final locationCount = _overviewCount(sum['location_count'], locations.length);
    final sectionCount = _overviewCount(sum['section_count'], sections.length);
    final peopleCount = _overviewCount(sum['people_count'], people.length);
    final activeAssignments = assignments.where((a) => a['status'] == 'active').length;
    final unassignedPeople = _unassignedPeople();
    final attentionItems = <Widget>[];

    if (unassignedPeople.isNotEmpty) {
      attentionItems.add(
        _glassRow(
          child: Row(
            children: [
              const Icon(Icons.person_off_outlined, size: 18, color: TechColors.statusAmber),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('People without an active assignment', style: TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(
                      '${unassignedPeople.length} people may need a location or section assignment.',
                      style: const TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.35),
                    ),
                  ],
                ),
              ),
              TextButton(onPressed: () => setState(() => section = ManagementSection.people), child: const Text('Review')),
            ],
          ),
        ),
      );
    }

    if (attentionItems.isEmpty) {
      attentionItems.add(
        _glassRow(
          child: const Row(
            children: [
              Icon(Icons.check_circle_outline, size: 18, color: TechColors.statusGreen),
              SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("You're all caught up", style: TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
                    SizedBox(height: 3),
                    Text('There are no outstanding management actions right now.', style: TextStyle(color: TechColors.textMuted, fontSize: 10)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    final recentActivity = audit.take(5).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassContainer(
          useOwnLayer: true,
          quality: GlassQuality.minimal,
          settings: TechColors.sectionGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 18),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 18),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final organizationStatus = org['status']?.toString().trim();
              final subtitle = organizationStatus == null || organizationStatus.isEmpty
                  ? 'Manage your organization, people, access and activity from one place.'
                  : 'Manage your organization, people, access and activity from one place. Status: $organizationStatus.';
              final content = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _eyebrow('Organization overview'),
                  const SizedBox(height: 7),
                  Text(_overviewOrganizationName(), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textPrimary, fontSize: 24, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 7),
                  Text(subtitle, style: const TextStyle(color: TechColors.textMuted, fontSize: 12, height: 1.45)),
                ],
              );
              if (compact) return content;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: content),
                  const SizedBox(width: 20),
                  _statusDot(organizationStatus ?? 'active'),
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 14),
        _eyebrow('Organization summary'),
        const SizedBox(height: 9),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 620 ? 2 : 4;
            final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
            return Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                SizedBox(width: width, child: _overviewSummaryCard('People', peopleCount.toString(), 'People across your organization', Icons.people_outline)),
                SizedBox(width: width, child: _overviewSummaryCard('Locations', locationCount.toString(), 'Branches and locations', Icons.location_on_outlined)),
                SizedBox(width: width, child: _overviewSummaryCard('Sections', sectionCount.toString(), 'Sections across your locations', Icons.account_tree_outlined)),
                SizedBox(width: width, child: _overviewSummaryCard('Active assignments', activeAssignments.toString(), 'Current role and reporting assignments', Icons.assignment_ind_outlined)),
              ],
            );
          },
        ),
        const SizedBox(height: 18),
        _eyebrow('Quick actions'),
        const SizedBox(height: 9),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 820 ? 1 : 2;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            final actions = [
              ('Add person', 'Review and manage people', Icons.person_add_alt_1_outlined, ManagementSection.people),
              ('Manage organization', 'Locations, sections and leadership', Icons.account_tree_outlined, ManagementSection.organization),
              ('Review invitations', 'See invitation activity', Icons.mail_outline, ManagementSection.invitations),
              ('Manage access', 'Review access and assignments', Icons.admin_panel_settings_outlined, ManagementSection.dataAccess),
              ('View audit', 'Review recent management activity', Icons.history_rounded, ManagementSection.audit),
            ];
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: actions.map((action) => SizedBox(
                width: width,
                child: _overviewQuickAction(action.$1, action.$2, action.$3, action.$4),
              )).toList(),
            );
          },
        ),
        const SizedBox(height: 18),
        _eyebrow('Management attention'),
        const SizedBox(height: 9),
        Column(
          children: attentionItems.map((item) => Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: item,
          )).toList(),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 900;
            final activity = GlassCard(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(15),
              shape: const LiquidRoundedSuperellipse(borderRadius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: _title('Recent activity', detail: 'Recent management events', icon: Icons.history_rounded)),
                      TextButton(onPressed: () => setState(() => section = ManagementSection.audit), child: const Text('View audit')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (recentActivity.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('No recent activity is available.', style: TextStyle(color: TechColors.textMuted, fontSize: 11)),
                    )
                  else
                    ...recentActivity.map(_overviewActivityItem),
                ],
              ),
            );
            final structure = GlassCard(
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(15),
              shape: const LiquidRoundedSuperellipse(borderRadius: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _title('Organization structure', detail: 'A quick view of how your organization is arranged', icon: Icons.account_tree_outlined),
                  const SizedBox(height: 14),
                  _overviewStructureStep('Organization', _overviewOrganizationName(), Icons.business_outlined),
                  _overviewStructureConnector(),
                  _overviewStructureStep('Branches / Locations', '$locationCount locations', Icons.location_on_outlined),
                  _overviewStructureConnector(),
                  _overviewStructureStep('Sections', '$sectionCount sections', Icons.account_tree_outlined),
                  _overviewStructureConnector(),
                  _overviewStructureStep('People', '$peopleCount people', Icons.people_outline),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => setState(() => section = ManagementSection.organization),
                      icon: const Icon(Icons.arrow_forward_rounded, size: 15),
                      label: const Text('View organization'),
                    ),
                  ),
                ],
              ),
            );
            return wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Expanded(child: activity), const SizedBox(width: 12), Expanded(child: structure)],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [activity, const SizedBox(height: 12), structure],
                  );
          },
        ),
      ],
    );
  }

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
        LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final controls = Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (_canUi('organization.structure.manage'))
                  _actionChip(
                    'CREATE LOCATION',
                    Icons.add_location_alt_outlined,
                    createLocation,
                  ),
                if (_canUi('organization.structure.manage') ||
                    _canUi('organization.section.create'))
                  _actionChip(
                    'CREATE SECTION',
                    Icons.account_tree_outlined,
                    createSection,
                    accent: true,
                  ),
              ],
            );
            return compact
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _eyebrow('Organization structure'),
                      const SizedBox(height: 8),
                      controls,
                    ],
                  )
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _eyebrow('Organization structure')),
                      controls,
                    ],
                  );
          },
        ),
        const SizedBox(height: 12),
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
    final roleOptions = people.map((p) => p['role_id']?.toString() ?? '')
        .where((v) => v.isNotEmpty).toSet().toList()..sort();
    final locationOptions = people.map((p) => p['location_name']?.toString() ?? '')
        .where((v) => v.isNotEmpty && v.toLowerCase() != 'unassigned').toSet().toList()..sort();
    final sectionOptions = people.map((p) => p['section_name']?.toString() ?? '')
        .where((v) => v.isNotEmpty && v.toLowerCase() != 'unassigned').toSet().toList()..sort();
    final summary = overview['summary'] is Map
        ? Map<String, dynamic>.from(overview['summary'] as Map)
        : const <String, dynamic>{};
    final roleCounts = summary['role_counts'] is Map
        ? Map<String, dynamic>.from(summary['role_counts'] as Map)
        : const <String, dynamic>{};
    int backendCount(String key, int fallback) {
      final value = roleCounts[key] ?? summary['${key}_count'];
      return int.tryParse(value?.toString() ?? '') ?? fallback;
    }
    final totalPeople = int.tryParse(summary['total_people']?.toString() ?? '') ?? people.length;
    final branchHeadCount = backendCount('branch_head', people.where((p) => p['role_id'] == 'branch_head').length);
    final managerCount = backendCount('manager', people.where((p) => p['role_id'] == 'manager').length);
    final teamLeadCount = backendCount('team_lead', people.where((p) => p['role_id'] == 'team_lead').length);
    const professionalRoles = <String>{'data_analyst','senior_data_analyst','business_analyst','data_scientist','data_engineer','ml_engineer','analytics_engineer','bi_developer','data_architect','data_quality_analyst','data_governance_analyst'};
    final professionalMemberCount = people.where((p) => professionalRoles.contains(p['role_id']?.toString())).length;
    final activeCount = people.where((p) => (p['status']?.toString().toLowerCase() ?? '') == 'active').length;
    final assignedCount = people.where((p) {
      final loc = p['location_name']?.toString() ?? '';
      final sec = p['section_name']?.toString() ?? '';
      return loc.isNotEmpty && loc.toLowerCase() != 'unassigned' &&
          sec.isNotEmpty && sec.toLowerCase() != 'unassigned';
    }).length;
    final filtered = people.where((p) {
      final fields = [p['full_name'], p['email'], p['employee_id'], p['role_id'],
        p['location_name'], p['section_name'], p['status']]
        .whereType<Object>().map((v) => v.toString().toLowerCase().trim());
      if (query.isNotEmpty && !fields.any((v) => v.contains(query))) return false;
      if (selectedLocation != null && p['location_name']?.toString() != selectedLocation) return false;
      if (selectedSection != null && p['section_name']?.toString() != selectedSection) return false;
      if (selectedRole != null && p['role_id']?.toString() != selectedRole) return false;
      return true;
    }).toList();
    final hasFilters = search.trim().isNotEmpty || selectedLocation != null || selectedSection != null || selectedRole != null;
    Widget metric(String label, int value, IconData icon) => Expanded(
      child: _glassRow(padding: const EdgeInsets.all(13), child: Row(children: [
        Icon(icon, size: 17, color: TechColors.borderActive),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('$value', style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
          Text(label, style: const TextStyle(fontSize: 10, color: TechColors.textMuted)),
        ])),
      ])),
    );
    Widget personCard(Map<String, dynamic> p, {bool compact = false}) {
      final name = p['full_name']?.toString().trim() ?? '';
      final employeeId = p['employee_id']?.toString().trim() ?? '';
      final role = _roleLabel(p['role_id']?.toString() ?? '—');
      final location = p['location_name']?.toString() ?? 'Unassigned';
      final subsection = p['section_name']?.toString() ?? 'Unassigned';
      final status = p['status']?.toString() ?? 'Unknown';
      final assignmentId = p['assignment_id']?.toString() ?? '';
      final target = assignments.where((a) =>
        assignmentId.isNotEmpty &&
        a['assignment_id']?.toString() == assignmentId).firstOrNull ??
        assignments.where((a) =>
          employeeId.isNotEmpty &&
          a['employee_id']?.toString() == employeeId).firstOrNull ??
        (assignmentId.isNotEmpty ? p : null);
      return _glassRow(padding: const EdgeInsets.all(14), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(width: 38, height: 38, alignment: Alignment.center,
              decoration: BoxDecoration(color: TechColors.borderActive.withValues(alpha: .14), borderRadius: BorderRadius.circular(12)),
              child: const Icon(Icons.person_outline, color: TechColors.borderActive, size: 19)),
            const SizedBox(width: 11),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name.isEmpty ? 'Profile incomplete' : name, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              if (p['email']?.toString().isNotEmpty ?? false) ...[
                const SizedBox(height: 3),
                Text(p['email'].toString(), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: TechColors.textMuted)),
              ],
              if (employeeId.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(employeeId, style: const TextStyle(fontSize: 10, color: TechColors.textMuted, fontFamily: 'monospace')),
              ],
            ])),
            const SizedBox(width: 8),
            _statusDot(status),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 7, runSpacing: 7, children: [
            _verificationBadge(role, true),
            _verificationBadge(status, status.toLowerCase() == 'active'),
          ]),
          const SizedBox(height: 9),
          Row(children: [
            const Icon(Icons.location_on_outlined, size: 14, color: TechColors.textMuted),
            const SizedBox(width: 5),
            Expanded(child: Text(location, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: TechColors.textMuted))),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Icon(Icons.account_tree_outlined, size: 14, color: TechColors.textMuted),
            const SizedBox(width: 5),
            Expanded(child: Text(subsection, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: TechColors.textMuted))),
          ]),
          if (target != null) ...[
            const SizedBox(height: 10),
            Align(alignment: Alignment.centerRight, child: TextButton.icon(
              onPressed: () => _showAssignmentProfile(target),
              icon: const Icon(Icons.person_search_outlined, size: 16),
              label: const Text('View profile'),
            )),
          ],
        ],
      ));
    }
    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 680;
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _title('People', detail: 'View and manage the people in your organization', icon: Icons.people_outline),
        const SizedBox(height: 12),
        if (people.isNotEmpty) ...[
          if (narrow) ...[
            metric('Total people', totalPeople, Icons.people_outline),
            const SizedBox(height: 7),
            metric('Branch Heads', branchHeadCount, Icons.badge_outlined),
            const SizedBox(height: 7),
            metric('Managers', managerCount, Icons.manage_accounts_outlined),
            const SizedBox(height: 7),
            metric('Team Leads', teamLeadCount, Icons.supervisor_account_outlined),
            const SizedBox(height: 7),
            metric('Professional members', professionalMemberCount, Icons.person_outline),
            const SizedBox(height: 7),
            metric('Active members', activeCount, Icons.verified_user_outlined),
            const SizedBox(height: 7),
            metric('Assigned', assignedCount, Icons.account_tree_outlined),
          ] else Wrap(
            spacing: 9,
            runSpacing: 9,
            children: [
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Total people', totalPeople, Icons.people_outline)),
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Branch Heads', branchHeadCount, Icons.badge_outlined)),
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Managers', managerCount, Icons.manage_accounts_outlined)),
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Team Leads', teamLeadCount, Icons.supervisor_account_outlined)),
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Professional members', professionalMemberCount, Icons.person_outline)),
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Active members', activeCount, Icons.verified_user_outlined)),
              SizedBox(width: (constraints.maxWidth - 36) / 5, child: metric('Assigned', assignedCount, Icons.account_tree_outlined)),
            ],
          ),
          const SizedBox(height: 12),
        ],
        GlassCard(margin: EdgeInsets.zero, padding: const EdgeInsets.all(12),
          shape: const LiquidRoundedSuperellipse(borderRadius: 16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            TextField(
              onChanged: (v) => setState(() => search = v),
              style: const TextStyle(color: TechColors.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search people',
                prefixIcon: const Icon(Icons.search, size: 19),
                suffixIcon: search.isEmpty ? null : IconButton(
                  tooltip: 'Clear search', icon: const Icon(Icons.close, size: 18),
                  onPressed: () => setState(() => search = ''),
                ),
                isDense: true, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 9),
            if (narrow) ...[
              DropdownButtonFormField<String>(
                initialValue: selectedLocation, isExpanded: true, decoration: const InputDecoration(labelText: 'Location', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('All locations')),
                  ...locationOptions.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() => selectedLocation = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: selectedSection, isExpanded: true, decoration: const InputDecoration(labelText: 'Section', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('All sections')),
                  ...sectionOptions.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() => selectedSection = v),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                initialValue: selectedRole, isExpanded: true, decoration: const InputDecoration(labelText: 'Role', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('All roles')),
                  ...roleOptions.map((v) => DropdownMenuItem(value: v, child: Text(_roleLabel(v), overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() => selectedRole = v),
              ),
            ] else Row(children: [
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: selectedLocation, isExpanded: true, decoration: const InputDecoration(labelText: 'Location', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('All locations')),
                  ...locationOptions.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() => selectedLocation = v),
              )),
              const SizedBox(width: 10),
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: selectedSection, isExpanded: true, decoration: const InputDecoration(labelText: 'Section', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('All sections')),
                  ...sectionOptions.map((v) => DropdownMenuItem(value: v, child: Text(v, overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() => selectedSection = v),
              )),
              const SizedBox(width: 10),
              Expanded(child: DropdownButtonFormField<String>(
                initialValue: selectedRole, isExpanded: true, decoration: const InputDecoration(labelText: 'Role', isDense: true),
                items: [const DropdownMenuItem(value: null, child: Text('All roles')),
                  ...roleOptions.map((v) => DropdownMenuItem(value: v, child: Text(_roleLabel(v), overflow: TextOverflow.ellipsis)))],
                onChanged: (v) => setState(() => selectedRole = v),
              )),
              if (hasFilters) IconButton(tooltip: 'Clear filters', onPressed: () => setState(() {
                search = ''; selectedLocation = null; selectedSection = null; selectedRole = null;
              }), icon: const Icon(Icons.filter_alt_off)),
            ]),
            if (narrow && hasFilters) Align(alignment: Alignment.centerRight, child: TextButton(
              onPressed: () => setState(() { search = ''; selectedLocation = null; selectedSection = null; }),
              child: const Text('Clear filters'),
            )),
          ]),
        ),
        const SizedBox(height: 12),
        if (people.isEmpty)
          surface(const Padding(padding: EdgeInsets.all(28), child: Column(children: [
            Icon(Icons.people_outline, size: 30, color: TechColors.textMuted),
            SizedBox(height: 9),
            Text('No people yet', style: TextStyle(fontWeight: FontWeight.w700)),
            SizedBox(height: 5),
            Text('People added to your organization will appear here.', textAlign: TextAlign.center,
              style: TextStyle(color: TechColors.textMuted, fontSize: 12)),
          ])))
        else if (filtered.isEmpty)
          surface(Padding(padding: const EdgeInsets.all(28), child: Column(children: [
            const Icon(Icons.search_off, size: 28, color: TechColors.textMuted),
            const SizedBox(height: 9),
            Text(query.isNotEmpty ? 'No people match your search' : 'No people match these filters',
              style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 5),
            const Text('Try changing your search or clearing the selected filters.',
              textAlign: TextAlign.center, style: TextStyle(color: TechColors.textMuted, fontSize: 12)),
            TextButton(onPressed: () => setState(() { search = ''; selectedLocation = null; selectedSection = null; }),
              child: const Text('Clear search and filters')),
          ])))
        else if (narrow)
          Column(children: filtered.map((p) => Padding(
            padding: const EdgeInsets.only(bottom: 8), child: personCard(p, compact: true),
          )).toList())
        else
          GlassCard(margin: EdgeInsets.zero, padding: const EdgeInsets.all(10),
            shape: const LiquidRoundedSuperellipse(borderRadius: 16),
            child: Column(children: [
              Padding(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Row(children: const [
                  Expanded(flex: 3, child: Text('PERSON', style: TextStyle(fontSize: 10, color: TechColors.textMuted))),
                  Expanded(flex: 2, child: Text('ROLE', style: TextStyle(fontSize: 10, color: TechColors.textMuted))),
                  Expanded(flex: 2, child: Text('LOCATION / SECTION', style: TextStyle(fontSize: 10, color: TechColors.textMuted))),
                  SizedBox(width: 78, child: Text('STATUS', style: TextStyle(fontSize: 10, color: TechColors.textMuted))),
                ]),
              ),
              const Divider(height: 1),
              ...filtered.map((p) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: personCard(p),
              )),
            ]),
          ),
      ]);
    });
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
      _title('Audit',detail:'Review recent organization activity and understand who performed important management actions.',icon:Icons.history_rounded),const SizedBox(height:12),
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
    Widget block({double height = 16, double? width}) => Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        color: TechColors.textMuted.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        block(width: 150, height: 22),
        const SizedBox(height: 9),
        block(width: 290, height: 12),
      ])),
      const SizedBox(height: 12),
      surface(block(height: 46)),
      const SizedBox(height: 12),
      ...List.generate(4, (_) => Padding(
        padding: const EdgeInsets.only(bottom: 9),
        child: surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          block(width: 190, height: 17),
          const SizedBox(height: 10),
          block(width: 130, height: 12),
          const SizedBox(height: 8),
          block(width: 220, height: 11),
        ])),
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
    Widget block({double height = 18, double width = double.infinity}) => Container(
      height: height, width: width,
      decoration: BoxDecoration(
        color: TechColors.textMuted.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
      ),
    );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 8, children: List.generate(4, (_) => SizedBox(
        width: 180,
        child: surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          block(width: 62, height: 10), const SizedBox(height: 10), block(width: 42, height: 20),
        ])),
      ))),
      const SizedBox(height: 12),
      surface(Row(children: [
        Expanded(child: block(height: 46)), const SizedBox(width: 10),
        SizedBox(width: 180, child: block(height: 46)),
      ])),
      const SizedBox(height: 12),
      ...List.generate(3, (_) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: surface(Row(children: [
          Expanded(flex: 3, child: block(width: 220)), const SizedBox(width: 18),
          Expanded(flex: 2, child: block(width: 100)), const SizedBox(width: 18),
          Expanded(flex: 2, child: block(width: 120)),
        ])),
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
    final query = invitationSearch.trim().toLowerCase();
    final now = DateTime.now();
    final observedStatuses = invitations.map((item) => item['status']?.toString().trim().toLowerCase() ?? '')
        .where((value) => value.isNotEmpty).toSet();

    final pending = invitations.where((item) {
      final status = item['status']?.toString().trim().toLowerCase() ?? '';
      if (status != 'invited') return false;
      final expiry = DateTime.tryParse(item['expires_at']?.toString() ?? '');
      return expiry == null || !expiry.isBefore(now);
    }).length;
    final accepted = invitations.where((item) => item['status']?.toString().trim().toLowerCase() == 'accepted').length;
    final expired = invitations.where((item) {
      final status = item['status']?.toString().trim().toLowerCase() ?? '';
      if (status == 'expired') return true;
      if (status != 'invited') return false;
      final expiry = DateTime.tryParse(item['expires_at']?.toString() ?? '');
      return expiry != null && expiry.isBefore(now);
    }).length;
    final revoked = invitations.where((item) => item['status']?.toString().trim().toLowerCase() == 'revoked').length;

    final filtered = invitations.where((item) {
      final rawStatus = item['status']?.toString() ?? '';
      final status = rawStatus.trim().toLowerCase();
      if (invitationStatus != null && status != invitationStatus) return false;
      final person = _invitationPerson(item);
      final roleId = item['role_id']?.toString() ?? '';
      final expiry = DateTime.tryParse(item['expires_at']?.toString() ?? '');
      final expiredByDate = status == 'invited' && expiry != null && expiry.isBefore(now);
      final searchable = [
        item['email'], person?['full_name'], item['employee_id'], roleId,
        _roleLabel(roleId), _invitationStatusLabel(rawStatus, expiredByDate: expiredByDate),
      ].whereType<Object>().join(' ').toLowerCase();
      return query.isEmpty || searchable.contains(query);
    }).toList();

    final cards = <(String, int, IconData)>[
      ('Total', invitations.length, Icons.mail_outline),
      if (observedStatuses.contains('invited')) ('Pending', pending, Icons.schedule_outlined),
      if (observedStatuses.contains('accepted')) ('Accepted', accepted, Icons.check_circle_outline),
      if (observedStatuses.contains('expired') || expired > 0) ('Expired', expired, Icons.timer_off_outlined),
      if (observedStatuses.contains('revoked')) ('Revoked', revoked, Icons.block_outlined),
    ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_canUi('invitation.manage'))
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _inviteEmployee,
            icon: const Icon(Icons.person_add_alt_1_outlined, size: 17),
            label: const Text('Invite employee'),
          ),
        ),
      const SizedBox(height: 10),
      LayoutBuilder(builder: (context, constraints) {
        final count = constraints.maxWidth >= 900 ? cards.length.clamp(1, 5)
            : constraints.maxWidth >= 560 ? 3 : 2;
        final itemWidth = (constraints.maxWidth - (count - 1) * 8) / count;
        return Wrap(spacing: 8, runSpacing: 8, children: cards.map((metric) => SizedBox(
          width: itemWidth,
          child: surface(Row(children: [
            Icon(metric.$3, size: 16, color: TechColors.textMuted), const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(metric.$1, style: const TextStyle(color: TechColors.textMuted, fontSize: 10)),
              Text(metric.$2.toString(), style: const TextStyle(color: TechColors.textPrimary, fontSize: 19, fontWeight: FontWeight.w700)),
            ])),
          ])),
        )).toList());
      }),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) => Wrap(
        spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(width: constraints.maxWidth >= 520 ? 320 : constraints.maxWidth, child: TextField(
            onChanged: (value) => setState(() => invitationSearch = value),
            decoration: input('Search invitations').copyWith(
              prefixIcon: const Icon(Icons.search),
              suffixIcon: invitationSearch.isEmpty ? null : IconButton(
                tooltip: 'Clear search',
                onPressed: () => setState(() => invitationSearch = ''),
                icon: const Icon(Icons.close),
              ),
            ),
          )),
          SizedBox(width: constraints.maxWidth >= 520 ? 190 : constraints.maxWidth,
            child: DropdownButtonFormField<String?>(
              initialValue: invitationStatus, decoration: input('Status'),
              dropdownColor: TechColors.panelBg,
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('All statuses')),
                ...invitations.map((item) => item['status']?.toString().trim() ?? '')
                  .where((value) => value.isNotEmpty).toSet()
                  .map((value) => DropdownMenuItem<String>(
                    value: value.toLowerCase(), child: Text(_invitationStatusLabel(value)),
                  )),
              ],
              onChanged: (value) => setState(() => invitationStatus = value),
            )),
          if (invitationSearch.isNotEmpty || invitationStatus != null)
            TextButton.icon(
              onPressed: () => setState(() { invitationSearch = ''; invitationStatus = null; }),
              icon: const Icon(Icons.refresh, size: 16), label: const Text('Clear filters'),
            ),
        ],
      )),
      const SizedBox(height: 12),
      if (invitations.isEmpty)
        surface(const Padding(
          padding: EdgeInsets.symmetric(vertical: 28, horizontal: 16),
          child: Column(children: [
            Icon(Icons.mail_outline, size: 30, color: TechColors.textMuted),
            SizedBox(height: 10),
            Text('No invitations', textAlign: TextAlign.center,
              style: TextStyle(color: TechColors.textPrimary, fontWeight: FontWeight.w700)),
            SizedBox(height: 6),
            Text('There are currently no invitations available to display.',
              textAlign: TextAlign.center, style: TextStyle(color: TechColors.textMuted, height: 1.4)),
          ]),
        ))
      else if (filtered.isEmpty)
        surface(Padding(
          padding: const EdgeInsets.all(22),
          child: Column(children: [
            const Icon(Icons.search_off, color: TechColors.textMuted), const SizedBox(height: 8),
            Text(invitationSearch.isNotEmpty ? 'No invitations match your search'
                : 'No invitations match the selected status',
              textAlign: TextAlign.center,
              style: const TextStyle(color: TechColors.textPrimary, fontWeight: FontWeight.w600)),
            if (invitationSearch.isNotEmpty || invitationStatus != null) ...[
              const SizedBox(height: 10),
              TextButton(onPressed: () => setState(() { invitationSearch = ''; invitationStatus = null; }),
                child: const Text('Clear search and filters')),
            ],
          ]),
        ))
      else
        ...filtered.map((item) {
          final rawStatus = item['status']?.toString() ?? '';
          final status = rawStatus.trim().toLowerCase();
          final expiry = item['expires_at']?.toString() ?? '';
          final expiryDate = DateTime.tryParse(expiry);
          final expiredByDate = status == 'invited' && expiryDate != null && expiryDate.isBefore(now);
          final label = _invitationStatusLabel(rawStatus, expiredByDate: expiredByDate);
          final person = _invitationPerson(item);
          final fullName = item['recipient_display']?.toString().trim().isNotEmpty == true
              ? item['recipient_display']!.toString().trim()
              : (person?['full_name']?.toString().trim() ?? '');
          final role = item['recipient_role_id']?.toString() ?? item['role_id']?.toString() ?? '';
          final senderName = item['sender_name']?.toString().trim() ?? '';
          final senderRole = item['sender_role_id']?.toString().trim() ?? '';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: surface(LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxWidth < 620;
              final narrow = constraints.maxWidth < 480;
              final identity = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(fullName.isEmpty ? (item['email']?.toString() ?? 'Invitee email unavailable') : fullName,
                  maxLines: narrow ? 2 : 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: TechColors.textPrimary, fontWeight: FontWeight.w700)),
                const SizedBox(height: 3),
                Text('TO · ${item['email']?.toString() ?? 'Email unavailable'}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: TechColors.textMuted, fontSize: 10)),
                if (senderName.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    'FROM · $senderName${senderRole.isEmpty ? '' : ' · ${_roleLabel(senderRole)}'}',
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: TechColors.textMuted, fontSize: 10),
                  ),
                ],
              ]);
              if (compact) {
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  identity, const SizedBox(height: 10),
                  Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    _invitationStatusChip(label, rawStatus),
                    Text(role.isEmpty ? 'Role unavailable' : _roleLabel(role),
                      style: const TextStyle(color: TechColors.textMuted, fontSize: 11, fontFamily: 'monospace')),
                    Text('Expires ${_formatInvitationExpiry(expiry)}',
                      style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
                    Tooltip(message: 'View invitation details', child: TextButton.icon(onPressed: () => _showInvitationDetails(item),
                      icon: const Icon(Icons.info_outline, size: 15), label: const Text('Details'))),
                  ]),
                ]);
              }
              final details = Row(mainAxisSize: MainAxisSize.min, children: [
                _invitationStatusChip(label, rawStatus), const SizedBox(width: 10),
                Flexible(child: Text(role.isEmpty ? 'Role unavailable' : _roleLabel(role), maxLines: 1,
                  overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, fontFamily: 'monospace'))),
                const SizedBox(width: 10),
                Flexible(child: Text('Expires ${_formatInvitationExpiry(expiry)}', maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: TechColors.textMuted, fontSize: 11))),
                const SizedBox(width: 4),
                TextButton.icon(onPressed: () => _showInvitationDetails(item),
                  icon: const Icon(Icons.info_outline, size: 15), label: const Text('Details')),
              ]);
              return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(flex: 3, child: identity), const SizedBox(width: 18),
                Expanded(flex: 4, child: details),
              ]);
            })),
          );
        }),
    ]);
  }

  String _sectionLabel(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'Management Overview',
    ManagementSection.organization => 'Organization',
    ManagementSection.people => 'People Registry',
    ManagementSection.invitations => 'Invitations',
    ManagementSection.dataAccess => 'Access',
    ManagementSection.companySettings => 'Company Settings',
    ManagementSection.audit => 'Audit',
  };

  String _sectionDetail(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'ORGANIZATION OVERVIEW',
    ManagementSection.organization => 'LOCATION → BRANCH HEAD / MANAGER → SECTION → TEAM LEAD → EMPLOYEE',
    ManagementSection.people => 'IDENTITY / ROLE / PLACEMENT',
    ManagementSection.invitations => 'Manage invitations sent to people in your organization and review their current status.',
    ManagementSection.dataAccess => 'DATASET / RESOURCE AUTHORIZATION',
    ManagementSection.companySettings => 'COMPANY / BRANCH / EMAIL IDENTITY',
    ManagementSection.audit => 'Review recent organization activity and understand who performed important management actions.',
  };

  IconData _sectionIcon(ManagementSection value) => switch (value) {
    ManagementSection.overview => Icons.dashboard_outlined,
    ManagementSection.organization => Icons.account_tree_outlined,
    ManagementSection.people => Icons.people_outline,
    ManagementSection.invitations => Icons.mail_outline,
    ManagementSection.dataAccess => Icons.lock_outline,
    ManagementSection.companySettings => Icons.settings_outlined,
    ManagementSection.audit => Icons.history_rounded,
  };

  Widget body() {
    switch (section) {
      case ManagementSection.overview: return overviewView();
      case ManagementSection.organization: return organizationView();
      case ManagementSection.people: return peopleView();
      case ManagementSection.invitations: return invitationView();
      case ManagementSection.dataAccess: return const ManagedDatasetAccessWorkspace();
      case ManagementSection.companySettings: return companySettingsView();
      case ManagementSection.audit: return auditView();
    }
  }

  Widget companySettingsView() {
    if (!_canUi('organization.structure.manage')) {
      return surface(const Text('Company Settings are available only to the organization owner or Branch Head.', style: TextStyle(color: TechColors.textMuted, height: 1.4)));
    }
    if (locations.isEmpty) return surface(const Text('Create an active branch before configuring Company Settings.', style: TextStyle(color: TechColors.textMuted)));
    final locationId = selectedLocation ?? locations.first['location_id'].toString();
    return FutureBuilder<Map<String, dynamic>>(
      future: _companySettings(locationId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return surface(const Center(child: CupertinoActivityIndicator()));
        final data = snapshot.data!;
        final companyName = TextEditingController(text: data['company_name']?.toString() ?? '');
        final companyId = TextEditingController(text: data['company_identifier']?.toString() ?? '');
        final companyEmail = TextEditingController(text: data['company_email']?.toString() ?? '');
        final companyDomain = TextEditingController(text: data['company_domain']?.toString() ?? '');
        final emailDomain = TextEditingController(text: data['email_domain']?.toString() ?? '');
        final branchName = TextEditingController(text: data['branch_name']?.toString() ?? '');
        final branchId = TextEditingController(text: data['branch_identifier']?.toString() ?? '');
        final branchEmail = TextEditingController(text: data['branch_email']?.toString() ?? '');
        return surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('EMAIL & INVITATIONS', style: TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          const Text('The generated InsightFlow identity is separate from the authenticated Gmail transport account.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
          const SizedBox(height: 14),
          TextField(controller: companyName, decoration: input('Company name')),
          const SizedBox(height: 10), TextField(controller: companyId, decoration: input('Company identifier')),
          const SizedBox(height: 10), TextField(controller: companyEmail, decoration: input('Company email')),
          const SizedBox(height: 10), TextField(controller: companyDomain, decoration: input('Company domain')),
          const SizedBox(height: 10), TextField(controller: emailDomain, decoration: input('Email domain')),
          const SizedBox(height: 10), TextField(controller: branchName, decoration: input('Branch name')),
          const SizedBox(height: 10), TextField(controller: branchId, decoration: input('Branch identifier')),
          const SizedBox(height: 10), TextField(controller: branchEmail, decoration: input('Branch email')),
          const SizedBox(height: 16), _eyebrow('GENERATED INSIGHTFLOW IDENTITY'), const SizedBox(height: 5),
          Text(data['sender_identity']?.toString() ?? '—', style: const TextStyle(color: TechColors.borderActive, fontSize: 14, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
          const SizedBox(height: 12),
          Text('Sending account: ' + (data['gmail_connected'] == true ? (data['connected_gmail']?.toString() ?? 'Connected Gmail') : 'Not connected'), style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
          const SizedBox(height: 5),
          Text(data['sender_identity_mode'] == 'display_only' ? 'Transport mode: authenticated Gmail account. The generated identity is display-only until a legitimate verified Gmail Send-As alias exists.' : 'Transport mode: ' + (data['sender_identity_mode']?.toString() ?? 'unknown'), style: const TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.35)),
          const SizedBox(height: 14),
          Wrap(spacing: 8, runSpacing: 8, children: [
            GlassButton.custom(onTap: () async { try { await _saveCompanySettings(locationId, {'company_name': companyName.text.trim(), 'company_identifier': companyId.text.trim(), 'company_email': companyEmail.text.trim(), 'company_domain': companyDomain.text.trim(), 'email_domain': emailDomain.text.trim(), 'branch_name': branchName.text.trim(), 'branch_identifier': branchId.text.trim(), 'branch_email': branchEmail.text.trim()}); if (mounted) feedback('Company settings saved.'); } catch (e) { feedback(e); } }, height: 40, shape: const LiquidRoundedSuperellipse(borderRadius: 12), child: const Text('Save settings', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
            GlassButton.custom(onTap: () async { try { await _connectBranchGmail(locationId); } catch (e) { feedback(e); } }, height: 40, shape: const LiquidRoundedSuperellipse(borderRadius: 12), child: Text(data['gmail_connected'] == true ? 'Reconnect Gmail' : 'Configure Email', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
        ]));
      },
    );
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
          '/assignments/team-lead/requests/${item['request_id']}/decision?approve=${approve}',
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
    if (confirmed == true) {
      await InsightFlowSupabaseAuthService.signOut();
    }
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
    // Mirrors DataScreen._buildGlassAppBar(): management is another
    // InsightFlow workspace, not a separate admin theme.
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: GlassContainer(
        useOwnLayer: true,
        quality: GlassQuality.standard,
        settings: kInsightFlowFloatingBrandGlassSettings,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final identity = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome_rounded, color: TechColors.borderActive, size: 18),
                const SizedBox(width: 10),
                const Text('InsightFlow', style: TextStyle(
                  color: TechColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                )),
              ],
            );
            final workspace = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _eyebrow(_roleWorkspaceTitle()),
                const SizedBox(height: 3),
                Text(_roleWorkspaceSubtitle(), style: const TextStyle(
                  color: TechColors.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                )),
              ],
            );
            final controls = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Profile',
                  onPressed: _showCurrentUserProfile,
                  icon: const Icon(Icons.person_outline_rounded, size: 18, color: TechColors.textPrimary),
                ),
                IconButton(
                  tooltip: 'Refresh management data',
                  onPressed: loadAll,
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: TechColors.textPrimary),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: _confirmSignOut,
                  icon: const Icon(Icons.logout, size: 18, color: TechColors.textPrimary),
                ),
              ],
            );
            if (compact) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [identity, const Spacer(), controls]),
                  const SizedBox(height: 7),
                  workspace,
                ],
              );
            }
            return Row(children: [
              identity,
              const Spacer(),
              workspace,
              const SizedBox(width: 14),
              controls,
            ]);
          },
        ),
      ),
    );
  }

  Widget _buildManagementNavigation() {
    final tabs = <MapEntry<ManagementSection, String>>[
      const MapEntry(ManagementSection.overview, 'OVERVIEW'),
      const MapEntry(ManagementSection.organization, 'ORGANIZATION'),
      const MapEntry(ManagementSection.people, 'PEOPLE'),
      const MapEntry(ManagementSection.dataAccess, 'ACCESS'),
      const MapEntry(ManagementSection.companySettings, 'COMPANY SETTINGS'),
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
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                labelStyle: TextStyle(
                  fontSize: 13,
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

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    extendBodyBehindAppBar: true,
    body: LiquidGlassScope(
      child: Stack(
        children: [
          Positioned.fill(child: GlassBackgroundSource(child: const TechAnimatedBackground())),
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  _buildManagementHeader(),
                  _buildManagementNavigation(),
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 1500),
                          child: loading
                              ? (section == ManagementSection.invitations
                                  ? _invitationSkeleton()
                                  : section == ManagementSection.audit
                                      ? _auditSkeleton()
                                      : _overviewSkeleton())
                              : error != null
                                  ? GlassCard(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.error_outline_rounded, color: TechColors.statusRed, size: 22),
                                          const SizedBox(height: 8),
                                          _eyebrow('MANAGEMENT SERVICE ERROR'),
                                          const SizedBox(height: 6),
                                          Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: TechColors.textPrimary, height: 1.4)),
                                          const SizedBox(height: 14),
                                          _actionChip('RETRY', Icons.refresh_rounded, loadAll, accent: true),
                                        ],
                                      ),
                                    )
                                  : Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        if (section != ManagementSection.dataAccess) ...[
                                          surface(_title(
                                            _sectionLabel(section),
                                            detail: _sectionDetail(section),
                                            icon: _sectionIcon(section),
                                          )),
                                          const SizedBox(height: 12),
                                        ],
                                        body(),
                                        if (section == ManagementSection.organization) ...[
                                          const SizedBox(height: 16),
                                          actions(),
                                          const SizedBox(height: 16),
                                          assignmentList(),
                                        ],
                                      ],
                                    ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_selectedAssignmentProfile != null) _buildAssignmentProfileOverlay(),
        ],
      ),
    ),
  );
}