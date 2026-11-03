import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import '../../app_colors.dart';
import '../../core/auth/authenticated_http.dart';
import '../../core/auth/supabase_auth_service.dart';
import 'management_navigation.dart';

String _managedDatasetSha256(Uint8List bytes) => sha256.convert(bytes).toString();

class ManagedDatasetAccessWorkspace extends StatefulWidget {
  const ManagedDatasetAccessWorkspace({
    super.key,
    this.readOnly = false,
    this.canRunAnalysis = false,
    this.capabilities = const <String>{},
  });

  /// External viewers can inspect explicitly authorized resources only.
  final bool readOnly;
  final bool canRunAnalysis;
  final Set<String> capabilities;
  @override
  State<ManagedDatasetAccessWorkspace> createState() => _ManagedDatasetAccessWorkspaceState();
}

class ManagedDatasetAccessSkeleton extends StatelessWidget {
  const ManagedDatasetAccessSkeleton({
    super.key,
    this.capabilities = const <String>{},
    this.readOnly = false,
  });

  final Set<String> capabilities;
  final bool readOnly;

  Widget _block({double height = 12, double? width, double radius = 8}) =>
      Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: TechColors.textMuted.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: TechColors.textMuted.withValues(alpha: .07)),
        ),
      );

  Widget _panel({required Widget child, EdgeInsets padding = const EdgeInsets.all(14)}) =>
      Container(
        padding: padding,
        decoration: BoxDecoration(
          color: const Color(0xB8051727),
          borderRadius: BorderRadius.circular(13),
          border: Border.all(color: const Color(0xFF164564).withValues(alpha: .9)),
        ),
        child: child,
      );

  Widget _datasetRow() => _panel(
    child: LayoutBuilder(builder: (context, constraints) {
      final identity = Row(children: [
        _block(width: 38, height: 38, radius: 10),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _block(width: 165, height: 12),
          const SizedBox(height: 7),
          _block(width: 115, height: 9),
        ])),
      ]);
      final metadata = Wrap(spacing: 10, runSpacing: 7, children: [
        _block(width: 54, height: 18, radius: 20),
        _block(width: 65, height: 18, radius: 20),
      ]);
      return constraints.maxWidth < 560
          ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              identity, const SizedBox(height: 10), metadata,
              const SizedBox(height: 10), _block(width: 130, height: 32, radius: 8),
            ])
          : Row(children: [
              Expanded(flex: 4, child: identity),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: metadata),
              const SizedBox(width: 12),
              _block(width: 130, height: 32, radius: 8),
            ]);
    }),
  );

  @override
  Widget build(BuildContext context) {
    final showProposalQueue = capabilities.contains('dataset.proposal.submit') ||
        capabilities.contains('dataset.proposal.review');
    final showAccessManagement = capabilities.contains('dataset.copy.request') ||
        capabilities.contains('dataset.copy_requests.review') ||
        capabilities.contains('dataset.upload_grants.manage');
    final showUpload = !readOnly && capabilities.contains('dataset.upload.direct');
    return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _panel(padding: const EdgeInsets.all(18), child: Row(children: [
        _block(width: 42, height: 42, radius: 11),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _block(width: 145, height: 10),
          const SizedBox(height: 9),
          _block(width: 235, height: 22),
          const SizedBox(height: 7),
          _block(width: 295, height: 10),
        ])),
      ])),
      const SizedBox(height: 12),
      LayoutBuilder(builder: (context, constraints) {
        final columns = constraints.maxWidth < 560 ? 2 : 4;
        const gap = 10.0;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(spacing: gap, runSpacing: gap, children: List.generate(4, (_) =>
          SizedBox(width: width, child: _panel(child: Row(children: [
            _block(width: 36, height: 36, radius: 10),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _block(width: 54, height: 21),
              const SizedBox(height: 6),
              _block(width: 92, height: 9),
            ])),
          ]))),
        ));
      }),
      const SizedBox(height: 12),
      _panel(child: LayoutBuilder(builder: (context, constraints) {
        final controls = Wrap(spacing: 8, runSpacing: 8, children: [
          _block(width: 190, height: 38, radius: 9),
          _block(width: 116, height: 38, radius: 9),
          _block(width: 116, height: 38, radius: 9),
        ]);
        final actions = Wrap(spacing: 8, runSpacing: 8, children: [
          if (showUpload)
            KeyedSubtree(
              key: const ValueKey('dataset-upload-skeleton'),
              child: _block(width: 142, height: 36, radius: 9),
            ),
          _block(width: 90, height: 36, radius: 9),
        ]);
        return constraints.maxWidth < 760
            ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                controls, const SizedBox(height: 10), actions,
              ])
            : Row(children: [
                Expanded(child: controls), const SizedBox(width: 12), actions,
              ]);
      })),
      const SizedBox(height: 12),
      _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _block(width: 150, height: 14),
        const SizedBox(height: 10),
        ...List.generate(4, (_) => Padding(
          padding: const EdgeInsets.only(bottom: 9),
          child: _datasetRow(),
        )),
      ])),
      if (showProposalQueue) ...[
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const ValueKey('dataset-proposal-skeleton'),
          child: _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _block(width: 185, height: 14),
            const SizedBox(height: 8),
            _block(width: 265, height: 10),
            const SizedBox(height: 12),
            ...List.generate(2, (_) => _datasetRow()),
          ])),
        ),
      ],
      if (showAccessManagement) ...[
        const SizedBox(height: 12),
        KeyedSubtree(
          key: const ValueKey('dataset-access-skeleton'),
          child: _panel(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _block(width: 165, height: 14),
            const SizedBox(height: 12),
            ...List.generate(3, (_) => _datasetRow()),
          ])),
        ),
      ],
    ],
    );
  }
}

class _ManagedDatasetRequestException implements Exception {
  const _ManagedDatasetRequestException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

class _ManagedDatasetAccessWorkspaceState extends State<ManagedDatasetAccessWorkspace> {
  bool loading = true, rowsLoading = false;
  bool _uploading = false;
  bool _cancelUploadRequested = false;
  bool _deletingDataset = false;
  bool _openingWorkingCopy = false;
  int _loadGeneration = 0;
  int _selectionGeneration = 0;
  int _rowsGeneration = 0;
  final Set<String> _pendingAccessOperations = <String>{};
  double _uploadProgress = 0;
  http.Client? _activeUploadClient;
  bool _hasLoadedCoreSnapshot = false;
  String? error, rowsError, search, refreshError;
  String _sortBy = 'newest';
  String _statusFilter = 'all';
  String _locationFilter = 'all';
  String? catalogError, requestsError;
  List<Map<String,dynamic>> datasets = [], catalog = [], members = [], requests = [], rows = [];
  List<Map<String,dynamic>> proposals = [];
  List<Map<String,dynamic>> managerUploadGrants = [];
  String? managerUploadGrantsError;
  String? proposalsError;
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

  String _httpFailureMessage(int statusCode, dynamic decoded, {String fallback = 'Managed dataset request failed.'}) {
    final rawDetail = decoded is Map ? decoded['detail'] : null;
    // FastAPI sometimes returns structured details (for example, a duplicate
    // conflict object). Never stringify the entire map into a user-facing
    // error; extract only a deliberate message when one is available.
    final detail = rawDetail is String
        ? rawDetail.trim()
        : rawDetail is Map
            ? (rawDetail['message'] ?? rawDetail['error'])?.toString().trim()
            : null;
    final normalizedDetail = (detail ?? '').toLowerCase();

    if (statusCode == 403 &&
        (normalizedDetail.contains('authorization context') ||
            normalizedDetail.contains('active branch assignment') ||
            normalizedDetail.contains('workspace authorization'))) {
      return 'InsightFlow could not verify your active branch access. Refresh the page and sign in again. If the problem continues, ask your Organization Owner to verify your branch assignment. No change was confirmed.';
    }
    if (statusCode >= 500) {
      return 'The service is temporarily unavailable. Your change was not confirmed; refresh the dataset list before retrying.';
    }
    if (detail != null && detail.isNotEmpty) return detail;
    switch (statusCode) {
      case 400: return 'The request is invalid. Check the selected dataset and try again.';
      case 401: return 'Your session has expired. Sign in again and retry.';
      case 403: return 'You do not have permission to perform this action in the current branch.';
      case 404: return 'This resource is no longer available in your authorized scope. Refresh the list.';
      case 409: return 'This resource changed or conflicts with another operation. Refresh and try again.';
      case 422: return 'The submitted data did not pass validation. Check the input and try again.';
      case 429: return 'Too many requests. Wait a moment and retry.';
      default: return fallback;
    }
  }

