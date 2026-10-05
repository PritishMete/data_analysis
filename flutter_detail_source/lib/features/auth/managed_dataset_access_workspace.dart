import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'management_navigation.dart';

class ManagedDatasetAccessWorkspace extends StatefulWidget {
  const ManagedDatasetAccessWorkspace({super.key});
  @override
  State<ManagedDatasetAccessWorkspace> createState() => _ManagedDatasetAccessWorkspaceState();
}

class _ManagedDatasetAccessWorkspaceState extends State<ManagedDatasetAccessWorkspace> {
  bool loading = true, rowsLoading = false;
  String? error, rowsError, search;
  List<Map<String,dynamic>> datasets = [], catalog = [], members = [], requests = [], rows = [];
  List<String> roles = [];
  Map<String,dynamic>? selected, profile;
  int offset = 0;
  static const pageSize = 100;

  Future<Map<String,String>> _headers() async {
    final session = await InsightFlowSupabaseAuthService.ensureSession(timeout: const Duration(seconds: 8));
    if (session == null || session.accessToken.isEmpty) throw StateError('Authenticated session could not be restored.');
    final h = await supabaseAuthHeaders();
    if (insightFlowWorkspaceId.isNotEmpty) h['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
    return h;
  }

  Future<dynamic> _get(String path) async {
    final r = await http.get(Uri.parse(insightFlowBackendBaseUrl + path), headers: await _headers()).timeout(const Duration(seconds: 45));
    dynamic d; try { d = jsonDecode(r.body); } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) throw StateError(d is Map && d['detail'] != null ? d['detail'].toString() : 'Managed dataset request failed.');
    return d;
  }

