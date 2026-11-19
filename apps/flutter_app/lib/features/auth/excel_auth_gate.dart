import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/auth/supabase_auth_service.dart';
import '../../core/interop/excel_auth_bridge.dart';

const _excelApiBase = String.fromEnvironment(
  'INSIGHTFLOW_BACKEND_URL',
  defaultValue: 'https://data-analysis-oajs.onrender.com',
);

String _secureId([int bytes = 32]) {
  final random = Random.secure();
  final values = List<int>.generate(bytes, (_) => random.nextInt(256));
  return base64UrlEncode(values).replaceAll('=', '');
}

class ExcelAuthGate extends StatefulWidget {
  const ExcelAuthGate({super.key});

  @override
  State<ExcelAuthGate> createState() => _ExcelAuthGateState();
}

class _ExcelAuthGateState extends State<ExcelAuthGate> {
  Map<String, dynamic>? _transaction;
  Map<String, dynamic>? _status;
  Timer? _pollTimer;
  bool _busy = true;
  bool _polling = false;
  bool _claiming = false;
  String? _error;
  String? _notice;

  String get _handoffUrl {
    final base = Uri.parse(InsightFlowSupabaseConfig.authRedirectUrl);
    return base.replace(queryParameters: {
      'excelHandoff': _transaction!['transaction_id'].toString(),
    }).toString();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Map<String, String> extraHeaders = const {},
  }) async {
    final response = await http
        .post(
          Uri.parse('$_excelApiBase/v2/excel-auth/handoff/$path'),
          headers: {'Content-Type': 'application/json', ...extraHeaders},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    Map<String, dynamic> payload = {};
    try {
      payload = jsonDecode(response.body) as Map<String, dynamic>;
    } catch (_) {}
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        (payload['detail'] ?? 'Excel sign-in could not continue.').toString(),
      );
    }
    return payload;
  }

  Future<void> _initialize() async {
    try {
      final session = await InsightFlowSupabaseAuthService.ensureSession(
        timeout: const Duration(seconds: 8),
      );
      if (session != null) {
        final user = await InsightFlowSupabaseAuthService.fetchAuthoritativeUser(
          timeout: const Duration(seconds: 8),
        );
        if (user != null && user.emailConfirmedAt != null) {
          if (mounted) setState(() {
            _busy = false;
            _notice = 'Your existing InsightFlow session is verified.';
          });
          return;
        }
      }
    } catch (_) {
      // An unavailable/stale session must not prevent a fresh Excel login.
    }

    try {
      final saved = ExcelAuthBridge.loadExcelTransaction();
      if (saved.isNotEmpty) {
        final restored = jsonDecode(saved) as Map<String, dynamic>;
        if (restored['claim_attempted'] == true) {
          // The claim endpoint is at-most-once. Never replay after a reload.
          ExcelAuthBridge.clearExcelTransaction();
        } else {
          _transaction = restored;
        }
      }
      if (_transaction == null) {
        final created = await _post('create', {
          'excel_instance_id': _secureId(),
        }, extraHeaders: {'Idempotency-Key': _secureUuid()});
        _transaction = created;
        _persistTransaction();
      }
      if (mounted) setState(() => _busy = false);
      _startPolling();
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  void _persistTransaction() {
    final value = _transaction;
    if (value != null) {
      ExcelAuthBridge.saveExcelTransaction(jsonEncode(value));
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _pollStatus(),
    );
    _pollStatus();
  }

  Future<void> _pollStatus() async {
    if (_polling || _claiming || _transaction == null || !mounted) return;
    _polling = true;
    try {
      final result = await _post('status', {
        'transaction_id': _transaction!['transaction_id'],
        'status_capability': _transaction!['status_capability'],
      });
      if (!mounted) return;
      setState(() => _status = result);
      final state = result['status'];
      if (state == 'completed') {
        await _claimSession(result);
      } else if (state == 'rejected' ||
          state == 'cancelled' ||
          state == 'expired' ||
          state == 'failed') {
        _pollTimer?.cancel();
        setState(() => _error = 'This sign-in request $state. Start a new sign-in.');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString().replaceFirst('Bad state: ', ''));
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _approve(String decision) async {
    if (_transaction == null || _status == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _post('approve', {
        'transaction_id': _transaction!['transaction_id'],
        'approval_capability': _transaction!['approval_capability'],
        'candidate_uid': _status!['candidate_uid'],
        'generation': _status!['candidate_generation'],
        'decision': decision,
        'request_id': _secureUuid(),
      });
      if (decision == 'reject') {
        _pollTimer?.cancel();
        ExcelAuthBridge.clearExcelTransaction();
        setState(() {
          _transaction = null;
          _status = null;
          _busy = false;
          _error = 'You rejected this account. Start a new sign-in to choose another account.';
        });
      } else {
        setState(() {
          _busy = false;
          _notice = 'Account approved. Waiting for the browser to finish securely…';
        });
      }
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  String _secureUuid() {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _claimSession(Map<String, dynamic> status) async {
    if (_claiming || _transaction == null) return;
    _claiming = true;
    _pollTimer?.cancel();
    final approvedUid = status['approved_uid']?.toString();
    final generation = status['approved_generation'];
    _transaction!['claim_attempted'] = true;
    _persistTransaction();
    try {
      final result = await _post('claim', {
        'transaction_id': _transaction!['transaction_id'],
        'claim_capability': _transaction!['claim_capability'],
      });
      final refreshToken = result['refresh_token']?.toString() ?? '';
      if (refreshToken.isEmpty) throw StateError('Excel did not receive a valid session.');
      final response = await InsightFlowSupabaseAuthService.client.auth
          .setSession(refreshToken)
          .timeout(const Duration(seconds: 20));
      final session = response.session;
      if (session == null) throw StateError('Supabase did not establish the Excel session.');
      final userResponse = await InsightFlowSupabaseAuthService.client.auth
          .getUser(session.accessToken)
          .timeout(const Duration(seconds: 12));
      final verifiedUser = userResponse.user;
      if (approvedUid == null ||
          verifiedUser == null ||
          verifiedUser.id != approvedUid ||
          generation != status['generation'] ||
          generation != _transaction!['generation']) {
        await InsightFlowSupabaseAuthService.signOutCurrentDevice();
        throw StateError('The claimed session did not match the account approved in Excel.');
      }
      ExcelAuthBridge.clearExcelTransaction();
      if (mounted) setState(() {
        _notice = 'Excel sign-in verified. Opening InsightFlow…';
        _busy = false;
        _transaction = null;
      });
    } catch (error) {
      // Claim is irreversible even if the response was lost or local session
      // establishment failed. Never replay it; require a fresh transaction.
      await InsightFlowSupabaseAuthService.signOutCurrentDevice();
      ExcelAuthBridge.clearExcelTransaction();
      if (mounted) setState(() {
        _transaction = null;
        _status = null;
        _busy = false;
        _error = 'The one-time session claim could not be completed. Start a new sign-in. ${error.toString().replaceFirst('Bad state: ', '')}';
      });
    } finally {
      _claiming = false;
    }
  }


  Future<void> _cancelHandoff() async {
    _pollTimer?.cancel();
    final current = _transaction;
    if (current != null) {
      try {
        await _post('cancel', {
          'transaction_id': current['transaction_id'],
          'cancel_capability': current['cancel_capability'],
        });
      } catch (_) {
        // Local cancellation still clears this instance's capabilities.
      }
    }
    ExcelAuthBridge.clearExcelTransaction();
    if (mounted) setState(() {
      _transaction = null;
      _status = null;
      _busy = false;
      _error = null;
      _notice = 'Excel sign-in cancelled. You can start again when ready.';
    });
  }

  Future<void> _startNewTransaction() async {
    _pollTimer?.cancel();
    ExcelAuthBridge.clearExcelTransaction();
    if (mounted) setState(() {
      _busy = true;
      _transaction = null;
      _status = null;
      _error = null;
      _notice = null;
    });
    try {
      final created = await _post('create', {'excel_instance_id': _secureId()},
          extraHeaders: {'Idempotency-Key': _secureUuid()});
      _transaction = created;
      _persistTransaction();
      if (mounted) setState(() => _busy = false);
      _startPolling();
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _copyBrowserLink() async {
    try {
      await ExcelAuthBridge.copyText(_handoffUrl);
      if (mounted) setState(() => _notice = 'Browser sign-in link copied. Open it in Chrome or Edge.');
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _openDialog() async {
    try {
      final uri = Uri.parse(_handoffUrl).replace(queryParameters: {
        'excelHandoff': _transaction!['transaction_id'].toString(),
        'excelAuthDialog': '1',
      });
      await ExcelAuthBridge.openOfficeDialog(uri.toString());
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _retry() async {
    if (_transaction == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _post('retry', {
        'transaction_id': _transaction!['transaction_id'],
        'retry_capability': _transaction!['retry_capability'],
        'request_id': _secureUuid(),
      });
      _transaction!['pairing_code'] = result['pairing_code'];
      _transaction!['generation'] = result['generation'];
      _transaction!['claim_attempted'] = false;
      _status = null;
      _persistTransaction();
      if (mounted) setState(() {
        _busy = false;
        _notice = 'A new pairing code is ready. Use it in the browser.';
      });
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_busy) {
      return const _ExcelStatus(
        title: 'Checking your InsightFlow sign-in…',
        detail: 'Your Excel session is being verified.',
        busy: true,
      );
    }
    final candidate = _status?['candidate_uid'] != null &&
        _status?['status'] == 'candidate_pending_approval';
    return _ExcelStatus(
      title: candidate ? 'Approve this InsightFlow account' : 'Connect InsightFlow to Excel',
      detail: candidate
          ? 'The browser signed in as ${_status?['candidate_email'] ?? 'an InsightFlow account'}. Confirm that this is the account you want to use.'
          : 'Open the link in Chrome or Edge, enter the pairing code, and sign in. Excel will continue after you approve the verified account.',
      error: _error,
      notice: _notice,
      pairingCode: _transaction?['pairing_code']?.toString(),
      browserLink: _transaction == null ? null : _handoffUrl,
      onCopyLink: _transaction == null ? null : _copyBrowserLink,
      onOpenDialog: _transaction == null ? null : _openDialog,
      onApprove: candidate ? () => _approve('approve') : null,
      onReject: candidate ? () => _approve('reject') : null,
      onRetry: _transaction != null &&
              _status?['candidate_uid'] == null &&
              const ['pending', 'browser_bound'].contains(_status?['status'])
          ? _retry
          : null,
      onNew: _transaction == null || _status?['status'] == 'expired' || _error != null ? _startNewTransaction : null,
      onCancel: _transaction != null && _status?['status'] != 'completed' ? _cancelHandoff : null,
    );
  }
}

class ExcelAuthBrowserGate extends StatefulWidget {
  const ExcelAuthBrowserGate({super.key});

  @override
  State<ExcelAuthBrowserGate> createState() => _ExcelAuthBrowserGateState();
}

class _ExcelAuthBrowserGateState extends State<ExcelAuthBrowserGate> {
  final _pairing = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resumeOAuth());
  }

  @override
  void dispose() {
    _pairing.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Map<String, dynamic> _browserConfig() => {
        'transactionId': ExcelAuthBridge.browserHandoffId,
        'pairingCode': _pairing.text.trim().toUpperCase(),
        'generation': 1,
        'supabaseUrl': InsightFlowSupabaseConfig.url,
        'publishableKey': InsightFlowSupabaseConfig.publishableKey,
        'apiBase': _excelApiBase,
      };

  Future<void> _resumeOAuth() async {
    if (ExcelAuthBridge.browserHandoffId.isEmpty) return;
    try {
      setState(() {
        _busy = true;
        _error = null;
        _notice = 'Verifying the Google sign-in callback…';
      });
      final resumed = await ExcelAuthBridge.resumeOAuth();
      if (resumed && mounted) {
        setState(() => _notice = 'Account submitted. Waiting for approval in Excel…');
      } else if (mounted) {
        setState(() {
          _busy = false;
          _notice = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  Future<void> _google() async {
    if (_pairing.text.trim().isEmpty) {
      setState(() => _error = 'Enter the pairing code shown in Excel first.');
      return;
    }
    try {
      ExcelAuthBridge.prepareBrowser(jsonEncode(_browserConfig()));
      await ExcelAuthBridge.startGoogle();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _passwordLogin() async {
    if (_pairing.text.trim().isEmpty || _email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter the Excel pairing code, email and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = 'Verifying your InsightFlow account…';
    });
    try {
      ExcelAuthBridge.prepareBrowser(jsonEncode(_browserConfig()));
      await ExcelAuthBridge.passwordSignIn(jsonEncode({
        ..._browserConfig(),
        'email': _email.text.trim(),
        'password': _password.text,
      }));
      if (mounted) setState(() => _notice = 'Account submitted. Waiting for approval in Excel…');
    } catch (error) {
      if (mounted) setState(() {
        _busy = false;
        _error = error.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return _ExcelStatus(
      title: 'Sign in to InsightFlow',
      detail: 'Enter the pairing code displayed in Excel. Your password and session tokens are sent only to Supabase and the protected handoff API.',
      error: _error,
      notice: _notice,
      busy: _busy,
      child: Column(
        children: [
          TextField(
            controller: _pairing,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(labelText: 'Excel pairing code'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (_) => _passwordLogin(),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _busy ? null : _passwordLogin,
            child: const Text('Continue with email'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _google,
            child: const Text('Continue with Google'),
          ),
        ],
      ),
    );
  }
}

class _ExcelStatus extends StatelessWidget {
  const _ExcelStatus({
    required this.title,
    required this.detail,
    this.busy = false,
    this.error,
    this.notice,
    this.pairingCode,
    this.browserLink,
    this.onCopyLink,
    this.onOpenDialog,
    this.onApprove,
    this.onReject,
    this.onRetry,
    this.onNew,
    this.onCancel,
    this.child,
  });

  final String title;
  final String detail;
  final bool busy;
  final String? error;
  final String? notice;
  final String? pairingCode;
  final String? browserLink;
  final VoidCallback? onCopyLink;
  final VoidCallback? onOpenDialog;
  final VoidCallback? onApprove;
  final VoidCallback? onReject;
  final VoidCallback? onRetry;
  final VoidCallback? onNew;
  final VoidCallback? onCancel;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050B18),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 38, color: Color(0xFF55D6E8)),
                  const SizedBox(height: 20),
                  Text(title, textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white, fontSize: 19, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 10),
                  Text(detail, textAlign: TextAlign.center,
                    style: const TextStyle(color: Color(0xFF9BAAC1), fontSize: 13, height: 1.5)),
                  if (error != null) ...[
                    const SizedBox(height: 14),
                    Text(error!, textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFFFF8B8B), fontSize: 12)),
                  ],
                  if (notice != null) ...[
                    const SizedBox(height: 12),
                    Text(notice!, textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF79DCCB), fontSize: 12)),
                  ],
                  if (busy) ...[
                    const SizedBox(height: 22),
                    const CircularProgressIndicator(color: Color(0xFF55D6E8)),
                  ],
                  if (pairingCode != null) ...[
                    const SizedBox(height: 20),
                    const Text('PAIRING CODE', style: TextStyle(color: Color(0xFF9BAAC1), fontSize: 10, letterSpacing: 1.4)),
                    const SizedBox(height: 6),
                    SelectableText(pairingCode!,
                      style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  ],
                  if (browserLink != null) ...[
                    const SizedBox(height: 12),
                    SelectableText(browserLink!, textAlign: TextAlign.center,
                      style: const TextStyle(color: Color(0xFF9BAAC1), fontSize: 11)),
                    const SizedBox(height: 8),
                    OutlinedButton(onPressed: onCopyLink, child: const Text('Copy browser sign-in link')),
                    OutlinedButton(onPressed: onOpenDialog, child: const Text('Use Excel sign-in window instead')),
                  ],
                  if (child != null) ...[
                    const SizedBox(height: 12),
                    child!,
                  ],
                  if (onApprove != null) ...[
                    const SizedBox(height: 18),
                    FilledButton(onPressed: onApprove, child: const Text('Approve this account')),
                    TextButton(onPressed: onReject, child: const Text('Reject and choose another account')),
                  ],
                  if (onRetry != null) ...[
                    const SizedBox(height: 10),
                    OutlinedButton(onPressed: onRetry, child: const Text('Generate a new pairing code')),
                  ],
                  if (onNew != null) ...[
                    const SizedBox(height: 10),
                    OutlinedButton(onPressed: onNew, child: const Text('Start a new sign-in')),
                  ],
                  if (onCancel != null) ...[
                    const SizedBox(height: 10),
                    TextButton(onPressed: onCancel, child: const Text('Cancel Excel sign-in')),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
