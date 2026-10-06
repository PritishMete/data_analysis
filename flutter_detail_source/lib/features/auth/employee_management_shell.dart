import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import '../../tech_background.dart';
import 'managed_dataset_access_workspace.dart';

enum EmployeeCellSection { overview, datasets, profile }

class EmployeeManagementShell extends StatefulWidget {
  const EmployeeManagementShell({super.key});

  @override
  State<EmployeeManagementShell> createState() => _EmployeeManagementShellState();
}

class _EmployeeManagementShellState extends State<EmployeeManagementShell> {
  EmployeeCellSection section = EmployeeCellSection.overview;
  bool loading = true;
  String? error;
  Map<String, dynamic> overview = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, String>> _headers() async {
    final session = await InsightFlowSupabaseAuthService.ensureSession(
      timeout: const Duration(seconds: 8),
    );
    if (session == null || session.accessToken.isEmpty) {
      throw StateError('Authenticated session could not be restored.');
    }
    final headers = await supabaseAuthHeaders();
    if (insightFlowWorkspaceId.isNotEmpty) {
      headers['X-InsightFlow-Workspace-ID'] = insightFlowWorkspaceId;
    }
    return headers;
  }

  Future<void> _load() async {
    setState(() { loading = true; error = null; });
    try {
      final response = await httpGetAuth(
        '/v1/authz/management/overview',
        headers: await _headers(),
      );
      if (!mounted) return;
      setState(() {
        overview = response is Map
            ? Map<String, dynamic>.from(response)
            : const {};
        loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        loading = false;
        error = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Map<String, dynamic> get actor {
    final value = overview['actor'];
    return value is Map ? Map<String, dynamic>.from(value) : const {};
  }

  Map<String, dynamic> get policy {
    final value = overview['ui_policy'];
    return value is Map ? Map<String, dynamic>.from(value) : const {};
  }

  String get roleLabel {
    final value = policy['role_label']?.toString().trim() ?? '';
    return value.isEmpty ? 'Employee' : value;
  }

  String get scopeLabel {
    final value = policy['scope_label']?.toString().trim() ?? '';
    return value.isEmpty ? 'Assigned workspace' : value;
  }

  String _value(String key) {
    final value = actor[key]?.toString().trim() ?? '';
    return value.isEmpty ? '—' : value;
  }

  Widget _surface(Widget child) => GlassCard(
    margin: EdgeInsets.zero,
    padding: const EdgeInsets.all(16),
    shape: const LiquidRoundedSuperellipse(borderRadius: 16),
    child: child,
  );

  Widget _eyebrow(String text) => Text(
    text.toUpperCase(),
    style: const TextStyle(
      color: TechColors.textMuted,
      fontSize: 9,
      fontWeight: FontWeight.w700,
      letterSpacing: 1.2,
      fontFamily: 'monospace',
    ),
  );

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
    child: GlassContainer(
      useOwnLayer: true,
      quality: GlassQuality.standard,
      settings: TechColors.panelGlass,
      shape: const LiquidRoundedSuperellipse(borderRadius: 16),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          const Icon(Icons.person_outline_rounded,
              color: TechColors.borderActive, size: 18),
          const SizedBox(width: 9),
          const Text('InsightFlow',
              style: TextStyle(color: TechColors.textPrimary,
                  fontSize: 14, fontWeight: FontWeight.bold,
                  fontFamily: 'monospace')),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _eyebrow(roleLabel.toUpperCase() + ' / WORKSPACE'),
              const SizedBox(height: 3),
              Text(scopeLabel,
                  style: const TextStyle(color: TechColors.textMuted,
                      fontSize: 10, fontWeight: FontWeight.w600,
                      fontFamily: 'monospace')),
            ],
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18,
                color: TechColors.textPrimary),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: () => InsightFlowSupabaseAuthService.signOut(),
            icon: const Icon(Icons.logout, size: 18,
                color: TechColors.textPrimary),
          ),
        ],
      ),
    ),
  );

  Widget _navigation() {
    const tabs = <MapEntry<EmployeeCellSection, String>>[
      MapEntry(EmployeeCellSection.overview, 'OVERVIEW'),
      MapEntry(EmployeeCellSection.datasets, 'MY DATASETS'),
      MapEntry(EmployeeCellSection.profile, 'MY PROFILE'),
    ];
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: tabs.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final tab = tabs[index];
          final selected = section == tab.key;
          return GlassChip(
            label: tab.value,
            selected: selected,
            selectedColor: TechColors.borderActive.withValues(alpha: .22),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            labelStyle: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? TechColors.textPrimary : TechColors.textMuted,
            ),
            onTap: () => setState(() => section = tab.key),
          );
        },
      ),
    );
  }

  Widget _overview() {
    final name = _value('full_name');
    final professionalRole = _value('professional_role');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _surface(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow('EMPLOYEE MANAGEMENT CELL'),
            const SizedBox(height: 6),
            Text(
              'Welcome, ' + name,
              style: const TextStyle(color: TechColors.textPrimary,
                  fontSize: 22, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Your workspace contains only the resources and capabilities authorized for your account.',
              style: TextStyle(color: TechColors.textMuted,
                  fontSize: 11, height: 1.45),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                _stat('ORGANIZATIONAL LEVEL', roleLabel),
                _stat('PROFESSIONAL ROLE', professionalRole),
                _stat('EMPLOYEE ID', _value('employee_id')),
                _stat('SCOPE', scopeLabel),
              ],
            ),
          ],
        )),
        const SizedBox(height: 12),
        _surface(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _eyebrow('AUTHORIZED CAPABILITIES'),
            const SizedBox(height: 9),
            _capability('Own profile', true),
            _capability('Assigned workspace', true),
            _capability('Explicitly authorized datasets', true),
            _capability('Explicitly authorized working copies', true),
            _capability('Dataset upload / Import CSV', false),
            _capability('Organization-wide dataset access', false),
            _capability('Unauthorized dataset management', false),
          ],
        )),
      ],
    );
  }

  Widget _stat(String label, String value) => GlassContainer(
    useOwnLayer: true,
    quality: GlassQuality.minimal,
    settings: TechColors.panelGlass,
    shape: const LiquidRoundedSuperellipse(borderRadius: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _eyebrow(label),
      const SizedBox(height: 4),
      Text(value, maxLines: 2, overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: TechColors.textPrimary,
              fontSize: 11, fontWeight: FontWeight.w700)),
    ]),
  );

  Widget _capability(String label, bool allowed) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(children: [
      Icon(allowed ? Icons.check_circle_outline : Icons.block_outlined,
          size: 16,
          color: allowed ? TechColors.statusGreen : TechColors.statusRed),
      const SizedBox(width: 8),
      Expanded(child: Text(label,
          style: const TextStyle(color: TechColors.textPrimary, fontSize: 11))),
      Text(allowed ? 'AUTHORIZED' : 'DENIED',
          style: TextStyle(
            color: allowed ? TechColors.statusGreen : TechColors.statusRed,
            fontSize: 8, fontWeight: FontWeight.w700,
            fontFamily: 'monospace')),
    ]),
  );

  Widget _profile() => _surface(Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _eyebrow('MY PROFILE'),
      const SizedBox(height: 12),
      _profileRow('NAME', _value('full_name')),
      _profileRow('EMPLOYEE ID', _value('employee_id')),
      _profileRow('EMAIL', _value('email')),
      _profileRow('ROLE', roleLabel),
      _profileRow('SCOPE', scopeLabel),
    ],
  ));

  Widget _profileRow(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 11),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: 125, child: _eyebrow(label)),
      Expanded(child: Text(value,
          style: const TextStyle(color: TechColors.textPrimary,
              fontSize: 11, fontWeight: FontWeight.w600))),
    ]),
  );

  Widget _body() {
    switch (section) {
      case EmployeeCellSection.overview:
        return _overview();
      case EmployeeCellSection.datasets:
        return const ManagedDatasetAccessWorkspace();
      case EmployeeCellSection.profile:
        return _profile();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    extendBodyBehindAppBar: true,
    body: LiquidGlassScope(
      child: Stack(children: [
        const Positioned.fill(child: TechAnimatedBackground()),
        Positioned.fill(
          child: SafeArea(
            child: Column(children: [
              _header(),
              _navigation(),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 30),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1500),
                      child: loading
                          ? const Padding(
                              padding: EdgeInsets.all(32),
                              child: CircularProgressIndicator(
                                strokeWidth: 1.7,
                                color: TechColors.borderActive,
                              ),
                            )
                          : error != null
                              ? _surface(Column(children: [
                                  const Icon(Icons.error_outline_rounded,
                                      color: TechColors.statusRed),
                                  const SizedBox(height: 8),
                                  Text(error!,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                          color: TechColors.textPrimary,
                                          fontSize: 11)),
                                  const SizedBox(height: 12),
                                  TextButton(
                                      onPressed: _load,
                                      child: const Text('RETRY')),
                                ]))
                              : _body(),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ]),
    ),
  );
}