  Future<dynamic> _get(String path) async {
    final headers = await _headers();
    const retryableStatuses = {429, 500, 502, 503, 504};
    for (var attempt = 0; attempt < 3; attempt++) {
      final response = await http
          .get(Uri.parse(insightFlowBackendBaseUrl + path), headers: headers)
          .timeout(const Duration(seconds: 45));
      if (retryableStatuses.contains(response.statusCode) && attempt < 2) {
        final retryAfterSeconds =
            int.tryParse(response.headers['retry-after'] ?? '');
        final delayMs = retryAfterSeconds == null
            ? 350 * (attempt + 1)
            : (retryAfterSeconds * 1000).clamp(250, 2000).toInt();
        await Future.delayed(Duration(milliseconds: delayMs));
        continue;
      }
      dynamic decoded;
      try {
        decoded = jsonDecode(response.body);
      } catch (_) {}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw _ManagedDatasetRequestException(
          response.statusCode,
          _httpFailureMessage(response.statusCode, decoded),
        );
      }
      return decoded;
    }
    throw StateError('Managed dataset request failed after retrying.');
  }

  Future<dynamic> _loadAllAuthorizedDatasets() async {
    const pageSize = 100;
    final collected = <Map<String, dynamic>>[];
    var offset = 0;
    int? expectedTotal;
    while (true) {
      final result = await _get(
        '/v1/managed-datasets?limit=$pageSize&offset=$offset',
      );
      if (result is! Map) {
        throw StateError('The dataset catalogue returned an invalid response.');
      }
      final page = ((result['datasets'] as List?) ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      final pagination = result['pagination'];
      if (pagination is Map) {
        expectedTotal = int.tryParse((pagination['total'] ?? '').toString());
      }
      collected.addAll(page);
      offset += page.length;
      if (page.isEmpty ||
          (expectedTotal != null && offset >= expectedTotal) ||
          (pagination is Map && pagination['has_more'] == false) ||
          (pagination is! Map && page.length < pageSize)) {
        break;
      }
      if (page.length < pageSize) break;
    }

    // Deduplicate repeated records from retries or inconsistent pages. Prefer
    // the newest representation while keeping a stable first-seen ordering.
    final unique = <String, Map<String, dynamic>>{};
    for (final item in collected) {
      final id = (item['dataset_id'] ?? '').toString().trim();
      final fallback = [
        item['location_id'] ?? '',
        item['dataset_name'] ?? item['display_name'] ?? item['original_filename'] ?? '',
      ].join('|').toLowerCase();
      final key = id.isNotEmpty ? id : 'fallback:$fallback';
      final normalized = Map<String, dynamic>.from(item);
      final status = (normalized['status'] ?? '').toString().trim().toLowerCase();
      if (status.isNotEmpty) normalized['status'] = status;
      unique[key] = {...?unique[key], ...normalized};
    }
    return {
      'datasets': unique.values.toList(),
      'pagination': {
        'offset': 0,
        'limit': unique.length,
        'total': unique.length,
        'has_more': false,
      },
    };
  }

  String _errorMessage(Object error) =>
      error.toString().replaceFirst('Bad state: ', '');

  bool _isTransientRefreshFailure(Object error) {
    if (error is TimeoutException || error is http.ClientException) {
      return true;
    }
    return error is _ManagedDatasetRequestException &&
        const {429, 500, 502, 503, 504}.contains(error.statusCode);
  }

  Future<void> _loadCatalog([int? generation]) async {
    final expectedGeneration = generation ?? _loadGeneration;
    try {
      final result =
          await _get('/v1/authz/management/data-access/catalog');
      final items = ((result as Map?)?['datasets'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (mounted && expectedGeneration == _loadGeneration) {
        setState(() {
          catalog = items;
          catalogError = null;
        });
      }
    } catch (e) {
      if (mounted && expectedGeneration == _loadGeneration) {
        setState(() {
          catalog = [];
          catalogError = _errorMessage(e);
        });
      }
    }
  }

  Future<void> _loadCopyRequests([int? generation]) async {
    final expectedGeneration = generation ?? _loadGeneration;
    try {
      final result =
          await _get('/v1/authz/management/data-access/requests');
      final items = ((result as Map?)?['requests'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (mounted && expectedGeneration == _loadGeneration) {
        setState(() {
          requests = items;
          requestsError = null;
        });
      }
    } catch (e) {
      if (mounted && expectedGeneration == _loadGeneration) {
        setState(() {
          requests = [];
          requestsError = _errorMessage(e);
        });
      }
    }
  }

  Future<dynamic> _post(
    String path,
    Map<String,dynamic> body, {
    Map<String,String>? extraHeaders,
    Map<String,String>? headersOverride,
  }) async {
    final h = headersOverride == null
        ? await _headers()
        : Map<String,String>.from(headersOverride);
    h['Content-Type'] = 'application/json';
    if (extraHeaders != null) h.addAll(extraHeaders);
    final r = await http.post(
      Uri.parse(insightFlowBackendBaseUrl + path),
      headers: h,
      body: jsonEncode(body),
    ).timeout(const Duration(seconds: 45));
    dynamic d;
    try { d = jsonDecode(r.body); } catch (_) {}
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw StateError(_httpFailureMessage(
        r.statusCode,
        d,
        fallback: 'The authorization change was rejected. Refresh the page and retry.',
      ));
    }
    return d;
  }

  @override void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    final hadCoreSnapshot = _hasLoadedCoreSnapshot;
    setState(() {
      loading = !hadCoreSnapshot;
      error = null;
      refreshError = null;
    });
    try {
      // Dataset visibility and the role/member snapshot are the core view.
      // Catalog and copy-request lists are loaded independently below so a
      // transient failure in either optional panel cannot blank this screen.
      final values = widget.readOnly
          ? await Future.wait([
              _loadAllAuthorizedDatasets(),
              _get('/v1/authz/me'),
            ])
          : await Future.wait([
              _loadAllAuthorizedDatasets(),
              _get('/v1/authz/management'),
            ]);
      final ds = ((values[0] as Map?)?['datasets'] as List? ?? const [])
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .where((item) => (item['dataset_id']?.toString() ?? '').trim().isNotEmpty)
          .toList();
      final mg = values[1] is Map
          ? Map<String, dynamic>.from(values[1] as Map)
          : <String, dynamic>{};
      if (!mounted || generation != _loadGeneration) return;
      final selectedDatasetId = selected?['dataset_id']?.toString();
      Map<String, dynamic>? refreshedSelected;
      if (selectedDatasetId != null) {
        for (final item in ds) {
          if (item['dataset_id']?.toString() == selectedDatasetId) {
            refreshedSelected = item;
            break;
          }
        }
      }
      final selectedStillAuthorized = selectedDatasetId == null || refreshedSelected != null;
      final selectedVersionChanged = selected != null &&
          refreshedSelected != null &&
          selected?['current_version']?.toString() != refreshedSelected['current_version']?.toString();
      setState(() {
        datasets = ds;
        if (!selectedStillAuthorized) {
          selected = null;
          profile = null;
          rows = [];
          offset = 0;
        } else if (refreshedSelected != null) {
          selected = refreshedSelected;
          if (selectedVersionChanged) {
            // Do not keep a preview from an older version attached to the
            // refreshed catalogue record.
            profile = null;
            rows = [];
            rowsError = null;
            offset = 0;
          }
        }
        members = (mg['members'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        loading = false;
        error = null;
        refreshError = null;
        _hasLoadedCoreSnapshot = true;
      });

      if (!widget.readOnly) {
        final optionalLoads = <Future<void>>[];
        if (_can('dataset.copy.request')) optionalLoads.add(_loadCatalog(generation));
        if (_can('dataset.copy_requests.review')) optionalLoads.add(_loadCopyRequests(generation));
        await Future.wait(optionalLoads);
      }
      if (_requiresManagerUploadGrant) await _loadManagerUploadGrants(generation);
      if (_can('dataset.proposal.submit') || _can('dataset.proposal.review')) {
        await _loadProposals(generation);
      }
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      final keepLastSnapshot =
          _hasLoadedCoreSnapshot && _isTransientRefreshFailure(e);
      setState(() {
        loading = false;
        if (keepLastSnapshot) {
          // Preserve the last successful screen during a temporary gateway,
          // service or rate-limit failure. Authorization is still enforced by
          // every server mutation/read endpoint.
          refreshError = _errorMessage(e);
          error = null;
        } else {
          // Never retain stale role/member information after an auth or scope
          // failure; those values control which management actions are shown.
          error = _errorMessage(e);
          refreshError = null;
          _hasLoadedCoreSnapshot = false;
          datasets = [];
          catalog = [];
          members = [];
          requests = [];
          selected = null;
          profile = null;
          rows = [];
          offset = 0;
          managerUploadGrants = [];
          managerUploadGrantsError = null;
          proposals = [];
          catalogError = null;
          requestsError = null;
        }
      });
    }
  }

  Future<void> _loadManagerUploadGrants([int? generation]) async {
    final expectedGeneration = generation ?? _loadGeneration;
    if (expectedGeneration != _loadGeneration || !mounted) return;
    if (!_requiresManagerUploadGrant || widget.readOnly) {
      if (mounted && expectedGeneration == _loadGeneration) {
        setState(() {
          managerUploadGrants = [];
          managerUploadGrantsError = null;
        });
      }
      return;
    }
    try {
      final result = await _get('/v1/managed-datasets/upload-grants/me');
      final items = ((result as Map?)?['grants'] as List? ?? const [])
          .whereType<Map>().map((e) => Map<String,dynamic>.from(e))
          .where((e) => e['status']?.toString() == 'active').toList();
      if (mounted && expectedGeneration == _loadGeneration) setState(() {
        managerUploadGrants = items;
        managerUploadGrantsError = null;
      });
    } catch (e) {
      if (mounted && expectedGeneration == _loadGeneration) setState(() {
        // Fail closed: an unavailable grant endpoint must not leave upload
        // controls enabled from stale permissions or look like a valid empty
        // grant list. The backend independently rechecks every upload.
        managerUploadGrants = [];
        managerUploadGrantsError = _errorMessage(e);
      });
    }
  }

  bool _managerHasUploadGrantFor(Map<String,dynamic>? dataset) {
    if (!_requiresManagerUploadGrant) return false;
    if (dataset == null) return managerUploadGrants.isNotEmpty;
    final locationId = dataset['location_id']?.toString();
    return locationId != null && managerUploadGrants.any(
      (grant) => grant['location_id']?.toString() == locationId,
    );
  }

  Future<void> _grantManagerUpload() async {
    if (widget.readOnly || !_can('dataset.upload_grants.manage')) return;
    try {
      final scope = await _get('/v1/managed-datasets/upload-scope');
      final locations = ((scope as Map?)?['locations'] as List? ?? const [])
          .whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
      final managers = members.where((member) {
        final roleIds = (member['role_ids'] as List? ?? const []).map((e) => e.toString());
        return roleIds.contains('manager') && member['status']?.toString() == 'active'
            && member['principal_id'] != null;
      }).toList();
      if (locations.isEmpty || managers.isEmpty) {
        throw StateError('An active Manager and an authorized branch are required before granting upload access.');
      }
      String? locationId = locations.first['location_id']?.toString();
      String? managerId = managers.first['principal_id']?.toString();
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) =>
          AlertDialog(
            backgroundColor: const Color(0xFF0B1725),
            title: const Text('Grant Manager upload access', style: TextStyle(color: Colors.white)),
            content: SizedBox(width: 380, child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('This permits permanent original dataset uploads only within the selected branch. You can revoke it later.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: locationId,
                  dropdownColor: const Color(0xFF0B1725),
                  decoration: const InputDecoration(labelText: 'Branch'),
                  items: locations.map((location) => DropdownMenuItem(
                    value: location['location_id']?.toString(),
                    child: Text(location['location_name']?.toString() ?? 'Branch', overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (value) => setDialogState(() { locationId = value; }),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: managerId,
                  dropdownColor: const Color(0xFF0B1725),
                  decoration: const InputDecoration(labelText: 'Manager'),
                  items: managers.map((member) => DropdownMenuItem(
                    value: member['principal_id']?.toString(),
                    child: Text((member['employee_name'] ?? member['name'] ?? member['employee_id'] ?? member['principal_id']).toString(), overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (value) => setDialogState(() { managerId = value; }),
                ),
              ],
            )),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('CANCEL')),
              FilledButton(onPressed: locationId == null || managerId == null
                ? null : () => Navigator.of(dialogContext).pop(true), child: const Text('GRANT ACCESS')),
            ],
          ),
        ),
      );
      if (confirmed != true || locationId == null || managerId == null) return;
      await _post('/v1/managed-datasets/upload-grants', {
        'manager_principal_id': managerId,
        'location_id': locationId,
      });
      _snack('Manager upload access granted for the selected branch.');
      await _loadManagerUploadGrants();
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _revokeManagerUpload() async {
    if (widget.readOnly || !_can('dataset.upload_grants.manage')) return;
    try {
      final scope = await _get('/v1/managed-datasets/upload-scope');
      final locations = ((scope as Map?)?['locations'] as List? ?? const [])
          .whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
      if (locations.isEmpty) throw StateError('No branch is available within your authorization scope.');
      String? locationId = locations.first['location_id']?.toString();
      String? grantId;
      List<Map<String,dynamic>> grants = [];
      Future<void> refreshGrants() async {
        if (locationId == null) { grants = []; return; }
        final path = '/v1/managed-datasets/upload-grants?location_id=' + Uri.encodeQueryComponent(locationId!);
        final result = await _get(path);
        grants = ((result as Map?)?['grants'] as List? ?? const [])
            .whereType<Map>().map((e) => Map<String,dynamic>.from(e))
            .where((grant) => grant['status']?.toString() == 'active').toList();
        grantId = grants.isEmpty ? null : grants.first['grant_id']?.toString();
      }
      await refreshGrants();
      final selectedGrant = await showDialog<Map<String,String>>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) =>
          AlertDialog(
            backgroundColor: const Color(0xFF0B1725),
            title: const Text('Revoke Manager upload access', style: TextStyle(color: Colors.white)),
            content: SizedBox(width: 380, child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  value: locationId,
                  dropdownColor: const Color(0xFF0B1725),
                  decoration: const InputDecoration(labelText: 'Branch'),
                  items: locations.map((location) => DropdownMenuItem(
                    value: location['location_id']?.toString(),
                    child: Text(location['location_name']?.toString() ?? 'Branch', overflow: TextOverflow.ellipsis),
                  )).toList(),
                  onChanged: (value) async {
                    locationId = value;
                    await refreshGrants();
                    setDialogState(() {});
                  },
                ),
                const SizedBox(height: 10),
                if (grants.isEmpty)
                  const Text('No active Manager upload grants exist for this branch.', style: TextStyle(color: TechColors.textMuted, fontSize: 11))
                else
                  DropdownButtonFormField<String>(
                    value: grantId,
                    dropdownColor: const Color(0xFF0B1725),
                    decoration: const InputDecoration(labelText: 'Manager grant'),
                    items: grants.map((grant) {
                      final matching = members.where((m) => m['principal_id']?.toString() == grant['manager_principal_id']?.toString());
                      final member = matching.isEmpty ? null : matching.first;
                      final name = member?['employee_name'] ?? member?['name'] ?? grant['manager_principal_id'];
                      return DropdownMenuItem(value: grant['grant_id']?.toString(), child: Text(name.toString(), overflow: TextOverflow.ellipsis));
                    }).toList(),
                    onChanged: (value) => setDialogState(() { grantId = value; }),
                  ),
              ],
            )),
            actions: [
              TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('CANCEL')),
              FilledButton(
                onPressed: grantId == null ? null : () => Navigator.of(dialogContext).pop({'grant_id': grantId!, 'location_id': locationId!}),
                child: const Text('REVOKE ACCESS'),
              ),
            ],
          ),
        ),
      );
      if (selectedGrant == null) return;
      final headers = await _headers();
      final response = await http.delete(
        Uri.parse(insightFlowBackendBaseUrl + '/v1/managed-datasets/upload-grants/' + Uri.encodeComponent(selectedGrant['grant_id']!)),
        headers: headers,
      ).timeout(const Duration(seconds: 45));
      dynamic body; try { body = jsonDecode(response.body); } catch (_) {}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(body is Map && body['detail'] != null ? body['detail'].toString() : 'Manager upload grant revocation was rejected.');
      }
      _snack('Manager upload access revoked.');
      await _loadManagerUploadGrants();
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _loadProposals([int? generation]) async {
    final expectedGeneration = generation ?? _loadGeneration;
    if (expectedGeneration != _loadGeneration || !mounted) return;
    if (!_can('dataset.proposal.submit') && !_can('dataset.proposal.review')) {
      setState(() { proposals = []; proposalsError = null; });
      return;
    }
    try {
      final result = await _get('/v1/managed-datasets/proposals');
      final items = ((result as Map?)?['proposals'] as List? ?? const [])
          .whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
      if (mounted && expectedGeneration == _loadGeneration) setState(() { proposals = items; proposalsError = null; });
    } catch (e) {
      if (mounted && expectedGeneration == _loadGeneration) setState(() { proposalsError = e.toString().replaceFirst('Bad state: ', ''); });
    }
  }

