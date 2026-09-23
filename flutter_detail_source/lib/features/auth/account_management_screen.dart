import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:http/http.dart' as http;
import '../../core/auth/authenticated_http.dart';
import 'dart:convert';

import '../../app_colors.dart';
import '../../core/auth/insightflow_auth_service.dart';
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
    final user = InsightFlowAuthService.currentUser;
    _nameController.text = user?.displayName ?? '';
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
    try {
      if (InsightFlowAuthService.hasProvider('password')) {
        final controller = TextEditingController();
        final password = await showCupertinoDialog<String>(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Recent authentication required'),
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
        await InsightFlowAuthService.reauthenticateWithPassword(password);
        return true;
      }

      if (InsightFlowAuthService.hasProvider('google.com')) {
        await InsightFlowAuthService.reauthenticateWithGoogle();
        return true;
      }

      _setMessage(
        'This account does not have a supported reauthentication method.',
        error: true,
      );
      return false;
    } catch (error) {
      _setMessage(
        InsightFlowAuthService.userFacingAuthError(error),
        error: true,
      );
      return false;
    }
  }

  Future<void> _saveProfile() async {
    final name = _nameController.text.trim();
    final email = _emailController.text.trim();
    final user = InsightFlowAuthService.currentUser;
    if (user == null) return;

    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (name != (user.displayName ?? '')) {
        await InsightFlowAuthService.updateProfile(
          displayName: name.isEmpty ? null : name,
        );
      }
      if (email.isNotEmpty && email != (user.email ?? '')) {
        if (!await _reauthenticate()) return;
        await InsightFlowAuthService.verifyBeforeUpdateEmail(email);
        _setMessage(
          'A verification email was sent to the new address. The change applies after verification.',
        );
      } else {
        _setMessage('Profile updated.');
      }
    } catch (error) {
      _setMessage(
        InsightFlowAuthService.userFacingAuthError(error),
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
      await InsightFlowAuthService.changePassword(password);
      _newPasswordController.clear();
      _confirmPasswordController.clear();
      _setMessage('Password changed successfully.');
    } catch (error) {
      _setMessage(
        InsightFlowAuthService.userFacingAuthError(error),
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
            'This permanently deletes your Firebase Authentication account. '
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
      final token = await InsightFlowAuthService.getIdToken(forceRefresh: true);
      final cleanup = await http.post(
        Uri.parse('$insightFlowBackendBaseUrl/v1/authz/account/cleanup'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          if (insightFlowWorkspaceId.isNotEmpty)
            'X-InsightFlow-Workspace-ID': insightFlowWorkspaceId,
        },
        body: jsonEncode({
          'uid': InsightFlowAuthService.currentUser?.uid,
        }),
      );
      if (cleanup.statusCode != 200) {
        throw StateError(
          'Authorization cleanup could not be completed. The account was not deleted.',
        );
      }
      await InsightFlowAuthService.deleteAccount();
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      _setMessage(
        InsightFlowAuthService.userFacingAuthError(error),
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
    final user = InsightFlowAuthService.currentUser;

    return AuthGlassScaffold(
      title: 'ACCOUNT / PROFILE',
      subtitle: user?.email ?? 'Firebase account',
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
          onPressed: _busy ? null : InsightFlowAuthService.signOut,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
