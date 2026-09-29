import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../tech_background.dart';
import 'management_navigation.dart';
import 'authorization_management_screen.dart';

enum ManagementSection { overview, organization, people, locations, sections, invitations, dataAccess, audit }

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
  String search = '';
  String? selectedLocation;

  @override
  void initState() { super.initState(); loadAll(); }

  List<Map<String, dynamic>> maps(dynamic v) => v is List
      ? v.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : <Map<String, dynamic>>[];

  Future<Map<String, dynamic>> request(String path, {String method = 'GET', Map<String, dynamic>? body}) async {
    final headers = await supabaseAuthHeaders();
    if (insightFlowWorkspaceId.isNotEmpty) headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
    if (body != null) headers['Content-Type'] = 'application/json';
    final uri = Uri.parse(insightFlowBackendBaseUrl + '/v1/authz/management' + path);
    final response = method == 'POST'
        ? await http.post(uri, headers: headers, body: jsonEncode(body)).timeout(const Duration(seconds: 15))
        : await http.get(uri, headers: headers).timeout(const Duration(seconds: 15));
    dynamic data;
    try { data = jsonDecode(response.body); } catch (_) {}
    if (response.statusCode == 401) {
      await InsightFlowSupabaseAuthService.signOut();
      throw StateError('Your session is no longer authorized.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(data is Map && data['detail'] != null ? data['detail'].toString() : 'Management request failed.');
    }
    if (data is! Map) throw StateError('Management service returned an invalid response.');
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
    margin: EdgeInsets.zero, padding: const EdgeInsets.all(16),
    settings: TechColors.sectionGlass, quality: GlassQuality.standard,
    shape: const LiquidRoundedSuperellipse(borderRadius: 16), child: child);

  void feedback(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));
  }

  Future<void> createLocation() async {
    final name = TextEditingController(), id = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
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
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
      title: const Text('Create section'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(
          value: location, decoration: const InputDecoration(labelText: 'Location'),
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
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
      title: Text(replace ? 'Replace Manager' : 'Assign Manager'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(value: location, decoration: const InputDecoration(labelText: 'Location'),
          items: locations.map((x) => DropdownMenuItem(value: x['location_id'].toString(), child: Text(x['name'].toString()))).toList(),
          onChanged: (v) => set(() => location = v ?? location)),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(value: principal, decoration: const InputDecoration(labelText: 'Person'),
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
      return AlertDialog(
        title: const Text('Assign Team Lead'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButtonFormField<String>(value: location, decoration: const InputDecoration(labelText: 'Location'),
            items: locations.map((x) => DropdownMenuItem(value: x['location_id'].toString(), child: Text(x['name'].toString()))).toList(),
            onChanged: (v) => set(() => location = v ?? location)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: matching.isEmpty ? null : sectionId, decoration: const InputDecoration(labelText: 'Section'),
            items: matching.map((x) => DropdownMenuItem(value: x['section_id'].toString(), child: Text(x['name'].toString()))).toList(),
            onChanged: (v) => set(() => sectionId = v ?? sectionId)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(value: principal, decoration: const InputDecoration(labelText: 'Person'),
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
    final ok = await showDialog<bool>(context: context, builder: (c) => StatefulBuilder(builder: (c, set) => AlertDialog(
      title: const Text('Reporting relationship'),
      content: DropdownButtonFormField<String?>(
        value: candidates.any((x) => x['assignment_id'].toString() == parent) ? parent : null,
        decoration: const InputDecoration(labelText: 'Reports to'),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('No direct reporting target')),
          ...candidates.map((x) => DropdownMenuItem<String?>(value: x['assignment_id'].toString(), child: Text(x['employee_id'].toString() + ' · ' + x['role_id'].toString()))),
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

  Widget metric(String label, dynamic value) => surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(label, style: const TextStyle(color: TechColors.textMuted, fontSize: 11)),
    const SizedBox(height: 5), Text((value ?? 0).toString(), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
  ]));

  Widget overviewView() {
    final org = Map<String, dynamic>.from(overview['organization'] ?? const {});
    final sum = Map<String, dynamic>.from(overview['summary'] ?? const {});
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      surface(ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.business_outlined, color: TechColors.borderActive),
        title: Text(org['name']?.toString() ?? 'Organization', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        subtitle: Text('Workspace ' + (insightFlowWorkspaceId.isEmpty ? '—' : insightFlowWorkspaceId) + ' · ' + (org['status']?.toString() ?? '—')))),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        SizedBox(width: 150, child: metric('Locations', sum['location_count'])),
        SizedBox(width: 150, child: metric('Managers', sum['manager_count'])),
        SizedBox(width: 150, child: metric('Team Leads', sum['team_lead_count'])),
        SizedBox(width: 150, child: metric('Employees', sum['employee_count'])),
      ]),
    ]);
  }

  Widget organizationView() {
    if (locations.isEmpty) return surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('No organizational structure is configured yet.', style: TextStyle(color: TechColors.textMuted)))));
    return Column(children: locations.map((l) {
      final id = l['location_id'].toString();
      final secs = sections.where((s) => s['location_id'].toString() == id).toList();
      final asg = assignments.where((a) => a['location_id'].toString() == id && a['status'] == 'active').toList();
      final managers = asg.where((a) => a['role_id'] == 'manager').toList();
      return Padding(padding: const EdgeInsets.only(bottom: 10), child: surface(ExpansionTile(
        title: Text(l['name'].toString()), subtitle: Text(l['branch_identifier'].toString()),
        children: [
          ListTile(dense: true, leading: const Icon(Icons.manage_accounts_outlined), title: const Text('Manager'),
            subtitle: Text(managers.isEmpty ? 'Unassigned' : managers.first['employee_id'].toString())),
          for (final s in secs) ...[
            ListTile(dense: true, leading: const Icon(Icons.account_tree_outlined), title: Text(s['name'].toString()),
              subtitle: Text((s['employee_count'] ?? 0).toString() + ' employees')),
            ...asg.where((a) => a['section_id']?.toString() == s['section_id']?.toString() && (a['role_id'] == 'team_lead' || a['role_id'] == 'employee')).map((a) =>
              Padding(padding: const EdgeInsets.only(left: 26), child: ListTile(dense: true, title: Text(a['employee_id'].toString()), subtitle: Text(a['role_id'].toString())))),
          ],
        ],
      )));
    }).toList());
  }

  Widget peopleView() {
    final q = search.trim().toLowerCase();
    final list = people.where((p) => q.isEmpty || [p['employee_id'], p['role_id'], p['location_name'], p['section_name'], p['status']]
      .any((v) => v?.toString().toLowerCase().contains(q) ?? false)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(onChanged: (v) => setState(() => search = v), decoration: input('Search people')),
      const SizedBox(height: 12),
      if (list.isEmpty) surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('No people match this search.', style: TextStyle(color: TechColors.textMuted)))))
      else surface(Column(children: list.map((p) => ListTile(dense: true, leading: const Icon(Icons.person_outline),
        title: Text(p['employee_id']?.toString() ?? 'Person'),
        subtitle: Text((p['role_id'] ?? '—').toString() + ' · ' + (p['location_name'] ?? 'Unassigned location').toString() + ' · ' + (p['section_name'] ?? 'Unassigned section').toString() + ' · ' + (p['status'] ?? '—').toString()))).toList())),
    ]);
  }

  Widget locationsView() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [const Expanded(child: Text('Locations', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
      IconButton(onPressed: createLocation, tooltip: 'Create location', icon: const Icon(Icons.add))]),
    const SizedBox(height: 10),
    if (locations.isEmpty) surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('No locations yet.', style: TextStyle(color: TechColors.textMuted)))))
    else ...locations.map((l) => Padding(padding: const EdgeInsets.only(bottom: 8), child: surface(ListTile(
      contentPadding: EdgeInsets.zero, title: Text(l['name'].toString()),
      subtitle: Text('Branch: ' + l['branch_identifier'].toString() + ' · ' + (l['section_count'] ?? 0).toString() + ' sections · ' + (l['employee_count'] ?? 0).toString() + ' employees'),
      trailing: Text(l['manager']?['employee_id']?.toString() ?? 'No manager'),
      onTap: () => setState(() => selectedLocation = l['location_id'].toString()),
    )))),
  ]);

  Widget sectionsView() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [const Expanded(child: Text('Sections', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
      IconButton(onPressed: createSection, tooltip: 'Create section', icon: const Icon(Icons.add))]),
    const SizedBox(height: 10),
    if (sections.isEmpty) surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('No sections yet.', style: TextStyle(color: TechColors.textMuted)))))
    else ...sections.map((s) {
      final loc = locations.firstWhere((l) => l['location_id']?.toString() == s['location_id']?.toString(), orElse: () => const {'name': 'Unknown location'});
      final leads = maps(s['team_leads']);
      return Padding(padding: const EdgeInsets.only(bottom: 8), child: surface(ListTile(contentPadding: EdgeInsets.zero,
        title: Text(s['name'].toString()), subtitle: Text(loc['name'].toString() + ' · ' + (s['employee_count'] ?? 0).toString() + ' employees'),
        trailing: Text(leads.isEmpty ? 'No Team Lead' : leads.map((x) => x['employee_id'].toString()).join(', ')))));
    }),
  ]);

  Widget auditView() => audit.isEmpty ? surface(const Padding(padding: EdgeInsets.all(28), child: Center(child: Text('No audit events are available.', style: TextStyle(color: TechColors.textMuted))))) :
    surface(Column(children: audit.map((e) => ListTile(dense: true, leading: const Icon(Icons.history),
      title: Text(e['action']?.toString() ?? 'Event'),
      subtitle: Text((e['outcome'] ?? '—').toString() + ' · ' + (e['created_at'] ?? '').toString()))).toList()));

  Widget legacyView(String title, String text) => surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), const SizedBox(height: 6),
    Text(text, style: const TextStyle(color: TechColors.textMuted)), const SizedBox(height: 14),
    FilledButton.icon(onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AuthorizationManagementScreen())),
      icon: const Icon(Icons.open_in_new), label: const Text('Open existing authorization tools')),
  ]));

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

  Widget actions() => surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Management actions', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8),
    Wrap(spacing: 8, runSpacing: 8, children: [
      FilledButton.icon(onPressed: () => assignManager(), icon: const Icon(Icons.manage_accounts), label: const Text('Assign Manager')),
      FilledButton.icon(onPressed: () => assignManager(replace: true), icon: const Icon(Icons.swap_horiz), label: const Text('Replace Manager')),
      FilledButton.icon(onPressed: assignTeamLead, icon: const Icon(Icons.supervisor_account), label: const Text('Assign Team Lead')),
    ]),
  ]));

  Widget assignmentList() => surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Organizational assignments', style: TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 8),
    if (assignments.isEmpty) const Text('No assignments.', style: TextStyle(color: TechColors.textMuted)),
    ...assignments.map((a) => ListTile(dense: true, title: Text(a['employee_id'].toString()),
      subtitle: Text((a['role_id'] ?? '—').toString() + ' · ' + (a['location_name'] ?? '—').toString() + ' · ' + (a['section_name'] ?? '—').toString()),
      trailing: TextButton(onPressed: a['status'] == 'active' ? () => reporting(a) : null, child: const Text('Reporting')))),
  ]));

  Widget navButton(ManagementSection target, String label, IconData icon) {
    final selected = target == section;
    return TextButton.icon(
      onPressed: () => setState(() => section = target), icon: Icon(icon, size: 16),
      label: Text(label), style: TextButton.styleFrom(
        foregroundColor: selected ? TechColors.textPrimary : TechColors.textMuted,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ));
  }

  Widget nav(bool narrow) {
    final buttons = <Widget>[
      navButton(ManagementSection.overview, 'Overview', Icons.dashboard_outlined),
      navButton(ManagementSection.organization, 'Organization', Icons.account_tree_outlined),
      navButton(ManagementSection.people, 'People', Icons.people_outline),
      navButton(ManagementSection.locations, 'Locations', Icons.location_on_outlined),
      navButton(ManagementSection.sections, 'Sections', Icons.view_agenda_outlined),
      navButton(ManagementSection.invitations, 'Invitations', Icons.mail_outline),
      navButton(ManagementSection.dataAccess, 'Data Access', Icons.lock_outline),
      navButton(ManagementSection.audit, 'Audit Log', Icons.receipt_long_outlined),
      TextButton.icon(
        onPressed: () => openInsightFlowAnalysis(context),
        icon: const Icon(Icons.analytics_outlined, size: 16, color: TechColors.borderActive),
        label: const Text('Analysis'),
        style: TextButton.styleFrom(foregroundColor: TechColors.textPrimary),
      ),
      IconButton(onPressed: loadAll, tooltip: 'Refresh', icon: const Icon(Icons.refresh)),
      IconButton(onPressed: () => InsightFlowSupabaseAuthService.signOut(), tooltip: 'Log out', icon: const Icon(Icons.logout)),
    ];
    return GlassCard(
      margin: EdgeInsets.zero, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      settings: TechColors.sectionGlass, quality: GlassQuality.minimal,
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: narrow ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: Row(children: buttons)) : Wrap(spacing: 2, runSpacing: 2, children: buttons),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    body: LiquidGlassScope(child: Stack(children: [
      const Positioned.fill(child: GlassBackgroundSource(child: TechAnimatedBackground())),
      Positioned.fill(child: SafeArea(child: LayoutBuilder(builder: (context, c) {
        final narrow = c.maxWidth < 760;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(narrow ? 12 : 22, 12, narrow ? 12 : 22, 28),
          child: Center(child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1400),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              nav(narrow), const SizedBox(height: 12),
              if (loading) surface(const Padding(padding: EdgeInsets.all(36), child: Center(child: CircularProgressIndicator(strokeWidth: 1.8))))
              else if (error != null) surface(Column(children: [
                const Icon(Icons.error_outline, color: Colors.redAccent), const SizedBox(height: 8),
                Text(error!, textAlign: TextAlign.center), const SizedBox(height: 12),
                FilledButton(onPressed: loadAll, child: const Text('Retry')),
              ]))
              else ...[
                if (section == ManagementSection.overview || section == ManagementSection.organization) ...[actions(), const SizedBox(height: 12)],
                body(),
                if (section == ManagementSection.organization) ...[const SizedBox(height: 12), assignmentList()],
              ],
            ]),
          )),
        );
      })),
    ])),
  );
}
