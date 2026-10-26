import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:http/http.dart' as http;
import '../../core/auth/authenticated_http.dart';
import 'dart:convert';

import '../../core/auth/supabase_auth_service.dart';
import 'auth_glass_widgets.dart';

class AccountManagementScreen extends StatefulWidget {
  const AccountManagementScreen({super.key});

  @override
  State<AccountManagementScreen> createState() => _AccountManagementScreenState();
}

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _busy = false;
  String? _message;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    _nameController.text = user?.userMetadata?['display_name']?.toString() ?? '';
    _emailController.text = user?.email ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _setMessage(String value, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = value;
      _error = error;
    });
  }

  Future<bool> _reauthenticate() async {
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    if (user == null) {
      _setMessage('Sign in again before changing account security settings.', error: true);
      return false;
    }

    final provider = user.appMetadata['provider']?.toString().toLowerCase();
    if (provider != 'email') {
      _setMessage(
        'For this account provider, reauthenticate by signing out and signing in again before retrying this change.',
        error: true,
      );
      return false;
    }

    final controller = TextEditingController();
    final password = await showCupertinoDialog<String>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Confirm your identity'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(
            controller: controller,
            obscureText: true,
            placeholder: 'Current password',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (password == null || password.isEmpty) return false;

    try {
      await InsightFlowSupabaseAuthService.signInWithPassword(
        email: user.email ?? '',
        password: password,
      );
      return true;
    } catch (_) {
      _setMessage('Current password could not be verified.', error: true);
      return false;
    }
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;
    if (user == null) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (name != (user.userMetadata?['display_name']?.toString() ?? '')) {
        await InsightFlowSupabaseAuthService.client.auth.updateUser(
          UserAttributes(data: {'display_name': name}),
        );
      }
      if (email.isNotEmpty && email != (user.email ?? '')) {
        if (!await _reauthenticate()) return;
        await InsightFlowSupabaseAuthService.client.auth.updateUser(
          UserAttributes(email: email),
        );
        _setMessage(
          'A verification email was sent to the new address. The change applies after verification.',
        );
      } else {
        _setMessage('Profile updated.');
      }
    } catch (error) {
      _setMessage(
        'The profile update could not be completed. Please try again.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _changePassword() async {
    final password = _newPasswordController.text;
    if (password.length < 6 ||
        password != _confirmPasswordController.text) {
      _setMessage(
        'Enter matching passwords with at least 6 characters.',
        error: true,
      );
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await _reauthenticate()) return;
      await InsightFlowSupabaseAuthService.setPassword(password);
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      _setMessage('Password changed successfully.');
    } catch (error) {
      _setMessage(
        'The password change could not be completed. Please try again.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete account?'),
        content: const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'This permanently deletes your InsightFlow account and revokes its organization access. '
            'It does not create replacement organization access.',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (!await _reauthenticate()) return;
      final token = InsightFlowSupabaseAuthService.accessToken;
      if (token == null || token.isEmpty) throw StateError('Sign-in required.');
      final cleanup = await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/account/cleanup'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          if (insightFlowWorkspaceId.isNotEmpty)
            'X-InsightFlow-Workspace-ID': insightFlowWorkspaceId,
        },
        body: jsonEncode({
          'uid': InsightFlowSupabaseAuthService.currentSupabaseUser?.id,
        }),
      );
      if (cleanup.statusCode != 200) {
        throw StateError(
          'Authorization cleanup could not be completed. The account was not deleted.',
        );
      }
      await InsightFlowSupabaseAuthService.signOut();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _setMessage(
        'The account could not be deleted. Organization access was not intentionally bypassed.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final passwordQuality =
        GlassThemeData.of(context).qualityFor(context) ?? GlassQuality.standard;
    final user = InsightFlowSupabaseAuthService.currentSupabaseUser;

    return AuthGlassScaffold(
      title: 'ACCOUNT / PROFILE',
      subtitle: user?.email ?? 'Supabase account',
      children: [
        const AuthGlassFieldLabel('Display name'),
        GlassTextField(
          controller: _nameController,
          placeholder: 'Display name',
          enabled: !_busy,
        ),
        const SizedBox(height: 12),
        const AuthGlassFieldLabel('Email'),
        GlassTextField(
          controller: _emailController,
          placeholder: 'Email',
          keyboardType: TextInputType.emailAddress,
          enabled: !_busy,
        ),
        const SizedBox(height: 14),
        GlassButton.custom(
          onTap: _busy ? () {} : _saveProfile,
          enabled: !_busy,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Save profile',
          child: const Text(
            'Save profile',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 18),
        const AuthGlassFieldLabel('Change password'),
        GlassPasswordField(
          controller: _newPasswordController,
          placeholder: 'New password',
          enabled: !_busy,
          quality: passwordQuality,
        ),
        const SizedBox(height: 8),
        GlassPasswordField(
          controller: _confirmPasswordController,
          placeholder: 'Confirm new password',
          enabled: !_busy,
          quality: passwordQuality,
        ),
        const SizedBox(height: 10),
        GlassButton.custom(
          onTap: _busy ? () {} : _changePassword,
          enabled: !_busy,
          width: double.infinity,
          height: 44,
          shape: const LiquidRoundedSuperellipse(borderRadius: 14),
          label: 'Change password',
          child: const Text(
            'Change password',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        if (_message != null) ...[
          const SizedBox(height: 12),
          AuthGlassMessage(text: _message!, error: _error),
        ],
        const SizedBox(height: 18),
        TextButton(
          onPressed: _busy ? null : _deleteAccount,
          child: const Text(
            'Delete account',
            style: TextStyle(color: CupertinoColors.destructiveRed),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : InsightFlowSupabaseAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