  Future<dynamic> _post(String path, Map<String,dynamic> body) async {
    final h = await _headers(); h['Content-Type'] = 'application/json';
    final r = await http.post(Uri.parse(insightFlowBackendBaseUrl + path), headers: h, body: jsonEncode(body)).timeout(const Duration(seconds: 45));
    dynamic d; try { d = jsonDecode(r.body); } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) throw StateError(d is Map && d['detail'] != null ? d['detail'].toString() : 'Authorization change was rejected.');
    return d;
  }

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final values = await Future.wait([_get('/v1/managed-datasets'), _get('/v1/authz/management'), _get('/v1/authz/management/data-access/catalog'), _get('/v1/authz/management/data-access/requests')]);
      final ds = ((values[0] as Map?)?['datasets'] as List? ?? const []).whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
      final mg = values[1] is Map ? Map<String,dynamic>.from(values[1] as Map) : <String,dynamic>{};
      final cat = values[2] is Map ? Map<String,dynamic>.from(values[2] as Map) : <String,dynamic>{};
      final rq = values[3] is Map ? Map<String,dynamic>.from(values[3] as Map) : <String,dynamic>{};
      if (!mounted) return;
      setState(() {
        datasets = ds;
        catalog = (cat['datasets'] as List? ?? const []).whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
        requests = (rq['requests'] as List? ?? const []).whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
        members = (mg['members'] as List? ?? const []).whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
        roles = (mg['role_ids'] as List? ?? const []).map((e) => e.toString()).toList();
        loading = false;
      });
    } catch (e) {
      if (mounted) setState(() { loading = false; error = e.toString().replaceFirst('Bad state: ', ''); });
    }
  }

  Future<void> _select(Map<String,dynamic> d) async {
    final id = d['dataset_id']?.toString();
    if (id == null) return;
    setState(() { selected = d; profile = null; rows = []; offset = 0; rowsLoading = true; rowsError = null; });
    try {
      final p = await _get('/v1/managed-datasets/' + id + '/profile?preview_limit=5');
      profile = p is Map ? Map<String,dynamic>.from(p) : <String,dynamic>{};
      await _loadRows();
    } catch (e) {
      if (mounted) setState(() { rowsLoading = false; rowsError = e.toString().replaceFirst('Bad state: ', ''); });
    }
  }

  Future<void> _loadRows() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null) return;
    setState(() { rowsLoading = true; rowsError = null; });
    try {
      final v = profile?['version_id']?.toString();
      final q = 'limit=' + pageSize.toString() + '&offset=' + offset.toString() +
          ((v == null || v.isEmpty) ? '' : '&version_id=' + Uri.encodeQueryComponent(v));
      final d = await _get('/v1/managed-datasets/' + id + '/rows?' + q);
      final loaded = ((d as Map?)?['rows'] as List? ?? const []).whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
      if (mounted) setState(() { rows = loaded; rowsLoading = false; });
    } catch (e) {
      if (mounted) setState(() { rowsLoading = false; rowsError = e.toString().replaceFirst('Bad state: ', ''); });
    }
  }

  Future<void> _requestCopy(String datasetId) async {
    try {
      await _post('/v1/authz/management/data-access/requests?dataset_id=' + Uri.encodeQueryComponent(datasetId), {});
      _snack('Copy request submitted to the Branch Head.');
      await _load();
    } catch (e) { _snack(e); }
  }

  Future<void> _decideRequest(String requestId, bool approve) async {
    try {
      await _post('/v1/authz/management/data-access/requests/' + Uri.encodeQueryComponent(requestId) + '/decision?approve=' + approve.toString(), {});
      _snack(approve ? 'Copy request approved and assigned.' : 'Copy request rejected.');
      await _load();
    } catch (e) { _snack(e); }
  }

  Future<void> _grant(String uid, List<String> permissions) async {
    final id = selected?['dataset_id']?.toString();
    if (id == null) return;
    try {
      await _post('/v1/authz/datasets/grants', {'workspace_id': insightFlowWorkspaceId, 'dataset_id': id, 'target_uid': uid, 'permissions': permissions});
      _snack(permissions.isEmpty ? 'Dataset access revoked.' : 'Dataset access updated.');
    } catch (e) { _snack(e); }
  }

  // Backend authorization remains the source of truth; download surfaces its safe HTTP detail.
  Future<void> _download() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null) return;
    try {
      final v = profile?['version_id']?.toString();
      var path = '/v1/managed-datasets/' + id + '/download';
      if (v != null && v.isNotEmpty) path += '?version_id=' + Uri.encodeQueryComponent(v);
      final r = await http.get(Uri.parse(insightFlowBackendBaseUrl + path), headers: await _headers()).timeout(const Duration(minutes: 2));
      if (r.statusCode != 200) {
        dynamic decoded;
        try { decoded = jsonDecode(r.body); } catch (_) {}
        final detail = decoded is Map && decoded['detail'] != null
            ? decoded['detail'].toString()
            : switch (r.statusCode) {
                401 => 'Authentication required.',
                403 => 'Permission denied for this resource.',
                404 => 'Dataset version not found.',
                409 => 'Workspace context conflict.',
                _ => 'Managed dataset operation failed.',
              };
        throw StateError(detail);
      }
      var filename = _name(selected!);
      if (!filename.toLowerCase().endsWith('.csv')) filename += '.csv';
      await FilePicker.platform.saveFile(dialogTitle: 'Save managed dataset', fileName: filename, bytes: r.bodyBytes);
    } catch (e) { _snack(e); }
  }

  Future<void> _upload({String? datasetId}) async {
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: const ['csv'], withData: true);
      if (picked == null || picked.files.isEmpty || picked.files.single.bytes == null) return;
      final file = picked.files.single;
      final path = datasetId == null ? '/v1/managed-datasets' : '/v1/managed-datasets/' + datasetId + '/versions';
      final request = http.MultipartRequest('POST', Uri.parse(insightFlowBackendBaseUrl + path));
      request.headers.addAll(await _headers());
      request.files.add(http.MultipartFile.fromBytes('file', file.bytes!, filename: file.name));
      final response = await request.send().timeout(const Duration(minutes: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        dynamic decoded; try { decoded = jsonDecode(body); } catch (_) {}
        throw StateError(decoded is Map && decoded['detail'] != null ? decoded['detail'].toString() : 'Dataset import was rejected.');
      }
      _snack(datasetId == null ? 'Managed dataset imported.' : 'New dataset version imported.');
      await _load();
    } catch (e) { _snack(e); }
  }

  Future<void> _deleteDataset() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null) return;
    try {
      final response = await http.delete(Uri.parse(insightFlowBackendBaseUrl + '/v1/managed-datasets/' + id), headers: await _headers()).timeout(const Duration(seconds: 45));
      if (response.statusCode < 200 || response.statusCode >= 300) throw StateError('Dataset deletion was rejected.');
      setState(() { selected = null; profile = null; rows = []; });
      await _load();
    } catch (e) { _snack(e); }
  }

  Future<void> _startWorking() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null) return;
    try {
      final d = await _post('/v1/managed-datasets/' + id + '/working-copies', {});
      final w = d is Map && d['working_copy'] is Map ? Map<String,dynamic>.from(d['working_copy']) : <String,dynamic>{};
      if (!mounted) return;
      openInsightFlowAnalysis(context, managedDatasetId: id, managedVersionId: w['structured_version_id']?.toString() ?? w['source_version']?.toString(), managedWorkingCopyId: w['working_copy_id']?.toString());
    } catch (e) { _snack(e); }
  }

  void _snack(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));
  }

  String _name(Map<String,dynamic> d) => d['original_filename']?.toString() ?? d['display_name']?.toString() ?? d['dataset_name']?.toString() ?? 'Managed dataset';
  Widget _eye(String s) => Text(s.toUpperCase(), style: const TextStyle(color: TechColors.textMuted, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.3, fontFamily: 'monospace'));
  Widget _surface(Widget child) => GlassCard(margin: EdgeInsets.zero, padding: const EdgeInsets.all(14), shape: const LiquidRoundedSuperellipse(borderRadius: 16), child: child);
  // Dataset import/version controls are privileged: only Organization Owners and Branch Heads may see or invoke them.\n  bool get canManage => roles.contains('organization_owner') || roles.contains('branch_head');

  Widget _action(String label, IconData icon, VoidCallback onTap, {bool active = false}) => GlassButton.custom(onTap: onTap, height: 36, shape: const LiquidRoundedSuperellipse(borderRadius: 12), label: label, child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: active ? TechColors.borderActive : TechColors.textPrimary), const SizedBox(width: 6), Text(label, style: TextStyle(color: active ? TechColors.borderActive : TechColors.textPrimary, fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace'))]));

  @override Widget build(BuildContext context) {
    if (loading) return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 22, width: 150, decoration: BoxDecoration(color: TechColors.panelBg, borderRadius: BorderRadius.circular(8))),
        const SizedBox(height: 10),
        Container(height: 13, width: 270, decoration: BoxDecoration(color: TechColors.panelBg, borderRadius: BorderRadius.circular(8))),
      ])),
      const SizedBox(height: 12),
      _surface(Column(children: [
        for (var i = 0; i < 3; i++) Padding(padding: const EdgeInsets.only(bottom: 9), child: Container(height: 48, decoration: BoxDecoration(color: TechColors.panelBg.withValues(alpha: .6), borderRadius: BorderRadius.circular(12)))),
      ])),
    ]);
    if (error != null) return _surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Access is temporarily unavailable', style: TextStyle(color: TechColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 7),
      const Text('We could not load the current access information. Please retry; no access settings were changed.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
      const SizedBox(height: 12), _action('RETRY', Icons.refresh, _load, active: true),
    ]));
    final q = (search ?? '').trim().toLowerCase();
    final canManage = roles.contains('organization_owner') || roles.contains('branch_head');
    final filtered = datasets.where((d) => q.isEmpty || [d['original_filename'], d['dataset_name'], d['dataset_id'], d['current_version']].any((v) => v?.toString().toLowerCase().contains(q) == true)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _surface(Wrap(spacing: 10, runSpacing: 9, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Access', style: TextStyle(color: TechColors.textPrimary, fontSize: 21, fontWeight: FontWeight.w700)),
        const Text('Review managed resources and the access levels available to people in your organization.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
        const SizedBox(height: 10),
        _eye('RESOURCE SEARCH'),
        SizedBox(width: 320, child: TextField(onChanged: (v) => setState(() => search = v), style: const TextStyle(color: TechColors.textPrimary, fontSize: 12), decoration: InputDecoration(hintText: 'Search managed resources', prefixIcon: const Icon(Icons.search, size: 16), isDense: true, suffixIcon: (search ?? '').isEmpty ? null : IconButton(tooltip: 'Clear search', onPressed: () => setState(() => search = ''), icon: const Icon(Icons.close, size: 16))))),
        if (canManage) _action('IMPORT CSV', Icons.file_upload_outlined, () => _upload(), active: true), _action('REFRESH', Icons.refresh, _load),
      ])),
      const SizedBox(height: 12),
      _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(filtered.length.toString() + (filtered.length == 1 ? ' managed resource' : ' managed resources'), style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)), const SizedBox(height: 8),
        if (filtered.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Text(q.isEmpty ? 'No managed resources are available in this scope yet.' : 'No resources match your search. Clear the search or try another term.', textAlign: TextAlign.center, style: const TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4))),
        ...filtered.map((d) {
          final sel = d['dataset_id']?.toString() == selected?['dataset_id']?.toString();
          return Padding(padding: const EdgeInsets.only(bottom: 6), child: GlassContainer(useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass, shape: const LiquidRoundedSuperellipse(borderRadius: 13), padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9), child: InkWell(onTap: () => _select(d), borderRadius: BorderRadius.circular(13), child: Row(children: [
            Icon(sel ? Icons.dataset_rounded : Icons.insert_drive_file_outlined, size: 16, color: sel ? TechColors.borderActive : TechColors.textMuted), const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_name(d), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text((d['status'] ?? 'UNKNOWN').toString().toUpperCase() + ' · ' + (d['row_count'] ?? '—').toString() + ' ROWS · ' + (d['column_count'] ?? '—').toString() + ' COLUMNS · ' + (d['current_version'] ?? '—').toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 8, fontFamily: 'monospace')),
            ])),
            if (sel) const Icon(CupertinoIcons.chevron_right, size: 14, color: TechColors.borderActive),
          ]))));
        }),
      ])),
      if (selected != null) ...[const SizedBox(height: 12), _detail()],
    ]);
  }

  Widget _detail() {
    final d = selected!;
    final cols = ((profile?['column_names'] as List?) ?? const []).map((e) => e.toString()).toList();
    final total = int.tryParse((profile?['row_count'] ?? d['row_count'] ?? 0).toString()) ?? 0;
    final end = (offset + rows.length).clamp(0, total);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _surface(Wrap(spacing: 10, runSpacing: 9, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_eye('SELECTED DATASET'), const SizedBox(height: 3), Text(_name(d), style: const TextStyle(color: TechColors.textPrimary, fontSize: 17, fontWeight: FontWeight.w700))]),
        _stat('ROWS', (d['row_count'] ?? '—').toString()), _stat('COLUMNS', (d['column_count'] ?? '—').toString()), _stat('VERSION', (d['current_version'] ?? '—').toString()), _stat('STATUS', (d['status'] ?? 'UNKNOWN').toString().toUpperCase()),
        _action('START WORKING', Icons.edit_note, _startWorking, active: true),
        _action('DOWNLOAD CSV', Icons.download_outlined, _download),
        if (canManage) _action('NEW VERSION', Icons.upload_file_outlined, () => _upload(datasetId: d['dataset_id']?.toString())),
        if (canManage) _action('DELETE', Icons.delete_outline, _deleteDataset),
      ])),
      const SizedBox(height: 12),
      _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _eye('DATASET PREVIEW'), const SizedBox(height: 5), Text(total == 0 ? 'EMPTY DATASET' : 'SHOWING ' + (offset + 1).toString() + '–' + end.toString() + ' OF ' + total.toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 9, fontFamily: 'monospace')), const SizedBox(height: 8),
        if (rowsLoading) const SizedBox(height: 220, child: Center(child: CircularProgressIndicator(strokeWidth: 1.7, color: TechColors.borderActive)))
        else if (rowsError != null) Column(children: [Text(rowsError!, style: const TextStyle(color: TechColors.statusRed)), const SizedBox(height: 8), _action('RETRY', Icons.refresh, _loadRows, active: true)])
        else if (cols.isEmpty || total == 0) _eye('NO ROWS / NO COLUMNS')
        else SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          headingRowHeight: 36, dataRowMinHeight: 32, dataRowMaxHeight: 44, columnSpacing: 20,
          headingTextStyle: const TextStyle(color: TechColors.borderActive, fontSize: 8, fontFamily: 'monospace', fontWeight: FontWeight.w700),
          dataTextStyle: const TextStyle(color: TechColors.textPrimary, fontSize: 9),
          columns: cols.map((c) => DataColumn(label: Text(c))).toList(),
          rows: rows.map((r) {
            final data = r['row_data'] is Map ? Map<String,dynamic>.from(r['row_data']) : <String,dynamic>{};
            return DataRow(cells: cols.map((c) => DataCell(SizedBox(width: 145, child: Text(data[c]?.toString() ?? '—', maxLines: 2, overflow: TextOverflow.ellipsis)))).toList());
          }).toList(),
        )),
        if (!rowsLoading && rowsError == null && total > 0) Padding(padding: const EdgeInsets.only(top: 9), child: Row(children: [
          _action('PREVIOUS', Icons.chevron_left, offset == 0 ? () {} : () { setState(() => offset = (offset - pageSize).clamp(0, total)); _loadRows(); }),
          const Spacer(), Text('PAGE ' + ((offset ~/ pageSize) + 1).toString() + ' / ' + (total / pageSize).ceil().toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 8, fontFamily: 'monospace')), const Spacer(),
          _action('NEXT', Icons.chevron_right, offset + pageSize >= total ? () {} : () { setState(() => offset += pageSize); _loadRows(); }),
        ])),
      ])),
      const SizedBox(height: 12), _accessPanel(), const SizedBox(height: 12),
      _surface(Wrap(spacing: 8, runSpacing: 8, children: [_action('OPEN ANALYSIS', Icons.bar_chart, _startWorking, active: true), _action('BACK TO DATASETS', Icons.arrow_back, () => setState(() { selected = null; profile = null; rows = []; }))])),
    ]);
  }

  Widget _stat(String label, String value) => GlassContainer(useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass, shape: const LiquidRoundedSuperellipse(borderRadius: 11), padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_eye(label), const SizedBox(height: 2), Text(value, style: const TextStyle(color: TechColors.textPrimary, fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'monospace'))]));

  Widget _accessPanel() => _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Dataset authorization workflow', style: TextStyle(color: TechColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
    const SizedBox(height: 5),
    const Text('Original datasets remain Branch Head / Organization Owner only. Managers and Team Leads request a working copy; approval creates and assigns a private copy.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
    const SizedBox(height: 10),
    if (roles.contains('manager') || roles.contains('team_lead')) ...[
      const Text('BRANCH DATA CATALOG', style: TextStyle(color: TechColors.borderActive, fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
      const SizedBox(height: 6),
      ...catalog.map((d) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: GlassContainer(useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 11), padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d['dataset_name']?.toString() ?? d['dataset_id']?.toString() ?? 'Dataset', style: const TextStyle(color: TechColors.textPrimary, fontSize: 10, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(d['location_name']?.toString() ?? 'Branch', style: const TextStyle(color: TechColors.textMuted, fontSize: 8, fontFamily: 'monospace')),
            ])),
            _action('REQUEST COPY', Icons.lock_open_outlined, () => _requestCopy(d['dataset_id'].toString()), active: true),
          ]),
        ),
      )),
    ],
    if (roles.contains('organization_owner') || roles.contains('branch_head')) ...[
      const Text('PENDING / RECENT REQUESTS', style: TextStyle(color: TechColors.borderActive, fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
      const SizedBox(height: 6),
      if (requests.isEmpty) const Text('No copy authorization requests.', style: TextStyle(color: TechColors.textMuted, fontSize: 10)),
      ...requests.map((r) => Padding(
        padding: const EdgeInsets.only(bottom: 5),
        child: GlassContainer(useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass,
          shape: const LiquidRoundedSuperellipse(borderRadius: 11), padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((r['requester_name']?.toString() ?? r['requester_employee_id']?.toString() ?? 'Employee') + ' · ' + (r['dataset_id']?.toString() ?? 'dataset'), style: const TextStyle(color: TechColors.textPrimary, fontSize: 10, fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text((r['status']?.toString() ?? 'pending').toUpperCase(), style: const TextStyle(color: TechColors.textMuted, fontSize: 8, fontFamily: 'monospace')),
            ])),
            if (r['status']?.toString() == 'pending') ...[
              _action('APPROVE', Icons.check, () => _decideRequest(r['request_id'].toString(), true), active: true),
              _action('REJECT', Icons.close, () => _decideRequest(r['request_id'].toString(), false)),
            ],
          ]),
        ),
      )),
    ],
  ]));