  Future<void> _submitProposal(String datasetId) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty || picked.files.single.bytes == null) {
        return;
      }
      final file = picked.files.single;
      if (file.size > 100 * 1024 * 1024) {
        throw StateError('This CSV exceeds the 100 MB managed-dataset upload limit.');
      }
      final request = http.MultipartRequest(
        'POST',
        Uri.parse(
          insightFlowBackendBaseUrl +
              '/v1/managed-datasets/' +
              Uri.encodeComponent(datasetId) +
              '/proposals',
        ),
      );
      request.headers.addAll(await _headers());
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
        ),
      );
      final response = await request.send().timeout(const Duration(minutes: 5));
      final body = await response.stream.bytesToString();
      dynamic decoded;
      try {
        decoded = jsonDecode(body);
      } catch (_) {}
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : 'Proposal submission was rejected.',
        );
      }
      _snack('Dataset proposal submitted for Branch Head review.');
      await _loadProposals();
    } catch (e) {
      _snack(e);
    }
  }

  Future<void> _decideProposal(String proposalId, bool approve) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(context: context, builder: (context) => AlertDialog(
      backgroundColor: const Color(0xFF0B1725),
      title: Text(approve ? 'Approve dataset proposal?' : 'Reject dataset proposal?', style: const TextStyle(color: Colors.white)),
      content: TextField(controller: controller, maxLength: 1000, maxLines: 3,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(labelText: 'Decision note (optional)', labelStyle: TextStyle(color: Color(0xFF9DBDDC)))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
        TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: Text(approve ? 'APPROVE' : 'REJECT'))],
    ));
    controller.dispose();
    if (note == null) return;
    try {
      await _post('/v1/managed-datasets/proposals/' + Uri.encodeComponent(proposalId) + '/decision', {'approve': approve, 'decision_note': note});
      _snack(approve ? 'Proposal approved and published.' : 'Proposal rejected.');
      await _loadProposals();
      await _load();
    } catch (e) { _snack(e); }
  }

  Future<void> _select(Map<String,dynamic> d) async {
    final id = d['dataset_id']?.toString();
    if (id == null || id.isEmpty || !mounted) return;
    final selectionGeneration = ++_selectionGeneration;
    setState(() {
      selected = d;
      profile = null;
      rows = [];
      offset = 0;
      rowsLoading = canViewOriginal;
      rowsError = null;
    });
    if (!canViewOriginal) return;
    try {
      final response = await _get('/v1/managed-datasets/' + Uri.encodeComponent(id) + '/profile?preview_limit=5');
      if (!mounted || selectionGeneration != _selectionGeneration || selected?['dataset_id']?.toString() != id) return;
      final loadedProfile = response is Map ? Map<String,dynamic>.from(response) : <String,dynamic>{};
      setState(() { profile = loadedProfile; });
      await _loadRows();
    } catch (e) {
      if (mounted && selectionGeneration == _selectionGeneration && selected?['dataset_id']?.toString() == id) {
        setState(() { rowsLoading = false; rowsError = _errorMessage(e); });
      }
    }
  }

  Future<void> _loadRows() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null || id.isEmpty || !mounted) return;
    final generation = ++_rowsGeneration;
    final versionId = profile?['version_id']?.toString();
    setState(() { rowsLoading = true; rowsError = null; });
    try {
      final q = 'limit=' + pageSize.toString() + '&offset=' + offset.toString() +
          ((versionId == null || versionId.isEmpty) ? '' : '&version_id=' + Uri.encodeQueryComponent(versionId));
      final d = await _get('/v1/managed-datasets/' + Uri.encodeComponent(id) + '/rows?' + q);
      final loaded = ((d as Map?)?['rows'] as List? ?? const []).whereType<Map>().map((e) => Map<String,dynamic>.from(e)).toList();
      if (mounted && generation == _rowsGeneration && selected?['dataset_id']?.toString() == id && profile?['version_id']?.toString() == versionId) {
        setState(() { rows = loaded; rowsLoading = false; });
      }
    } catch (e) {
      if (mounted && generation == _rowsGeneration && selected?['dataset_id']?.toString() == id) {
        setState(() { rowsLoading = false; rowsError = _errorMessage(e); });
      }
    }
  }

  Future<void> _requestCopy(String datasetId) async {
    final operation = 'copy-request:$datasetId';
    if (!_pendingAccessOperations.add(operation)) return;
    if (mounted) setState(() {});
    try {
      await _post('/v1/authz/management/data-access/requests?dataset_id=' + Uri.encodeQueryComponent(datasetId), {});
      await _load();
      _snack('Copy request submitted to the Branch Head.');
    } catch (e) {
      _snack(e);
    } finally {
      _pendingAccessOperations.remove(operation);
      if (mounted) setState(() {});
    }
  }

  Future<void> _decideRequest(String requestId, bool approve) async {
    final operation = 'copy-decision:$requestId';
    if (!_pendingAccessOperations.add(operation)) return;
    if (mounted) setState(() {});
    try {
      await _post('/v1/authz/management/data-access/requests/' + Uri.encodeQueryComponent(requestId) + '/decision?approve=' + approve.toString(), {});
      await _load();
      _snack(approve ? 'Copy request approved and assigned.' : 'Copy request rejected.');
    } catch (e) {
      _snack(e);
    } finally {
      _pendingAccessOperations.remove(operation);
      if (mounted) setState(() {});
    }
  }

  Future<void> _grant(String uid, List<String> permissions) async {
    final id = selected?['dataset_id']?.toString();
    if (id == null || id.isEmpty) return;
    final operation = 'grant:$id:$uid';
    if (!_pendingAccessOperations.add(operation)) return;
    if (mounted) setState(() {});
    try {
      await _post('/v1/authz/datasets/grants', {'workspace_id': insightFlowWorkspaceId, 'dataset_id': id, 'target_uid': uid, 'permissions': permissions});
      await _load();
      _snack(permissions.isEmpty ? 'Dataset access revoked.' : 'Dataset access updated.');
    } catch (e) {
      _snack(e);
    } finally {
      _pendingAccessOperations.remove(operation);
      if (mounted) setState(() {});
    }
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
        late final String detail;
        if (decoded is Map && decoded['detail'] != null) {
          detail = decoded['detail'].toString();
        } else {
          switch (r.statusCode) {
            case 401:
              detail = 'Authentication required.';
              break;
            case 403:
              detail = 'Permission denied for this resource.';
              break;
            case 404:
              detail = 'Dataset version not found.';
              break;
            case 409:
              detail = 'Workspace context conflict.';
              break;
            default:
              detail = 'Managed dataset operation failed.';
              break;
          }
        }
        throw StateError(detail);
      }
      var filename = _name(selected!);
      if (!filename.toLowerCase().endsWith('.csv')) filename += '.csv';
      await FilePicker.platform.saveFile(dialogTitle: 'Save managed dataset', fileName: filename, bytes: r.bodyBytes);
    } catch (e) { _snack(e); }
  }

  Future<String?> _promptDatasetName(String suggestedName) async {
    final controller = TextEditingController(text: suggestedName);
    try {
      return await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF0B1725),
          title: const Text(
            'Name this dataset',
            style: TextStyle(color: Colors.white),
          ),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Choose the name that will appear in InsightFlow and be saved with the dataset in the database.',
                  style: TextStyle(
                    color: TechColors.textMuted,
                    fontSize: 11,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  maxLength: 255,
                  textInputAction: TextInputAction.done,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: 'Dataset name',
                    hintText: 'e.g. Retail Sales 2026',
                  ),
                  onSubmitted: (value) {
                    final name = value.trim();
                    if (name.isNotEmpty) {
                      Navigator.of(dialogContext).pop(name);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  Navigator.of(dialogContext).pop(name);
                }
              },
              child: const Text('CONTINUE TO UPLOAD'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<String?> _confirmDatasetReplacement(List conflicts) async {
    final hasCrossBranchConflict = conflicts.whereType<Map>().any((raw) {
      final reasons = raw['reasons'] is List
          ? (raw['reasons'] as List).map((value) => value.toString()).toSet()
          : <String>{};
      return raw['code'] == 'content_outside_branch' ||
          reasons.contains('content_outside_branch');
    });
    final hasUploadInProgress = conflicts.whereType<Map>().any((raw) {
      final reasons = raw['reasons'] is List
          ? (raw['reasons'] as List).map((value) => value.toString()).toSet()
          : <String>{};
      return raw['code'] == 'upload_in_progress' ||
          reasons.contains('upload_in_progress');
    });
    final hasPendingProposal = conflicts.whereType<Map>().any((raw) {
      final reasons = raw['reasons'] is List
          ? (raw['reasons'] as List).map((value) => value.toString()).toSet()
          : <String>{};
      return raw['code'] == 'proposal_pending' ||
          reasons.contains('proposal_pending');
    });
    final visibleConflictIds = <String>{
      for (final raw in conflicts.whereType<Map>())
        if ((raw['dataset_id']?.toString() ?? '').trim().isNotEmpty)
          raw['dataset_id'].toString(),
    };
    if (hasCrossBranchConflict ||
        hasUploadInProgress ||
        hasPendingProposal ||
        visibleConflictIds.length != 1) {
      final message = hasCrossBranchConflict
          ? 'This CSV already exists in another branch. To protect branch data, InsightFlow cannot show or replace that dataset here. This upload is blocked.'
          : hasUploadInProgress
              ? 'An upload for this dataset is still processing. Nothing has been replaced. Wait for it to finish, or try again after InsightFlow marks an interrupted upload as failed.'
              : hasPendingProposal
                  ? 'A new dataset with this name is already awaiting Branch Head review. Do not upload it again. Wait for the proposal decision or ask the Branch Head to resolve it.'
                  : 'This upload matches more than one existing dataset. A single replacement could update the wrong data, so nothing has been changed. Use a different dataset name or resolve the other duplicate first.';
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) => AlertDialog(
          backgroundColor: const Color(0xFF0B1725),
          title: const Text('Cannot safely replace this dataset', style: TextStyle(color: Colors.white)),
          content: Text(message, style: const TextStyle(color: TechColors.textMuted, fontSize: 12, height: 1.45)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CLOSE'),
            ),
          ],
        ),
      );
      return null;
    }

    String? selectedId;
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF0B1725),
          title: const Text('Duplicate dataset found', style: TextStyle(color: Colors.white)),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'This upload matches an existing dataset name or CSV content. Select the existing dataset, then explicitly confirm replacement. Nothing will change if you cancel.',
                  style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4),
                ),
                const SizedBox(height: 10),
                ...conflicts.whereType<Map>().map((raw) {
                  final item = Map<String, dynamic>.from(raw);
                  final id = item['dataset_id']?.toString() ?? '';
                  final rawReasons = item['reasons'] is List
                      ? (item['reasons'] as List).map((value) => value.toString()).toList()
                      : [item['reason']?.toString() ?? 'duplicate'];
                  final labels = <String>[
                    if (rawReasons.contains('name')) 'Dataset name already exists',
                    if (rawReasons.contains('content')) 'Identical CSV content found',
                  ];
                  final selected = selectedId == id;
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Radio<String>(
                      value: id,
                      groupValue: selectedId,
                      onChanged: id.isEmpty
                          ? null
                          : (value) => setDialogState(() => selectedId = value),
                    ),
                    title: Text(
                      item['dataset_name']?.toString() ?? 'Existing dataset',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    subtitle: Text(
                      labels.isEmpty ? 'Duplicate dataset' : labels.join(' · '),
                      style: const TextStyle(color: TechColors.textMuted, fontSize: 10),
                    ),
                    selected: selected,
                    onTap: id.isEmpty
                        ? null
                        : () => setDialogState(() => selectedId = id),
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('CANCEL'),
            ),
            FilledButton(
              onPressed: selectedId == null
                  ? null
                  : () => Navigator.of(dialogContext).pop(selectedId),
              child: const Text('REPLACE DATASET'),
            ),
          ],
        ),
      ),
    );
  }

  Future<dynamic> _loadUploadScopeSafely() async {
    try {
      return await _get('/v1/managed-datasets/upload-scope');
    } catch (error) {
      // The name prompt may be cancelled while this request is running.
      // Return failures as values so an abandoned prefetch is not unhandled.
      return error;
    }
  }

  Future<void> _upload({String? datasetId}) async {
    if (_uploading) return;
    _uploading = true;
    if (mounted) setState(() {});
    var uploadDialogOpen = false;
    try {
      // Keep the native/browser file picker immediate; ask for the dataset
      // label before resolving remote scope or starting the upload.
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
      );
      if (picked == null || picked.files.isEmpty || picked.files.single.bytes == null) {
        return;
      }
      final file = picked.files.single;
      if (file.size > 100 * 1024 * 1024) {
        throw StateError('This CSV exceeds the 100 MB managed-dataset upload limit.');
      }
      // Resolve the branch list while the user is naming the CSV so the
      // network lookup does not add another wait before duplicate checking.
      final uploadScopeFuture = datasetId == null
          ? _loadUploadScopeSafely()
          : null;
      String? datasetName;
      if (datasetId == null) {
        final suggestedName = file.name
            .replaceFirst(RegExp(r'\.csv$', caseSensitive: false), '')
            .trim();
        datasetName = await _promptDatasetName(suggestedName);
        if (datasetName == null || !mounted) return;
      }

      String? uploadLocationId;
      if (datasetId == null) {
        final scopeResult = await uploadScopeFuture!;
        if (scopeResult is Exception) throw scopeResult;
        if (scopeResult is Error) throw scopeResult;
        final scope = scopeResult;
        final locations = ((scope as Map?)?['locations'] as List? ?? const [])
            .whereType<Map>()
            .map((item) => Map<String, dynamic>.from(item))
            .toList();
        if (locations.isEmpty) {
          throw StateError('No branch is authorized for original dataset uploads.');
        }
        if (_can('dataset.upload.direct') && locations.length != 1) {
          throw StateError('Your Branch Head account must resolve to exactly one assigned branch. Upload is blocked until the branch assignment is corrected.');
        }
        if (locations.length == 1) {
          uploadLocationId = locations.single['location_id']?.toString();
        } else {
          uploadLocationId = await showDialog<String>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: const Color(0xFF0B1725),
              title: const Text(
                'Choose upload branch',
                style: TextStyle(color: Colors.white),
              ),
              content: SizedBox(
                width: 360,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final location in locations)
                      ListTile(
                        title: Text(
                          location['location_name']?.toString() ?? 'Branch',
                          style: const TextStyle(color: Colors.white),
                        ),
                        subtitle: Text(
                          location['location_id']?.toString() ?? '',
                          style: const TextStyle(
                            color: TechColors.textMuted,
                            fontSize: 10,
                          ),
                        ),
                        onTap: () => Navigator.of(dialogContext)
                            .pop(location['location_id']?.toString()),
                      ),
                  ],
                ),
              ),
            ),
          );
          if (uploadLocationId == null) return;
        }
      } else if (_requiresManagerUploadGrant &&
          !_managerHasUploadGrantFor(selected)) {
        throw StateError(
          'A current upload grant for this exact branch is required.',
        );
      }

      final path = datasetId == null
          ? '/v1/managed-datasets'
          : '/v1/managed-datasets/' + Uri.encodeComponent(datasetId) + '/versions';

      // Hash locally and ask the backend about duplicates BEFORE sending
      // the CSV bytes. This is the fast path that makes the alert appear
      // without waiting for a potentially large multipart upload.
      final fileSha256 = await compute(_managedDatasetSha256, file.bytes!);
      final preflightBody = <String, dynamic>{
        'file_sha256': fileSha256,
        if (datasetName != null) 'dataset_name': datasetName,
        if (datasetId != null) 'dataset_id': datasetId,
      };
      final uploadHeaders = await _headers();
      if (uploadLocationId != null) {
        uploadHeaders['X-InsightFlow-Location-ID'] = uploadLocationId;
      }
      final preflight = await _post(
        '/v1/managed-datasets/duplicate-check',
        preflightBody,
        headersOverride: uploadHeaders,
      );
      final conflicts = (preflight is Map && preflight['conflicts'] is List)
          ? preflight['conflicts'] as List
          : const <dynamic>[];
      String? preflightReplaceId;
      var preflightConfirmDuplicate = false;
      if (conflicts.isNotEmpty) {
        final selectedConflictId = await _confirmDatasetReplacement(conflicts);
        if (selectedConflictId == null || !mounted) return;
        if (datasetId == null) {
          preflightReplaceId = selectedConflictId;
        } else {
          if (selectedConflictId != datasetId) {
            throw StateError('The duplicate confirmation did not match the selected dataset.');
          }
          preflightConfirmDuplicate = true;
        }
      }

      _cancelUploadRequested = false;
      _uploadProgress = 0;
      StateSetter? updateUploadDialog;
      final uploadClient = http.Client();
      _activeUploadClient = uploadClient;
      if (mounted) {
        setState(() {});
        uploadDialogOpen = true;
        unawaited(showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => StatefulBuilder(builder: (dialogContext, setDialogState) {
            updateUploadDialog = setDialogState;
            return AlertDialog(
            backgroundColor: const Color(0xFF0B1725),
            title: const Text('Importing dataset', style: TextStyle(color: Colors.white)),
            content: Row(children: [
              SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, value: _uploadProgress > 0 ? _uploadProgress : null)),
              const SizedBox(width: 12),
              Expanded(child: Text(_uploadProgress > 0 ? 'Uploading CSV · ${(_uploadProgress * 100).round()}%' : 'Preparing upload…', style: const TextStyle(color: TechColors.textMuted, fontSize: 12))),
            ]),
            actions: [
              TextButton(
                onPressed: () {
                  _cancelUploadRequested = true;
                  uploadDialogOpen = false;
                  _activeUploadClient?.close();
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('CANCEL UPLOAD'),
              ),
            ],
          );
          }),
        ));
      }
      Future<http.StreamedResponse> sendUpload({String? replaceId, bool confirmDuplicate = false}) async {
        final request = http.MultipartRequest(
          'POST',
          Uri.parse(insightFlowBackendBaseUrl + path),
        );
        request.headers.addAll(uploadHeaders);
        if (datasetName != null) request.fields['dataset_name'] = datasetName;
        if (replaceId != null) request.fields['replace_dataset_id'] = replaceId;
        if (confirmDuplicate) request.fields['confirm_duplicate'] = 'true';
        request.files.add(http.MultipartFile.fromBytes(
          'file',
          file.bytes!,
          filename: file.name,
        ));
        // Forward the multipart body as a stream so the UI can report actual
        // bytes sent instead of showing an indefinite spinner for large CSVs.
        final body = request.finalize();
        final outgoing = http.StreamedRequest('POST', request.url)
          ..headers.addAll(request.headers)
          ..contentLength = request.contentLength;
        final responseFuture = uploadClient.send(outgoing);
        var sentBytes = 0;
        final progressClock = Stopwatch()..start();
        await outgoing.sink.addStream(body.transform(
          StreamTransformer<List<int>, List<int>>.fromHandlers(
            handleData: (chunk, sink) {
              sentBytes += chunk.length;
              final totalBytes = outgoing.contentLength ?? 0;
              final isFinalChunk = totalBytes > 0 && sentBytes >= totalBytes;
              // Throttle rebuilds for large CSVs; update at most every 100 ms.
              if (totalBytes > 0 && mounted &&
                  (progressClock.elapsedMilliseconds >= 100 || isFinalChunk)) {
                _uploadProgress = (sentBytes / totalBytes).clamp(0.0, 1.0);
                progressClock
                  ..reset()
                  ..start();
                setState(() {});
                updateUploadDialog?.call(() {});
              }
              sink.add(chunk);
            },
          ),
        )).timeout(const Duration(minutes: 5));
        await outgoing.sink.close();
        return responseFuture.timeout(const Duration(minutes: 5));
      }

      var response = await sendUpload(
        replaceId: preflightReplaceId,
        confirmDuplicate: preflightConfirmDuplicate,
      );
      // Keep the upload endpoint's 409 handling as a race-condition fallback:
      // another user may upload the same file after preflight but before us.
      if (response.statusCode == 409) {
        final body = await response.stream.bytesToString().timeout(const Duration(seconds: 45));
        dynamic decoded;
        try { decoded = jsonDecode(body); } catch (_) {}
        final detail = decoded is Map ? decoded['detail'] : null;
        final conflicts = detail is Map && detail['conflicts'] is List
            ? detail['conflicts'] as List
            : const [];
        if (conflicts.isEmpty) throw StateError('A duplicate dataset was found, but its details could not be loaded.');
        final selectedConflictId = await _confirmDatasetReplacement(conflicts);
        if (selectedConflictId == null || !mounted) return;
        // A conflict retry is a new transfer; reset progress for the retry.
        _uploadProgress = 0;
        if (mounted) setState(() {});
        updateUploadDialog?.call(() {});
        if (datasetId == null) {
          response = await sendUpload(replaceId: selectedConflictId);
        } else {
          if (selectedConflictId != datasetId) {
            throw StateError('The duplicate confirmation did not match the selected dataset.');
          }
          response = await sendUpload(confirmDuplicate: true);
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString().timeout(const Duration(seconds: 45));
        dynamic decoded;
        try { decoded = jsonDecode(body); } catch (_) {}
        throw StateError(
          decoded is Map && decoded['detail'] != null
              ? decoded['detail'].toString()
              : 'Dataset import was rejected.',
        );
      }
      final successBody = await response.stream.bytesToString().timeout(const Duration(seconds: 45));
      dynamic successDecoded;
      try { successDecoded = jsonDecode(successBody); } catch (_) {}
      if (successDecoded is! Map || successDecoded['dataset'] is! Map) {
        throw StateError('The server did not confirm a published dataset.');
      }
      final datasetResult = Map<String, dynamic>.from(successDecoded['dataset']);
      final datasetStatus = (datasetResult['status'] ?? '').toString().toLowerCase();
      if (datasetStatus != 'ready') {
        throw StateError(
          'The CSV is not ready for use yet. Current status: '
          '${datasetStatus.isEmpty ? 'unknown' : datasetStatus}.',
        );
      }
      final uploadedDatasetId = datasetResult['dataset_id']?.toString();
      await _load();
      if (!mounted) return;
      if (uploadedDatasetId == null ||
          !datasets.any((item) => item['dataset_id']?.toString() == uploadedDatasetId)) {
        throw StateError(
          'The server marked the CSV READY, but the refreshed dataset list did not confirm it. Use REFRESH before attempting another upload.',
        );
      }
      if (datasetResult['content_unchanged'] == true) {
        _snack('Identical CSV already exists. The existing dataset was kept; no duplicate data was uploaded.');
      } else {
        _snack(
          datasetId == null
              ? 'Managed dataset imported. Verified in dataset list.'
              : 'New dataset version imported and verified.',
        );
      }
    } catch (e) {
      if (_cancelUploadRequested) {
        _snack('Upload connection cancelled. Refresh the dataset list before retrying because the server may already have received the CSV.');
      } else if (e is TimeoutException || e is http.ClientException) {
        _snack('The upload connection ended before confirmation. The server may have completed the import. Refresh the dataset list before retrying to avoid a duplicate upload.');
      } else {
        _snack(e);
      }
    } finally {
      _activeUploadClient?.close();
      _activeUploadClient = null;
      if (mounted) {
        if (uploadDialogOpen) {
          Navigator.of(context, rootNavigator: true).pop();
        }
        setState(() { _uploading = false; });
      } else {
        _uploading = false;
      }
    }
  }

  Future<void> _deleteDataset() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null || id.isEmpty || _deletingDataset || !mounted) return;
    setState(() { _deletingDataset = true; });
    try {
      final response = await http.delete(
        Uri.parse(insightFlowBackendBaseUrl + '/v1/managed-datasets/' + Uri.encodeComponent(id)),
        headers: await _headers(),
      ).timeout(const Duration(seconds: 45));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        dynamic decoded;
        try { decoded = jsonDecode(response.body); } catch (_) {}
        throw StateError(_httpFailureMessage(response.statusCode, decoded, fallback: 'Dataset deletion was rejected.'));
      }
      if (!mounted) return;
      setState(() { selected = null; profile = null; rows = []; offset = 0; });
      await _load();
      _snack('Dataset deleted.');
    } catch (e) {
      _snack(e);
    } finally {
      if (mounted) setState(() { _deletingDataset = false; });
    }
  }

  Future<void> _startWorking() async {
    final id = selected?['dataset_id']?.toString();
    if (id == null || id.isEmpty || _openingWorkingCopy || !mounted) return;
    setState(() { _openingWorkingCopy = true; });
    try {
      final d = await _post('/v1/managed-datasets/' + Uri.encodeComponent(id) + '/working-copies', {});
      final w = d is Map && d['working_copy'] is Map ? Map<String,dynamic>.from(d['working_copy']) : <String,dynamic>{};
      if (!mounted || selected?['dataset_id']?.toString() != id) return;
      final workingCopyId = w['working_copy_id']?.toString();
      if (workingCopyId == null || workingCopyId.isEmpty) {
        throw StateError('The backend did not return an authorized working-copy ID.');
      }
      // Never pass the original dataset ID into the analysis screen. The
      // backend resolves the pinned source version using this copy capability.
      openInsightFlowAnalysis(context, managedWorkingCopyId: workingCopyId, initialView: "AI_ANALYTICS", authorized: widget.canRunAnalysis && !widget.readOnly);
    } catch (e) {
      _snack(e);
    } finally {
      if (mounted) setState(() { _openingWorkingCopy = false; });
    }
  }

  void _snack(Object e) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))));
  }

  String _name(Map<String,dynamic> d) {
    for (final key in const ['display_name', 'dataset_name', 'original_filename']) {
      final value = d[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return 'Managed dataset';
  }

  String _displayStatus(Map<String, dynamic> dataset) {
    final status = (dataset['status'] ?? '').toString().trim().toLowerCase();
    if (status.isEmpty) return 'STATUS UNKNOWN';
    const labels = {
      'ready': 'READY',
      'processing': 'PROCESSING',
      'uploading': 'UPLOADING',
      'pending': 'PENDING',
      'failed': 'FAILED',
      'deleted': 'DELETED',
      'proposal_pending': 'PENDING REVIEW',
    };
    return labels[status] ?? status.replaceAll('_', ' ').toUpperCase();
  }
  Widget _eye(String s) => Text(s.toUpperCase(), style: const TextStyle(color: TechColors.textMuted, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: 1.3, fontFamily: 'monospace'));
  Widget _surface(Widget child) => GlassCard(margin: EdgeInsets.zero, padding: const EdgeInsets.all(14), shape: const LiquidRoundedSuperellipse(borderRadius: 16), child: child);
  bool _can(String capability) => widget.capabilities.contains(capability);

  bool get canViewOriginal => _can('dataset.view_original');

  // A Branch Head has direct branch authority. A Manager needs a current
  // explicit grant for the exact branch before the upload control is shown.
  bool get _requiresManagerUploadGrant =>
      _can('dataset.upload') && !_can('dataset.upload.direct');
  bool get canUpload => !widget.readOnly &&
      (_can('dataset.upload.direct') ||
       (_requiresManagerUploadGrant && managerUploadGrants.isNotEmpty));
  bool get canDelete => !widget.readOnly && _can('dataset.delete');
  bool get canCopy => !widget.readOnly &&
      widget.canRunAnalysis && !canViewOriginal;

  Widget _action(String label, IconData icon, VoidCallback onTap, {bool active = false}) => GlassButton.custom(onTap: onTap, height: 36, shape: const LiquidRoundedSuperellipse(borderRadius: 12), label: label, child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: active ? TechColors.borderActive : TechColors.textPrimary), const SizedBox(width: 6), Text(label, style: TextStyle(color: active ? TechColors.borderActive : TechColors.textPrimary, fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace'))]));

  @override Widget build(BuildContext context) {
    if (loading) return ManagedDatasetAccessSkeleton(
      capabilities: widget.capabilities,
      readOnly: widget.readOnly,
    );
    if (error != null) return _surface(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Access is temporarily unavailable', style: TextStyle(color: TechColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
      const SizedBox(height: 7),
      const Text('We could not load the current access information. Please retry; no access settings were changed.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
      const SizedBox(height: 12), _action('RETRY', Icons.refresh, _load, active: true),
    ]));
    final q = (search ?? '').trim().toLowerCase();
    final canManage = !widget.readOnly && _can('dataset.upload_grants.manage');
    final locationOptions = <String, String>{};
    for (final dataset in datasets) {
      final id = dataset['location_id']?.toString() ?? '';
      if (id.isNotEmpty) {
        locationOptions[id] = (dataset['location_name']?.toString().trim().isNotEmpty == true)
            ? dataset['location_name'].toString()
            : id;
      }
    }
    final filtered = datasets.where((d) {
      final values = [
        _name(d), d['original_filename'], d['dataset_name'], d['display_name'],
        d['dataset_id'], d['current_version'], d['location_name'],
        d['status'], d['owner_name'], d['created_at'],
      ];
      final matchesSearch = q.isEmpty ||
          values.any((v) => v?.toString().toLowerCase().contains(q) == true);
      final status = (d['status'] ?? '').toString().toLowerCase();
      final matchesStatus = _statusFilter == 'all' || status == _statusFilter;
      final location = d['location_id']?.toString() ?? '';
      final matchesLocation = _locationFilter == 'all' || location == _locationFilter;
      return matchesSearch && matchesStatus && matchesLocation;
    }).toList()
      ..sort((a, b) {
        switch (_sortBy) {
          case 'name':
            return _name(a).toLowerCase().compareTo(_name(b).toLowerCase());
          case 'status':
            final statusOrder = (a['status'] ?? 'unknown').toString()
                .toLowerCase().compareTo((b['status'] ?? 'unknown').toString().toLowerCase());
            return statusOrder != 0 ? statusOrder : _name(a).toLowerCase().compareTo(_name(b).toLowerCase());
          default:
            final aDate = DateTime.tryParse((a['created_at'] ?? a['updated_at'] ?? '').toString());
            final bDate = DateTime.tryParse((b['created_at'] ?? b['updated_at'] ?? '').toString());
            if (aDate == null && bDate == null) return _name(a).toLowerCase().compareTo(_name(b).toLowerCase());
            if (aDate == null) return 1;
            if (bDate == null) return -1;
            return bDate.compareTo(aDate);
        }
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (refreshError != null) ...[
        _surface(Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const Icon(Icons.cloud_off_outlined, color: Color(0xFFFFB454), size: 18),
          const SizedBox(width: 9),
          const Expanded(child: Text(
            'The latest refresh could not be completed. Showing the last successfully loaded data; retry to sync again.',
            style: TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.4),
          )),
          _action('RETRY', Icons.refresh, _load, active: true),
        ])),
        const SizedBox(height: 10),
      ],
      if (managerUploadGrantsError != null && _requiresManagerUploadGrant) ...[
        _surface(Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const Icon(Icons.shield_outlined, color: Color(0xFFFFB454), size: 18),
          const SizedBox(width: 9),
          const Expanded(child: Text(
            'Manager upload permissions could not be verified. Upload is disabled until permissions refresh successfully.',
            style: TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.4),
          )),
          _action('RETRY', Icons.refresh, _load, active: true),
        ])),
        const SizedBox(height: 10),
      ],
      _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 42, height: 42, alignment: Alignment.center, decoration: BoxDecoration(color: const Color(0xFF0D3854), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.shield_outlined, color: Color(0xFF43C8F3), size: 22)),
          const SizedBox(width: 12),
          const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Branch Data & Access', style: TextStyle(color: Color(0xFFE5F2FF), fontSize: 23, fontWeight: FontWeight.w800, letterSpacing: -.4)),
            SizedBox(height: 5),
            Text('Manage source datasets, review access requests, and work within your authorized scope.', style: TextStyle(color: Color(0xFF9DBDDC), fontSize: 12, height: 1.45)),
          ])),
        ]),
        const SizedBox(height: 16),
        LayoutBuilder(builder: (context, constraints) {
          final gap = 9.0, columns = constraints.maxWidth < 520 ? 2 : 4;
          final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
          Widget stat(String label, String value, IconData icon, Color accent) => Container(
            width: width, padding: const EdgeInsets.all(11),
            decoration: BoxDecoration(color: const Color(0xFF061522), borderRadius: BorderRadius.circular(11), border: Border.all(color: accent.withValues(alpha: .35))),
            child: Row(children: [Icon(icon, color: accent, size: 18), const SizedBox(width: 8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 3), Text(label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Color(0xFF9DBDDC), fontSize: 9)),
            ]))]),
          );
          return Wrap(spacing: gap, runSpacing: gap, children: [
            stat('Managed datasets', datasets.length.toString(), Icons.dataset_outlined, const Color(0xFF00CFFF)),
            stat('Catalog resources', catalogError == null ? catalog.length.toString() : '—', Icons.storage_outlined, const Color(0xFF168BFF)),
            stat('Access requests', requestsError == null ? requests.length.toString() : '—', Icons.pending_actions_outlined, const Color(0xFFFFB454)),
            stat('People in scope', members.length.toString(), Icons.groups_outlined, const Color(0xFF00D89A)),
          ]);
        }),
        const SizedBox(height: 14),
        Wrap(spacing: 10, runSpacing: 9, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const SizedBox(height: 10),
        _eye('RESOURCE SEARCH'),
        LayoutBuilder(builder: (context, constraints) => SizedBox(width: constraints.maxWidth < 350 ? constraints.maxWidth : 320, child: TextField(onChanged: (v) => setState(() => search = v), style: const TextStyle(color: TechColors.textPrimary, fontSize: 12), decoration: InputDecoration(hintText: 'Search managed resources', prefixIcon: const Icon(Icons.search, size: 16), isDense: true, suffixIcon: (search ?? '').isEmpty ? null : IconButton(tooltip: 'Clear search', onPressed: () => setState(() => search = ''), icon: const Icon(Icons.close, size: 16)))))),
        SizedBox(width: 150, child: DropdownButtonFormField<String>(
          value: _sortBy,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Sort by', isDense: true),
          items: const [
            DropdownMenuItem(value: 'newest', child: Text('Newest first')),
            DropdownMenuItem(value: 'name', child: Text('Name A–Z')),
            DropdownMenuItem(value: 'status', child: Text('Status')),
          ],
          onChanged: (value) => setState(() => _sortBy = value ?? 'newest'),
        )),
        SizedBox(width: 145, child: DropdownButtonFormField<String>(
          value: _statusFilter,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Status', isDense: true),
          items: const [
            DropdownMenuItem(value: 'all', child: Text('All statuses')),
            DropdownMenuItem(value: 'ready', child: Text('Ready')),
            DropdownMenuItem(value: 'processing', child: Text('Processing')),
            DropdownMenuItem(value: 'uploading', child: Text('Uploading')),
            DropdownMenuItem(value: 'pending', child: Text('Pending')),
            DropdownMenuItem(value: 'failed', child: Text('Failed')),
          ],
          onChanged: (value) => setState(() => _statusFilter = value ?? 'all'),
        )),
        if (locationOptions.isNotEmpty)
          SizedBox(width: 170, child: DropdownButtonFormField<String>(
            value: locationOptions.containsKey(_locationFilter) || _locationFilter == 'all' ? _locationFilter : 'all',
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Branch', isDense: true),
            items: [
              const DropdownMenuItem(value: 'all', child: Text('All branches')),
              ...locationOptions.entries.map((entry) => DropdownMenuItem(value: entry.key, child: Text(entry.value, overflow: TextOverflow.ellipsis))),
            ],
            onChanged: (value) => setState(() => _locationFilter = value ?? 'all'),
          )),
        if (!widget.readOnly && widget.canRunAnalysis)
          _action('OPEN AI ANALYTICS', Icons.auto_awesome,
            () => openInsightFlowAnalysis(context, initialView: 'AI_ANALYTICS', authorized: widget.canRunAnalysis && !widget.readOnly),
            active: true),
        if (canManage) _action('MANAGER UPLOAD GRANTS', Icons.admin_panel_settings_outlined, _grantManagerUpload),
        if (canManage) _action('REVOKE MANAGER UPLOAD', Icons.remove_moderator_outlined, _revokeManagerUpload),
        if (canUpload) _action('IMPORT CSV', Icons.file_upload_outlined, () => _upload(), active: true),
        _action('REFRESH', Icons.refresh, _load),
        ]),
      ])),
      if (!widget.readOnly &&
          (_can('dataset.proposal.submit') || _can('dataset.proposal.review'))) ...[
        const SizedBox(height: 12),
        _proposalPanel(),
      ],
      const SizedBox(height: 12),
      _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(filtered.length.toString() + (filtered.length == 1 ? ' managed resource' : ' managed resources'), style: const TextStyle(color: TechColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w700)), const SizedBox(height: 8),
        if (filtered.isEmpty) Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Text(
            datasets.isEmpty && q.isEmpty && _statusFilter == 'all' && _locationFilter == 'all'
                ? 'No managed resources are available in this authorized scope yet.'
                : 'No resources match the current search and filters. Clear a filter or try another term.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4),
          ),
        ),
        ...filtered.map((d) {
          final sel = d['dataset_id']?.toString() == selected?['dataset_id']?.toString();
          return Padding(padding: const EdgeInsets.only(bottom: 6), child: GlassContainer(useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass, shape: const LiquidRoundedSuperellipse(borderRadius: 13), padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9), child: InkWell(onTap: () => _select(d), borderRadius: BorderRadius.circular(13), child: Row(children: [
            Icon(sel ? Icons.dataset_rounded : Icons.insert_drive_file_outlined, size: 16, color: sel ? TechColors.borderActive : TechColors.textMuted), const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(_name(d), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: TechColors.textPrimary, fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(_displayStatus(d) + ' · ' + (d['row_count'] ?? '—').toString() + ' ROWS · ' + (d['column_count'] ?? '—').toString() + ' COLUMNS · ' + (d['current_version'] ?? '—').toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 8, fontFamily: 'monospace')),
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
        _stat('ROWS', (d['row_count'] ?? '—').toString()), _stat('COLUMNS', (d['column_count'] ?? '—').toString()), _stat('VERSION', (d['current_version'] ?? '—').toString()), _stat('STATUS', _displayStatus(d)),
        if (canCopy) _action('COPY DATASET', Icons.copy_outlined, _startWorking, active: true),
        if (canViewOriginal) ...[
          if (!widget.readOnly && widget.canRunAnalysis)
            _action('OPEN AI ANALYTICS', Icons.auto_awesome, _startWorking, active: true),
          _action('DOWNLOAD CSV', Icons.download_outlined, _download),
          if (canUpload && (!_requiresManagerUploadGrant || _managerHasUploadGrantFor(d)))
            _action('NEW VERSION', Icons.upload_file_outlined, () => _upload(datasetId: d['dataset_id']?.toString())),
          if (!widget.readOnly && _requiresManagerUploadGrant && _managerHasUploadGrantFor(d))
            _action('SUBMIT PROPOSAL', Icons.rate_review_outlined, () => _submitProposal(d['dataset_id']?.toString() ?? ''), active: true),
          if (canDelete) _action('DELETE', Icons.delete_outline, _deleteDataset),
        ],
      ])),
      const SizedBox(height: 12),
      if (canViewOriginal) _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
      if (!widget.readOnly && (_can('dataset.copy.request') ||
          _can('dataset.copy_requests.review') ||
          _can('dataset.upload_grants.manage'))) ...[
        const SizedBox(height: 12),
        _accessPanel(),
        const SizedBox(height: 12),
      ],
      _surface(Wrap(spacing: 8, runSpacing: 8, children: [
        _action('BACK TO DATASETS', Icons.arrow_back, () => setState(() {
          selected = null;
          profile = null;
          rows = [];
        })),
      ])),
    ]);
  }

  Widget _proposalPanel() => _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Original dataset proposals', style: TextStyle(color: TechColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
    const SizedBox(height: 4),
    Text(_can('dataset.proposal.review') ? 'Review proposals only for branches currently assigned to you.' : 'Your proposals remain private until the assigned Branch Head reviews them.', style: const TextStyle(color: TechColors.textMuted, fontSize: 10, height: 1.4)),
    const SizedBox(height: 9),
    if (proposalsError != null) Text(proposalsError!, style: const TextStyle(color: TechColors.statusRed, fontSize: 10)),
    if (proposals.isEmpty && proposalsError == null) const Text('No proposals in your authorized scope.', style: TextStyle(color: TechColors.textMuted, fontSize: 10)),
    ...proposals.map((p) {
      final status = (p['status']?.toString() ?? 'pending').toLowerCase();
      final pending = status == 'pending' || status == 'submitted';
      final statusLabel = switch (status) {
        'draft' => 'DRAFT',
        'submitted' => 'SUBMITTED',
        'pending' => 'AWAITING BRANCH HEAD APPROVAL',
        'approved' => 'APPROVED',
        'rejected' => 'REJECTED',
        _ => status.replaceAll('_', ' ').toUpperCase(),
      };
      final canReview = _can('dataset.proposal.review') && pending;
      final rejection = p['decision_note']?.toString();
      return Padding(padding: const EdgeInsets.only(bottom: 7), child: GlassContainer(
        useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass,
        shape: const LiquidRoundedSuperellipse(borderRadius: 11), padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.fact_check_outlined, color: Color(0xFF43C8F3), size: 17), const SizedBox(width: 8),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((p['original_filename'] ?? p['dataset_id'] ?? 'Dataset proposal').toString(), style: const TextStyle(color: TechColors.textPrimary, fontSize: 10, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text('STATUS: ' + statusLabel + ' · BASE: ' + (p['base_version_id'] ?? '—').toString(), style: const TextStyle(color: TechColors.textMuted, fontSize: 8, fontFamily: 'monospace')),
            ])),
            if (canReview) ...[
              _action('APPROVE', Icons.check, () => _decideProposal(p['proposal_id'].toString(), true), active: true),
              const SizedBox(width: 5),
              _action('REJECT', Icons.close, () => _decideProposal(p['proposal_id'].toString(), false)),
            ],
          ]),
          if (rejection != null && rejection.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Review note: ' + rejection, style: const TextStyle(color: TechColors.textMuted, fontSize: 10))),
        ]),
      ));
    }),
    Align(alignment: Alignment.centerRight, child: _action('REFRESH PROPOSALS', Icons.refresh, _loadProposals)),
  ]));

  Widget _stat(String label, String value) => GlassContainer(useOwnLayer: true, quality: GlassQuality.minimal, settings: TechColors.panelGlass, shape: const LiquidRoundedSuperellipse(borderRadius: 11), padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_eye(label), const SizedBox(height: 2), Text(value, style: const TextStyle(color: TechColors.textPrimary, fontSize: 10, fontWeight: FontWeight.w700, fontFamily: 'monospace'))]));

  Widget _accessPanel() => _surface(Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    const Text('Dataset authorization workflow', style: TextStyle(color: TechColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
    const SizedBox(height: 5),
    const Text('The assigned Branch Head manages the trusted branch original. Managers may publish only when they hold an active explicit upload grant for the exact branch; otherwise changes remain proposals. Organization Owners have organization-wide read and oversight access, not branch master-data write authority. Team Leads and employees work only on individually authorized copies.', style: TextStyle(color: TechColors.textMuted, fontSize: 11, height: 1.4)),
    const SizedBox(height: 10),
    if (_can('dataset.copy.request')) ...[
      const Text('BRANCH DATA CATALOG', style: TextStyle(color: TechColors.borderActive, fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
      const SizedBox(height: 6),
      if (catalogError != null)
        Row(children: [
          const Expanded(child: Text('The branch catalog could not be loaded. Retry this section without reloading the dataset list.', style: TextStyle(color: TechColors.statusRed, fontSize: 10))),
          _action('RETRY', Icons.refresh, _loadCatalog, active: true),
        ])
      else if (catalog.isEmpty)
        const Text('No copyable datasets are available in your authorized scope.', style: TextStyle(color: TechColors.textMuted, fontSize: 10)),
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
    if (_can('dataset.copy_requests.review')) ...[
      const Text('PENDING / RECENT REQUESTS', style: TextStyle(color: TechColors.borderActive, fontSize: 9, fontWeight: FontWeight.w700, fontFamily: 'monospace')),
      const SizedBox(height: 6),
      if (requestsError != null)
        Row(children: [
          const Expanded(child: Text('Copy requests could not be loaded. Retry this section without hiding the dataset list.', style: TextStyle(color: TechColors.statusRed, fontSize: 10))),
          _action('RETRY', Icons.refresh, _loadCopyRequests, active: true),
        ])
      else if (requests.isEmpty)
        const Text('No copy authorization requests.', style: TextStyle(color: TechColors.textMuted, fontSize: 10)),
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
}
