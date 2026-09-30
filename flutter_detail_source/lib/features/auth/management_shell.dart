import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../tech_background.dart';
import '../../widgets/shared/dock_glass_material.dart';
import 'management_navigation.dart';
import 'authorization_management_screen.dart';

enum ManagementSection { overview, organization, people, locations, sections, invitations, dataAccess, audit }

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
      backgroundColor: Colors.transparent,
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: actions
                      .map(
                        (action) => Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: action,
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// Exact glass navigation preset used by DataScreen's NavigationTabs.
const _kManagementNavigationGlassSettings = LiquidGlassSettings(
  thickness: 20,
  blur: 20,
  glassColor: Color(0x26FFFFFF),
  lightAngle: 0.75 * math.pi,
  lightIntensity: 0.7,
  ambientStrength: 0.5,
  saturation: 1.2,
  refractiveIndex: 1.2,
  chromaticAberration: 0.0,
);

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
  int pendingInvitations = 0;
  String search = '';
  String? selectedLocation;

  @override
  void initState() { super.initState(); loadAll(); }

  List<Map<String, dynamic>> maps(dynamic v) => v is List
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : <Map<String, dynamic>>[];

  static const _managementRequestTimeout = Duration(seconds: 45);

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
    } on TimeoutException {
      // Render's free instance can be asleep after the site has been closed
      // overnight. The first request may spend ~20-25s waking the service.
      // Retry once with a fresh authenticated session instead of surfacing
      // the old 15-second timeout to a user whose account is still valid.
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 8),
      );
      if (session == null || session.accessToken.isEmpty) rethrow;
      final refreshedHeaders = await supabaseAuthHeaders();
      if (insightFlowWorkspaceId.isNotEmpty) {
        refreshedHeaders['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
      }
      if (body != null) refreshedHeaders['Content-Type'] = 'application/json';
      return await sendWithHeaders(
        send: () => method == 'POST'
            ? http.post(uri, headers: refreshedHeaders, body: jsonEncode(body))
            : http.get(uri, headers: refreshedHeaders),
      );
    }
  }

  Future<http.Response> sendWithHeaders({
    required Future<http.Response> Function() send,
  }) {
    return send().timeout(_managementRequestTimeout);
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
    final headers = await supabaseAuthHeaders();
    if (insightFlowWorkspaceId.isNotEmpty) {
      headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
    }
    if (body != null) headers['Content-Type'] = 'application/json';
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

  Future<void> loadAll() async {
    setState(() { loading = true; error = null; });
    try {
      final r = await Future.wait([
        request('/overview'), request('/locations'), request('/sections'),
        request('/people'), request('/assignments'), request('/audit?limit=100'),
      ]);
      if (!mounted) return;
      setState(() {
        overview = r[0];
        locations = maps(r[1]['locations']);
        sections = maps(r[2]['sections']);
        people = maps(r[3]['people']);
        assignments = maps(r[4]['assignments']);
        audit = maps(r[5]['audit']);
        pendingInvitations = 0;
        loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { loading = false; error = e.toString().replaceFirst('Bad state: ', ''); });
    }
  }

  InputDecoration input(String label) => InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(color: TechColors.textMuted),
    filled: true,
    fillColor: Colors.white.withValues(alpha: 0.04),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  );

  Widget surface(Widget child) => GlassCard(
    margin: EdgeInsets.zero,
    padding: const EdgeInsets.all(16),
    settings: dockGlassSettings(
      glassColor: TechColors.panelBg.withValues(alpha: 0.30),
    ),
    quality: GlassQuality.minimal,
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
    if (locations.isEmpty || sections.isEmpty || active.isEmpty) { feedback(StateError('An active location, section, and person are required.')); return; }
    var location = selectedLocation ?? locations.first['location_id'].toString();
    var sectionId = sections.first['section_id'].toString();
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
      await request('/assignments/team-lead', method: 'POST',
        body: {'location_id': location, 'section_id': sectionId, 'principal_id': principal});
      feedback('Team Lead assigned.');
      await loadAll();
    } catch (e) { feedback(e); }
  }

  int level(dynamic role) => {'employee': 10, 'team_lead': 30, 'manager': 40, 'branch_head': 50, 'organization_owner': 50}[role?.toString()] ?? 0;

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
    style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5, fontFamily: 'monospace'),
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
          Text(detail, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, fontFamily: 'monospace')),
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
    EdgeInsetsGeometry padding = const EdgeInsets.symmetric(
      horizontal: 14,
      vertical: 11,
    ),
  }) =>
      GlassContainer(
        useOwnLayer: true,
        quality: GlassQuality.minimal,
        settings: TechColors.sectionGlass,
        shape: const LiquidRoundedSuperellipse(borderRadius: 14),
        padding: padding,
        child: child,
      );

  Widget _actionChip(String label, IconData icon, VoidCallback? onPressed, {bool accent = false}) => GlassButton.custom(
    onTap: onPressed ?? () {},
    enabled: onPressed != null,
    height: 38,
    width: 150,
    shape: const LiquidRoundedSuperellipse(borderRadius: 12),
    useOwnLayer: true,
    quality: GlassQuality.minimal,
    settings: TechColors.sectionGlass,
    glowColor: accent ? TechColors.borderActive.withValues(alpha: 0.28) : Colors.transparent,
    glowRadius: accent ? 10 : 0,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 15, color: accent ? TechColors.borderActive : TechColors.textMuted),
        const SizedBox(width: 7),
        Text(label, style: TextStyle(color: accent ? TechColors.textPrimary : TechColors.textMuted, fontSize: 11, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
      ]),
    ),
  );

  Widget metric(String label, dynamic value, {IconData? icon}) =>
      GlassContainer(
        useOwnLayer: true,
        quality: GlassQuality.minimal,
        settings: TechColors.sectionGlass,
        shape: const LiquidRoundedSuperellipse(borderRadius: 14),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 14, color: TechColors.borderActive),
              const SizedBox(width: 9),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _eyebrow(label),
                  const SizedBox(height: 4),
                  Text(
                    (value ?? 0).toString(),
                    style: const TextStyle(
                      color: TechColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      fontFamily: 'monospace',
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
  Widget overviewView() {
    final org = Map<String, dynamic>.from(overview['organization'] ?? const {});
    final sum = Map<String, dynamic>.from(overview['summary'] ?? const {});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GlassCard(
        margin: EdgeInsets.zero, padding: const EdgeInsets.all(18),
        settings: TechColors.panelGlass, quality: GlassQuality.standard,
        shape: const LiquidRoundedSuperellipse(borderRadius: 18),
        child: Row(children: [
          Container(width: 42, height: 42, decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: TechColors.borderActive.withValues(alpha: 0.10),
            border: Border.all(color: TechColors.borderActive.withValues(alpha: 0.45)),
          ), child: const Icon(Icons.business_outlined, color: TechColors.borderActive, size: 20)),
          const SizedBox(width: 13),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _eyebrow('Organization control'),
            const SizedBox(height: 4),
            Text(org['name']?.toString() ?? 'Organization', style: const TextStyle(color: TechColors.textPrimary, fontSize: 19, fontWeight: FontWeight.w700)),
            const SizedBox(height: 3),
            Text('${org['status'] ?? '—'}  ·  workspace ${insightFlowWorkspaceId.isEmpty ? '—' : insightFlowWorkspaceId}', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
          ])),
          _statusDot(org['status']?.toString() ?? ''),
        ]),
      ),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, c) {
        final width = c.maxWidth < 680 ? (c.maxWidth - 10) / 2 : (c.maxWidth - 30) / 4;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          SizedBox(width: width, child: metric('Locations', sum['location_count'], icon: Icons.location_on_outlined)),
          SizedBox(width: width, child: metric('Managers', sum['manager_count'], icon: Icons.manage_accounts_outlined)),
          SizedBox(width: width, child: metric('Team leads', sum['team_lead_count'], icon: Icons.supervisor_account_outlined)),
          SizedBox(width: width, child: metric('Employees', sum['employee_count'], icon: Icons.people_outline)),
          SizedBox(width: width, child: metric('Pending invites', pendingInvitations, icon: Icons.mail_outline)),
        ]);
      }),
    ]);
  }

  Widget organizationView() {
    if (locations.isEmpty) return surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _eyebrow('Organization topology'), const SizedBox(height: 8),
      const Text('No organizational structure is configured yet.', style: TextStyle(color: TechColors.textMuted)),
    ]));
    return Column(children: locations.map((l) {
      final id = l['location_id'].toString();
      final secs = sections.where((s) => s['location_id'].toString() == id).toList();
      final asg = assignments.where((a) => a['location_id'].toString() == id && a['status'] == 'active').toList();
      final managers = asg.where((a) => a['role_id'] == 'manager').toList();
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(
        margin: EdgeInsets.zero, padding: const EdgeInsets.all(14),
        settings: TechColors.sectionGlass, quality: GlassQuality.standard,
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.location_on_outlined, size: 17, color: TechColors.borderActive),
            const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700)),
              Text(l['branch_identifier'].toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
            ])),
            _statusDot(l['status']?.toString() ?? 'active'),
          ]),
          const SizedBox(height: 10),
          _glassRow(child: Row(children: [
            const Icon(Icons.manage_accounts_outlined, size: 15, color: TechColors.textMuted),
            const SizedBox(width: 8),
            const Text('MANAGER', style: TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
            const Spacer(),
            Text(managers.isEmpty ? 'UNASSIGNED' : managers.first['employee_id'].toString(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
          ])),
          if (secs.isNotEmpty) ...[
            const SizedBox(height: 10), _eyebrow('Sections'), const SizedBox(height: 7),
            ...secs.map((s) {
              final members = asg.where((a) => a['section_id']?.toString() == s['section_id']?.toString() && (a['role_id'] == 'team_lead' || a['role_id'] == 'employee')).toList();
              return Padding(padding: const EdgeInsets.only(bottom: 6), child: _glassRow(child: Row(children: [
                const Icon(Icons.account_tree_outlined, size: 14, color: TechColors.statusBlue),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s['name'].toString(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                  Text('${s['employee_count'] ?? 0} members', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
                ])),
                if (members.isNotEmpty) Text('${members.length}', style: const TextStyle(color: TechColors.textMuted, fontFamily: 'monospace', fontSize: 10)),
              ])));
            }),
          ],
        ]),
      ));
    }).toList());
  }

  Widget peopleView() {
    final q = search.trim().toLowerCase();
    final list = people.where((p) => q.isEmpty || [p['employee_id'], p['role_id'], p['location_name'], p['section_name'], p['status']].any((v) => v?.toString().toLowerCase().contains(q) ?? false)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GlassCard(
        margin: EdgeInsets.zero, padding: const EdgeInsets.all(14),
        settings: TechColors.sectionGlass, quality: GlassQuality.minimal,
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: Row(children: [
          const Icon(Icons.search, size: 16, color: TechColors.textMuted), const SizedBox(width: 8),
          Expanded(child: TextField(
            onChanged: (v) => setState(() => search = v),
            style: const TextStyle(color: TechColors.textPrimary, fontSize: 12, fontFamily: 'monospace'),
            decoration: const InputDecoration(
              hintText: 'SEARCH PEOPLE / ROLE / LOCATION / SECTION',
              hintStyle: TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace'),
              border: InputBorder.none, isDense: true,
            ),
          )),
        ]),
      ),
      const SizedBox(height: 10),
      if (list.isEmpty) surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('NO PEOPLE MATCH THIS QUERY', style: TextStyle(color: TechColors.textMuted, fontFamily: 'monospace', fontSize: 11)))))
      else Column(children: list.map((p) => Padding(padding: const EdgeInsets.only(bottom: 7), child: _glassRow(child: Row(children: [
        const Icon(Icons.person_outline, size: 17, color: TechColors.borderActive), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(p['employee_id']?.toString() ?? 'Person', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          const SizedBox(height: 3),
          Text('${p['role_id'] ?? '—'}  ·  ${p['location_name'] ?? 'Unassigned'}  ·  ${p['section_name'] ?? 'Unassigned'}', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
        ])),
        _statusDot(p['status']?.toString() ?? ''), const SizedBox(width: 7),
        Text(p['status']?.toString() ?? '—', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
      ])))).toList()),
    ]);
  }

  Widget locationsView() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [
      Expanded(child: _title('Locations', detail: 'BRANCH REGISTRY', icon: Icons.location_on_outlined)),
      _actionChip('CREATE', Icons.add, createLocation, accent: true),
    ]),
    const SizedBox(height: 12),
    if (locations.isEmpty) surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('NO LOCATIONS YET', style: TextStyle(color: TechColors.textMuted, fontFamily: 'monospace', fontSize: 11)))))
    else ...locations.map((l) => Padding(padding: const EdgeInsets.only(bottom: 8), child: _glassRow(child: InkWell(
      onTap: () => setState(() => selectedLocation = l['location_id'].toString()),
      borderRadius: BorderRadius.circular(12),
      child: Row(children: [
        const Icon(Icons.location_on_outlined, size: 17, color: TechColors.borderActive), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          const SizedBox(height: 3),
          Text('${l['branch_identifier']}  ·  ${l['section_count'] ?? 0} sections  ·  ${l['employee_count'] ?? 0} employees', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
        ])),
        Text(l['manager']?['employee_id']?.toString() ?? 'NO MANAGER', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
      ]),
    )))),
  ]);

  Widget sectionsView() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [
      Expanded(child: _title('Sections', detail: 'LOCATION → SECTION HIERARCHY', icon: Icons.account_tree_outlined)),
      _actionChip('CREATE', Icons.add, createSection, accent: true),
    ]),
    const SizedBox(height: 12),
    if (sections.isEmpty) surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('NO SECTIONS YET', style: TextStyle(color: TechColors.textMuted, fontFamily: 'monospace', fontSize: 11)))))
    else ...sections.map((s) {
      final loc = locations.firstWhere((l) => l['location_id']?.toString() == s['location_id']?.toString(), orElse: () => const {'name': 'Unknown location'});
      final leads = maps(s['team_leads']);
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: _glassRow(child: Row(children: [
        const Icon(Icons.subdirectory_arrow_right, size: 16, color: TechColors.statusBlue), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(s['name'].toString(), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
          const SizedBox(height: 3),
          Text('${loc['name']}  ·  ${s['employee_count'] ?? 0} employees', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
        ])),
        Text(leads.isEmpty ? 'NO TEAM LEAD' : leads.map((x) => x['employee_id'].toString()).join(', '), style: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace')),
      ])));
    }),
  ]);

  Widget auditView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _title('Audit Log', detail: 'SYSTEM EVENT STREAM', icon: Icons.terminal),
      const SizedBox(height: 12),
      if (audit.isEmpty)
        surface(
          const Padding(
            padding: EdgeInsets.all(28),
            child: Text(
              'NO AUDIT EVENTS ARE AVAILABLE.',
              style: TextStyle(
                color: TechColors.textMuted,
                fontFamily: 'monospace',
                fontSize: 11,
              ),
            ),
          ),
        )
      else
        GlassCard(
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.all(10),
          settings: TechColors.sectionGlass,
          quality: GlassQuality.standard,
          shape: const LiquidRoundedSuperellipse(borderRadius: 16),
          child: Column(
            children: audit.map((e) {
              final timestamp = e['created_at']?.toString() ?? '—';
              final action = e['action']?.toString() ?? 'EVENT';
              final outcome = e['outcome']?.toString() ?? '—';
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: _glassRow(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final compact = constraints.maxWidth < 520;
                      final event = Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(action, style: const TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'monospace',
                            )),
                            const SizedBox(height: 3),
                            Text(outcome, style: const TextStyle(
                              color: TechColors.textMuted,
                              fontSize: 10,
                              fontFamily: 'monospace',
                            )),
                          ],
                        ),
                      );
                      return compact
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(timestamp, style: const TextStyle(
                                        color: TechColors.textMuted,
                                        fontSize: 9,
                                        fontFamily: 'monospace',
                                      )),
                                    ),
                                    _statusDot(outcome),
                                  ],
                                ),
                                const SizedBox(height: 7),
                                event,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 120,
                                  child: Text(timestamp, style: const TextStyle(
                                    color: TechColors.textMuted,
                                    fontSize: 9,
                                    fontFamily: 'monospace',
                                  )),
                                ),
                                const SizedBox(width: 10),
                                event,
                                const SizedBox(width: 10),
                                _statusDot(outcome),
                              ],
                            );
                    },
                  ),
                ),
              );
            }).toList(),
          ),
        ),
    ],
  );

  Widget legacyView(String title, String text) => surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _eyebrow(title), const SizedBox(height: 7),
    Text(text, style: const TextStyle(color: TechColors.textMuted, height: 1.45)),
    const SizedBox(height: 14),
    _actionChip('OPEN LEGACY TOOLS', Icons.open_in_new, () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthorizationManagementScreen())), accent: true),
  ]));

  String _sectionLabel(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'Management Overview',
    ManagementSection.organization => 'Organization Topology',
    ManagementSection.people => 'People Registry',
    ManagementSection.locations => 'Location Registry',
    ManagementSection.sections => 'Section Hierarchy',
    ManagementSection.invitations => 'Invitations',
    ManagementSection.dataAccess => 'Data Access',
    ManagementSection.audit => 'Audit Log',
  };

  String _sectionDetail(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'ORGANIZATION CONTROL PLANE',
    ManagementSection.organization => 'LOCATION → SECTION → ASSIGNMENT',
    ManagementSection.people => 'IDENTITY / ROLE / PLACEMENT',
    ManagementSection.locations => 'BRANCH REGISTRY',
    ManagementSection.sections => 'LOCATION → SECTION HIERARCHY',
    ManagementSection.invitations => 'INVITATION CONTROL',
    ManagementSection.dataAccess => 'DATASET / RESOURCE AUTHORIZATION',
    ManagementSection.audit => 'SYSTEM EVENT STREAM',
  };

  IconData _sectionIcon(ManagementSection value) => switch (value) {
    ManagementSection.overview => Icons.dashboard_outlined,
    ManagementSection.organization => Icons.account_tree_outlined,
    ManagementSection.people => Icons.people_outline,
    ManagementSection.locations => Icons.location_on_outlined,
    ManagementSection.sections => Icons.account_tree_outlined,
    ManagementSection.invitations => Icons.mail_outline,
    ManagementSection.dataAccess => Icons.lock_outline,
    ManagementSection.audit => Icons.terminal,
  };

  Widget _telemetry(String label, int value) => GlassContainer(
    useOwnLayer: true,
    quality: GlassQuality.minimal,
    settings: dockGlassSettings(
      glassColor: TechColors.panelBg.withValues(alpha: 0.18),
    ),
    shape: const LiquidRoundedSuperellipse(borderRadius: 10),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _statusDot('active'),
        const SizedBox(width: 7),
        Text(
          '$label ${value.toString().padLeft(2, '0')}',
          style: const TextStyle(
            color: TechColors.textMuted,
            fontSize: 9,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
      ],
    ),
  );

  Widget body() {
    switch (section) {
      case ManagementSection.overview: return overviewView();
      case ManagementSection.organization: return organizationView();
      case ManagementSection.people: return peopleView();
      case ManagementSection.locations: return locationsView();
      case ManagementSection.sections: return sectionsView();
      case ManagementSection.invitations: return legacyView('Invitations', 'Existing invitation creation and acceptance behavior is preserved.');
      case ManagementSection.dataAccess: return legacyView('Data Access', 'Existing dataset grants, resource access, delegations, managed datasets, and working-copy controls are preserved.');
      case ManagementSection.audit: return auditView();
    }
  }

  Widget actions() => GlassCard(
    margin: EdgeInsets.zero, padding: const EdgeInsets.all(14),
    settings: TechColors.sectionGlass, quality: GlassQuality.standard,
    shape: const LiquidRoundedSuperellipse(borderRadius: 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _eyebrow('Contextual controls'), const SizedBox(height: 9),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _actionChip('ASSIGN MANAGER', Icons.manage_accounts, () => assignManager(), accent: true),
        _actionChip('REPLACE MANAGER', Icons.swap_horiz, () => assignManager(replace: true)),
        _actionChip('ASSIGN TEAM LEAD', Icons.supervisor_account, assignTeamLead),
      ]),
    ]),
  );

  Widget assignmentList() => GlassCard(
    margin: EdgeInsets.zero,
    padding: const EdgeInsets.all(14),
    settings: dockGlassSettings(
      glassColor: TechColors.panelBg.withValues(alpha: 0.24),
    ),
    quality: GlassQuality.minimal,
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
            child: _glassRow(
              child: Row(
                children: [
                  const Icon(Icons.link, size: 15, color: TechColors.statusBlue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(a['employee_id'].toString(), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                        Text('${a['role_id'] ?? '—'}  ·  ${a['location_name'] ?? '—'}  ·  ${a['section_name'] ?? '—'}', style: const TextStyle(color: TechColors.textMuted, fontSize: 9, fontFamily: 'monospace')),
                      ],
                    ),
                  ),
                  if (a['status'] == 'active')
                    _actionChip('REPORTING', Icons.account_tree_outlined, () => reporting(a)),
                ],
              ),
            ),
          );
        }),
      ],
    ),
  );

  Widget _glassActionButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    bool accent = false,
  }) {
    final color = accent ? TechColors.borderActive : TechColors.textMuted;
    return SizedBox(
      width: 38,
      height: 36,
      child: GlassButton.custom(
        onTap: onPressed ?? () {},
        enabled: onPressed != null,
        width: 38,
        height: 36,
        shape: const LiquidRoundedSuperellipse(borderRadius: 12),
        useOwnLayer: true,
        quality: GlassQuality.minimal,
        settings: dockGlassSettings(
          glassColor: accent
              ? TechColors.borderActive.withValues(alpha: 0.12)
              : TechColors.panelBg.withValues(alpha: 0.24),
        ),
        glowColor: accent
            ? TechColors.borderActive.withValues(alpha: 0.24)
            : Colors.transparent,
        glowRadius: accent ? 7 : 0,
        interactionScale: 1.04,
        child: Tooltip(
          message: tooltip,
          child: Center(
            child: Icon(icon, size: 16, color: color),
          ),
        ),
      ),
    );
  }

  Widget _managementAnalysisAction() => GlassButton.custom(
    onTap: () => openInsightFlowAnalysis(context),
    height: 38,
    width: 122,
    shape: const LiquidRoundedSuperellipse(borderRadius: 13),
    useOwnLayer: true,
    quality: GlassQuality.minimal,
    settings: dockGlassSettings(
      glassColor: TechColors.borderActive.withValues(alpha: 0.82),
    ),
    glowColor: kDockWhiteGlow.withValues(alpha: kDockGlowAlpha),
    glowRadius: kDockGlowRadius,
    interactionScale: kDockInteractionScale,
    child: const Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.analytics_outlined, size: 15, color: Colors.white),
        SizedBox(width: 7),
        Text(
          'ANALYSIS',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
            fontFamily: 'monospace',
          ),
        ),
      ],
    ),
  );

  Widget _buildGlassAppBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: GlassCard(
        margin: EdgeInsets.zero,
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 760;
            final identity = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.terminal,
                  color: TechColors.borderActive,
                  size: 18,
                ),
                const SizedBox(width: 10),
                const Text(
                  'InsightFlow',
                  style: TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            );
            final contextLabel = Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: _eyebrow('ORGANIZATION / MANAGEMENT'),
              ),
            );
            final controls = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _managementAnalysisAction(),
                const SizedBox(width: 8),
                _glassActionButton(
                  icon: Icons.refresh,
                  tooltip: 'Refresh management data',
                  onPressed: loadAll,
                ),
                const SizedBox(width: 6),
                _glassActionButton(
                  icon: Icons.logout,
                  tooltip: 'Log out',
                  onPressed: () => InsightFlowSupabaseAuthService.signOut(),
                ),
              ],
            );

            if (!compact) {
              return Row(
                children: [
                  identity,
                  Container(
                    width: 1,
                    height: 18,
                    margin: const EdgeInsets.symmetric(horizontal: 14),
                    color: TechColors.borderMuted,
                  ),
                  contextLabel,
                  controls,
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    identity,
                    const Spacer(),
                    _glassActionButton(
                      icon: Icons.refresh,
                      tooltip: 'Refresh management data',
                      onPressed: loadAll,
                    ),
                    const SizedBox(width: 6),
                    _glassActionButton(
                      icon: Icons.logout,
                      tooltip: 'Log out',
                      onPressed: () => InsightFlowSupabaseAuthService.signOut(),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Row(
                  children: [
                    contextLabel,
                    _managementAnalysisAction(),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _managementNavChip(
    ManagementSection target,
    String label,
  ) {
    final selected = target == section;
    return GlassChip(
      label: label,
      selected: selected,
      selectedColor: TechColors.borderActive.withValues(alpha: 0.32),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      labelStyle: TextStyle(
        fontSize: 11,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected
            ? TechColors.textPrimary
            : TechColors.textMuted.withValues(alpha: 0.92),
        fontFamily: 'monospace',
        letterSpacing: 0.2,
      ),
      onTap: () => setState(() => section = target),
    );
  }

  Widget _managementAnalysisNavChip() => GlassButton.custom(
    onTap: () => openInsightFlowAnalysis(context),
    height: 36,
    width: 112,
    shape: const LiquidRoundedSuperellipse(borderRadius: 12),
    useOwnLayer: true,
    quality: GlassQuality.minimal,
    settings: dockGlassSettings(
      glassColor: TechColors.borderActive.withValues(alpha: 0.78),
    ),
    glowColor: TechColors.borderActive.withValues(alpha: 0.30),
    glowRadius: 10,
    interactionScale: 1.02,
    child: const Center(
      child: Text(
        'ANALYSIS',
        style: TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          fontFamily: 'monospace',
        ),
      ),
    ),
  );

  Widget _buildManagementNavigation() {
    final chips = <Widget>[
      _managementNavChip(ManagementSection.overview, 'OVERVIEW'),
      _managementNavChip(ManagementSection.organization, 'ORGANIZATION'),
      _managementNavChip(ManagementSection.people, 'PEOPLE'),
      _managementNavChip(ManagementSection.locations, 'LOCATIONS'),
      _managementNavChip(ManagementSection.sections, 'SECTIONS'),
      _managementNavChip(ManagementSection.invitations, 'INVITATIONS'),
      _managementNavChip(ManagementSection.dataAccess, 'DATA ACCESS'),
      _managementNavChip(ManagementSection.audit, 'AUDIT LOG'),
      _managementAnalysisNavChip(),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      child: AdaptiveLiquidGlassLayer(
        settings: _kManagementNavigationGlassSettings,
        quality: GlassQuality.minimal,
        child: SizedBox(
          height: 56,
          child: SafeArea(
            top: false,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              itemCount: chips.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) => chips[index],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: LiquidGlassScope(
      child: Stack(
        children: [
          const Positioned.fill(
            child: GlassBackgroundSource(
              child: TechAnimatedBackground(),
            ),
          ),
          Positioned.fill(
            child: SafeArea(
              child: Column(
                children: [
                  _buildGlassAppBar(),
                  _buildManagementNavigation(),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, c) {
                        final narrow = c.maxWidth < 820;
                        return SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(
                            narrow ? 10 : 16,
                            8,
                            narrow ? 10 : 16,
                            28,
                          ),
                          child: Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1500),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (loading)
                                    GlassCard(
                                      margin: EdgeInsets.zero,
                                      padding: const EdgeInsets.all(40),
                                      settings: TechColors.sectionGlass,
                                      quality: GlassQuality.standard,
                                      shape: const LiquidRoundedSuperellipse(
                                        borderRadius: 18,
                                      ),
                                      child: const Column(
                                        children: [
                                          SizedBox(
                                            width: 22,
                                            height: 22,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.7,
                                              color: TechColors.borderActive,
                                            ),
                                          ),
                                          SizedBox(height: 12),
                                          Text(
                                            'INITIALIZING MANAGEMENT CONTROL PLANE',
                                            style: TextStyle(
                                              color: TechColors.textMuted,
                                              fontSize: 10,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ],
                                      ),
                                    )
                                  else if (error != null)
                                    GlassCard(
                                      margin: EdgeInsets.zero,
                                      padding: const EdgeInsets.all(24),
                                      settings: TechColors.sectionGlass,
                                      quality: GlassQuality.standard,
                                      shape: const LiquidRoundedSuperellipse(
                                        borderRadius: 18,
                                      ),
                                      child: Column(
                                        children: [
                                          const Icon(
                                            Icons.error_outline,
                                            color: TechColors.statusRed,
                                            size: 22,
                                          ),
                                          const SizedBox(height: 8),
                                          _eyebrow('Management service error'),
                                          const SizedBox(height: 5),
                                          Text(
                                            error!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: TechColors.textPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 13),
                                          _actionChip(
                                            'RETRY',
                                            Icons.refresh,
                                            loadAll,
                                            accent: true,
                                          ),
                                        ],
                                      ),
                                    )
                                  else ...[
                                    GlassContainer(
                                      useOwnLayer: true,
                                      quality: GlassQuality.minimal,
                                      settings: dockGlassSettings(
                                        glassColor: TechColors.panelBg.withValues(alpha: 0.22),
                                      ),
                                      shape: const LiquidRoundedSuperellipse(borderRadius: 22),
                                      padding: const EdgeInsets.fromLTRB(18, 16, 18, 20),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: [
                                          LayoutBuilder(
                                            builder: (context, inner) {
                                              final compact = inner.maxWidth < 680;
                                              final title = _title(
                                                _sectionLabel(section),
                                                detail: _sectionDetail(section),
                                                icon: _sectionIcon(section),
                                              );
                                              final telemetry = Wrap(
                                                spacing: 8,
                                                runSpacing: 8,
                                                children: [
                                                  _telemetry('LOC', locations.length),
                                                  _telemetry('PEOPLE', people.length),
                                                  _telemetry('SECTIONS', sections.length),
                                                  _telemetry('AUDIT', audit.length),
                                                ],
                                              );
                                              return compact
                                                  ? Column(
                                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                                      children: [title, const SizedBox(height: 12), telemetry],
                                                    )
                                                  : Row(
                                                      crossAxisAlignment: CrossAxisAlignment.start,
                                                      children: [
                                                        Expanded(child: title),
                                                        const SizedBox(width: 18),
                                                        telemetry,
                                                      ],
                                                    );
                                            },
                                          ),
                                          const SizedBox(height: 16),
                                          Container(height: 1, color: TechColors.borderMuted.withValues(alpha: 0.55)),
                                          const SizedBox(height: 16),
                                          if (section == ManagementSection.overview ||
                                              section == ManagementSection.organization) ...[
                                            actions(),
                                            const SizedBox(height: 14),
                                          ],
                                          body(),
                                          if (section == ManagementSection.organization) ...[
                                            const SizedBox(height: 14),
                                            assignmentList(),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}