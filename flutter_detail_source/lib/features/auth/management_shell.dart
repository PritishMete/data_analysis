import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
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
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.transparent,
    extendBodyBehindAppBar: true,
    body: LiquidGlassScope(
      child: Stack(
        children: [
          Positioned.fill(
            child: GlassBackgroundSource(
              child: const TechAnimatedBackground(),
            ),
          ),
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
                              ? const Padding(
                                  padding: EdgeInsets.only(top: 30),
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      color: TechColors.borderActive,
                                    ),
                                  ),
                                )
                              : error != null
                                  ? GlassCard(
                                      padding: const EdgeInsets.all(16),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(
                                            Icons.error_outline_rounded,
                                            color: TechColors.statusRed,
                                            size: 22,
                                          ),
                                          const SizedBox(height: 8),
                                          _eyebrow('MANAGEMENT SERVICE ERROR'),
                                          const SizedBox(height: 6),
                                          Text(
                                            error!,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                              color: TechColors.textPrimary,
                                              height: 1.4,
                                            ),
                                          ),
                                          const SizedBox(height: 14),
                                          _actionChip(
                                            'RETRY',
                                            Icons.refresh_rounded,
                                            loadAll,
                                            accent: true,
                                          ),
                                        ],
                                      ),
                                    )
                                  : Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _title(
                                          _sectionLabel(section),
                                          detail: _sectionDetail(section),
                                          icon: _sectionIcon(section),
                                        ),
                                        const SizedBox(height: 16),
                                        body(),
                                        if (section ==
                                            ManagementSection.organization) ...[
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
        ],
      ),
    ),
  );
}
