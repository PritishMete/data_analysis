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
  String? selectedSection;
  Map<String, dynamic>? _selectedAssignmentProfile;
  Future<Map<String, dynamic>>? _assignmentProfileFuture;
  bool _showIdProof = false;

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
      if (mounted) {
        setState(() {
          loading = false;
          error = e.toString().replaceFirst('Bad state: ', '');
        });
      }
    }
  }

  InputDecoration input(String label) => InputDecoration(
    labelText: label.toUpperCase(),
    labelStyle: const TextStyle(color: TechColors.textMuted, fontSize: 10, fontFamily: 'monospace'),
    floatingLabelStyle: const TextStyle(color: TechColors.borderActive, fontSize: 10, fontFamily: 'monospace'),
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
            color: CupertinoColors.black.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 5),
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
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
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
              fontSize: 18,
              fontWeight: FontWeight.w700,
              fontFamily: 'monospace',
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
    if (difference.inMinutes < 60) return difference.inMinutes.toString() + ' min ago';
    if (difference.inHours < 24) return difference.inHours.toString() + ' hr ago';
    if (difference.inDays < 7) return difference.inDays.toString() + ' days ago';
    return timestamp.day.toString() + '/' + timestamp.month.toString() + '/' + timestamp.year.toString();
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
        ? actor + ' · ' + _humanizeAuditAction(action)
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
                      unassignedPeople.length.toString() + ' people may need a location or section assignment.',
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
                  : 'Manage your organization, people, access and activity from one place. Status: ' + organizationStatus + '.';
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
                  _overviewStructureStep('Branches / Locations', locationCount.toString() + ' locations', Icons.location_on_outlined),
                  _overviewStructureConnector(),
                  _overviewStructureStep('Sections', sectionCount.toString() + ' sections', Icons.account_tree_outlined),
                  _overviewStructureConnector(),
                  _overviewStructureStep('People', peopleCount.toString() + ' people', Icons.people_outline),
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
                _actionChip(
                  'CREATE LOCATION',
                  Icons.add_location_alt_outlined,
                  createLocation,
                ),
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
                              (a['role_id'] == 'team_lead' ||
                                  a['role_id'] == 'employee'),
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
                                    '${s['employee_count'] ?? 0} members',
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
    final q = search.trim().toLowerCase();
    final list = people.where((p) {
      if (q.isEmpty) return true;
      return [
        p['employee_id'],
        p['full_name'],
        p['role_id'],
        p['location_name'],
        p['section_name'],
        p['status'],
      ].any(
        (v) => v?.toString().toLowerCase().contains(q) ?? false,
      );
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GlassCard(
          margin: EdgeInsets.zero,
          padding: const EdgeInsets.all(14),
          shape: const LiquidRoundedSuperellipse(borderRadius: 16),
          child: Row(
            children: [
              const Icon(Icons.search, size: 16, color: TechColors.textMuted),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  onChanged: (v) => setState(() => search = v),
                  style: const TextStyle(
                    color: TechColors.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    hintText:
                        'SEARCH NAME / EMPLOYEE / ROLE / LOCATION / SECTION',
                    hintStyle: TextStyle(
                      color: TechColors.textMuted,
                      fontSize: 10,
                      fontFamily: 'monospace',
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        if (list.isEmpty)
          surface(
            const Padding(
              padding: EdgeInsets.all(28),
              child: Center(
                child: Text(
                  'NO PEOPLE MATCH THIS QUERY',
                  style: TextStyle(
                    color: TechColors.textMuted,
                    fontFamily: 'monospace',
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          )
        else
          Column(
            children: list.map((p) {
              final fullName = p['full_name']?.toString().trim() ?? '';
              final employeeId = p['employee_id']?.toString() ?? '—';
              return Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: _glassRow(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.person_outline,
                        size: 17,
                        color: TechColors.borderActive,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              fullName.isEmpty ? 'Profile incomplete' : fullName,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              employeeId,
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: TechColors.textMuted,
                                fontSize: 9,
                                fontFamily: 'monospace',
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${_roleLabel(p['role_id']?.toString() ?? '—')}  ·  ${p['location_name']?.toString() ?? 'Unassigned'}  ·  ${p['section_name']?.toString() ?? 'Unassigned'}',
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
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          _verificationBadge(
                            'EMAIL',
                            p['email_verified'] == true,
                          ),
                          const SizedBox(height: 3),
                          _verificationBadge(
                            'PHONE',
                            p['phone_verified'] == true,
                          ),
                          const SizedBox(height: 3),
                          _statusDot(p['status']?.toString() ?? ''),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }
  Widget auditView() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _title('Audit', detail: 'SYSTEM EVENT STREAM', icon: Icons.terminal),
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

  String _sectionLabel(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'Management Overview',
    ManagementSection.organization => 'Organization',
    ManagementSection.people => 'People Registry',
    ManagementSection.invitations => 'Invitations',
    ManagementSection.dataAccess => 'Access',
    ManagementSection.audit => 'Audit',
  };

  String _sectionDetail(ManagementSection value) => switch (value) {
    ManagementSection.overview => 'ORGANIZATION CONTROL PLANE',
    ManagementSection.organization => 'LOCATION → BRANCH HEAD / MANAGER → SECTION → TEAM LEAD → EMPLOYEE',
    ManagementSection.people => 'IDENTITY / ROLE / PLACEMENT',
    ManagementSection.invitations => 'INVITATION CONTROL',
    ManagementSection.dataAccess => 'DATASET / RESOURCE AUTHORIZATION',
    ManagementSection.audit => 'SYSTEM EVENT STREAM',
  };

  IconData _sectionIcon(ManagementSection value) => switch (value) {
    ManagementSection.overview => Icons.dashboard_outlined,
    ManagementSection.organization => Icons.account_tree_outlined,
    ManagementSection.people => Icons.people_outline,
    ManagementSection.invitations => Icons.mail_outline,
    ManagementSection.dataAccess => Icons.lock_outline,
    ManagementSection.audit => Icons.terminal,
  };

  Widget body() {
    switch (section) {
      case ManagementSection.overview: return overviewView();
      case ManagementSection.organization: return organizationView();
      case ManagementSection.people: return peopleView();
      case ManagementSection.invitations: return legacyView('Invitations', 'Existing invitation creation and acceptance behavior is preserved.');
      case ManagementSection.dataAccess: return const ManagedDatasetAccessWorkspace();
      case ManagementSection.audit: return auditView();
    }
  }

  Widget actions() => GlassCard(
    margin: EdgeInsets.zero, padding: const EdgeInsets.all(14),
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

  String _roleLabel(String value) {
    switch (value) {
      case 'branch_head':
        return 'BRANCH HEAD';
      case 'team_lead':
        return 'TEAM LEAD';
      case 'manager':
        return 'MANAGER';
      case 'employee':
        return 'EMPLOYEE';
      default:
        return value.toUpperCase();
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
    });
  }

  void _closeAssignmentProfile() {
    if (!mounted) return;
    setState(() {
      _selectedAssignmentProfile = null;
      _assignmentProfileFuture = null;
      _showIdProof = false;
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
                color: TechColors.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
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
                        (MediaQuery.sizeOf(context).height * 0.85)
                            .clamp(360.0, 1000.0)
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
                          ? ''
                          : proofNumber.length <= 4
                              ? proofNumber
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
                          _showIdProof ? proofNumber : maskedProof,
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
                        child: GlassContainer(
                          useOwnLayer: true,
                          quality: GlassQuality.standard,
                          settings: TechColors.panelGlass.copyWith(
                            glowIntensity: 0,
                            shadowElevation: 0,
                            shadow: const <BoxShadow>[],
                          ),
                          shape: const LiquidRoundedSuperellipse(borderRadius: 20),
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
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        shape: const LiquidRoundedSuperellipse(borderRadius: 16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 700;
            final identity = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.terminal, color: TechColors.borderActive, size: 18),
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
                _eyebrow('ORGANIZATION / MANAGEMENT'),
                const SizedBox(height: 3),
                const Text('MANAGEMENT WORKSPACE', style: TextStyle(
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
                  tooltip: 'Refresh management data',
                  onPressed: loadAll,
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: TechColors.textPrimary),
                ),
                IconButton(
                  tooltip: 'Sign out',
                  onPressed: () => InsightFlowSupabaseAuthService.signOut(),
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
    const tabs = <MapEntry<ManagementSection, String>>[
      MapEntry(ManagementSection.overview, 'OVERVIEW'),
      MapEntry(ManagementSection.organization, 'ORGANIZATION'),
      MapEntry(ManagementSection.people, 'PEOPLE'),
      MapEntry(ManagementSection.dataAccess, 'ACCESS'),
      MapEntry(ManagementSection.invitations, 'INVITATIONS'),
      MapEntry(ManagementSection.audit, 'AUDIT'),
    ];
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
                selectedColor: TechColors.borderActive.withValues(alpha: 0.18),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
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
                              ? _overviewSkeleton()
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