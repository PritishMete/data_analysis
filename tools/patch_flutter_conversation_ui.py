from pathlib import Path

PATH = Path('flutter_detail_source/lib/detail_analysis_main.dart')
text = PATH.read_text(encoding='utf-8')
original = text


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected exactly 1 anchor, found {count}')
    text = text.replace(old, new, 1)


replace_once(
    "import 'core/services/chat_reasoning_service.dart';\n",
    "import 'core/services/chat_reasoning_service.dart';\nimport 'core/services/conversation_state_service.dart';\n",
    'conversation service import',
)
replace_once(
    "import 'widgets/analyst_chart.dart';\n",
    "import 'widgets/analyst_chart.dart';\nimport 'widgets/analyst_suggestions.dart';\n",
    'suggestion widget import',
)
replace_once(
    "  final _service = PowerBiDetailAnalysisService();\n  final _reasoningService = ChatReasoningService();\n",
    "  final _service = PowerBiDetailAnalysisService();\n  final _reasoningService = ChatReasoningService();\n  final _conversationService = ConversationStateService();\n  final String _conversationSessionId =\n      'detail-${DateTime.now().microsecondsSinceEpoch}';\n",
    'conversation fields',
)
replace_once(
    "  Map<String, dynamic> _analyticalContext = const <String, dynamic>{};\n",
    "  Map<String, dynamic> _analyticalContext = const <String, dynamic>{};\n  List<Map<String, dynamic>> _nextSuggestions = const <Map<String, dynamic>>[];\n",
    'suggestion state',
)
replace_once(
    "    _chatController.dispose();\n    _chatScrollController.dispose();\n    super.dispose();\n",
    "    _chatController.dispose();\n    _chatScrollController.dispose();\n    _conversationService.dispose();\n    super.dispose();\n",
    'dispose conversation service',
)
replace_once(
    "      _analyticalContext = const <String, dynamic>{};\n    });\n",
    "      _analyticalContext = const <String, dynamic>{};\n      _nextSuggestions = const <Map<String, dynamic>>[];\n    });\n    try {\n      await _conversationService.reset(_conversationSessionId);\n    } catch (_) {\n      // Local analytical state remains authoritative if the state helper is unavailable.\n    }\n",
    'reset conversation state on dataset change',
)

old_send_start = """  Future<void> _sendMessage() async {\n    final query = _chatController.text.trim();\n    if (query.isEmpty || _files.isEmpty || _runningMessage != null) return;\n    _chatController.clear();\n    final localFollowUp = _resolveLocalFollowUp(query);\n"""
new_send_start = """  Future<void> _sendMessage() async {\n    final query = _chatController.text.trim();\n    if (query.isEmpty || _runningMessage != null) return;\n    _chatController.clear();\n\n    if (_isSessionSummaryQuery(query)) {\n      setState(() {\n        _chatHistory.add(_ChatMessage.user(query));\n        _runningMessage = 'Summarizing this analysis session…';\n      });\n      try {\n        final summary = await _conversationService.summary(_conversationSessionId);\n        if (!mounted) return;\n        setState(() {\n          _runningMessage = null;\n          _chatHistory.add(\n            _ChatMessage.assistant(\n              summary['summary']?.toString() ?? 'Here is the current analysis summary.',\n              sessionSummary: summary,\n            ),\n          );\n        });\n        _scrollChatToEnd();\n      } catch (_) {\n        if (!mounted) return;\n        setState(() {\n          _runningMessage = null;\n          _chatHistory.add(\n            _ChatMessage.assistant(\n              'I could not summarize this session right now. Your current analytical context was not changed.',\n            ),\n          );\n        });\n      }\n      return;\n    }\n\n    try {\n      final meta = await _conversationService.meta(query);\n      if (meta['handled'] == true) {\n        if (!mounted) return;\n        setState(() {\n          _chatHistory.add(_ChatMessage.user(query));\n          _chatHistory.add(_ChatMessage.assistant(_metaResponseText(meta)));\n        });\n        _scrollChatToEnd();\n        return;\n      }\n    } catch (_) {\n      // Meta routing is an optional local fast path; normal analysis can continue.\n    }\n\n    if (_files.isEmpty) {\n      setState(() {\n        _chatHistory.add(_ChatMessage.user(query));\n        _chatHistory.add(\n          _ChatMessage.assistant(\n            'Upload one or more datasets to run analytical questions. You can still ask who I am, who created InsightFlow, what I can do, or how privacy works.',\n          ),\n        );\n      });\n      _scrollChatToEnd();\n      return;\n    }\n\n    final previousRoute = _lastRoute;\n    final previousAnalyticalContext = Map<String, dynamic>.from(_analyticalContext);\n    final localFollowUp = _resolveLocalFollowUp(query);\n"""
replace_once(old_send_start, new_send_start, 'send-message preflight')

replace_once(
    "    _lastRoute = route;\n    setState(() {\n",
    "    setState(() {\n",
    'defer route commit until success',
)

old_success = """      if (mounted) {\n        final structuredQuality =\n            route.subIntent?.startsWith('data_quality:') == true;\n        final attachResult = shouldAttachDetailAnalysisResult(\n          route.intent,\n          _isFullReportQuery(query),\n          isStructuredQuality: structuredQuality,\n        );\n        setState(() {\n          _runningMessage = null;\n          _chatHistory.add(\n            _ChatMessage.assistant(\n"""
new_success = """      if (mounted) {\n        _lastRoute = route;\n        final structuredQuality =\n            route.subIntent?.startsWith('data_quality:') == true;\n        final attachResult = shouldAttachDetailAnalysisResult(\n          route.intent,\n          _isFullReportQuery(query),\n          isStructuredQuality: structuredQuality,\n        );\n        List<Map<String, dynamic>> suggestions = const <Map<String, dynamic>>[];\n        try {\n          await _recordConversationSuccess(\n            query,\n            route,\n            result,\n            activeBusinessFilters,\n          );\n          suggestions = await _loadContextSuggestions(route, result);\n        } catch (_) {\n          // Suggestions/history are enhancements and must never fail the analysis itself.\n        }\n        _nextSuggestions = suggestions;\n        setState(() {\n          _runningMessage = null;\n          _chatHistory.add(\n            _ChatMessage.assistant(\n"""
replace_once(old_success, new_success, 'successful analysis state commit')

old_subintent_end = """                  : route.subIntent,\n            ),\n          );\n        });\n"""
new_subintent_end = """                  : route.subIntent,\n              suggestions: suggestions,\n            ),\n          );\n        });\n"""
replace_once(old_subintent_end, new_subintent_end, 'attach suggestions to assistant message')

replace_once(
    """    } catch (_) {\n      if (mounted) {\n        setState(() {\n          _runningMessage = null;\n""",
    """    } catch (_) {\n      _lastRoute = previousRoute;\n      _analyticalContext = previousAnalyticalContext;\n      _nextSuggestions = const <Map<String, dynamic>>[];\n      if (mounted) {\n        setState(() {\n          _runningMessage = null;\n""",
    'failed-query rollback',
)

helpers_anchor = """  Map<String, dynamic> _resolveBusinessFilters(\n    String query,\n    DetailAnalysisRoute route,\n  ) => resolveBusinessFiltersFromContext(_analyticalContext, query);\n\n"""
helpers = helpers_anchor + """  bool _isSessionSummaryQuery(String query) => RegExp(\n    r'\\b(summarize|summary|analysed|analyzed|history|current scope|looking at now)\\b',\n    caseSensitive: false,\n  ).hasMatch(query) &&\n      RegExp(\n        r'\\b(analysis|session|scope|so far|history|we|current)\\b',\n        caseSensitive: false,\n      ).hasMatch(query);\n\n  String _metaResponseText(Map<String, dynamic> meta) {\n    final parts = <String>[];\n    final summary = meta['summary']?.toString().trim();\n    if (summary != null && summary.isNotEmpty) parts.add(summary);\n    for (final section in (meta['sections'] as List? ?? const []).whereType<Map>()) {\n      final title = section['title']?.toString().trim();\n      final items = (section['items'] as List? ?? const [])\n          .map((item) => item.toString().trim())\n          .where((item) => item.isNotEmpty)\n          .toList();\n      if (title != null && title.isNotEmpty && items.isNotEmpty) {\n        parts.add('$title\\n${items.map((item) => '• $item').join('\\n')}');\n      }\n    }\n    final examples = (meta['examples'] as List? ?? const [])\n        .map((item) => item.toString().trim())\n        .where((item) => item.isNotEmpty)\n        .toList();\n    if (examples.isNotEmpty) {\n      parts.add('Examples\\n${examples.map((item) => '• $item').join('\\n')}');\n    }\n    return parts.isEmpty ? 'InsightFlow help is available locally.' : parts.join('\\n\\n');\n  }\n\n  Future<void> _recordConversationSuccess(\n    String query,\n    DetailAnalysisRoute route,\n    Map<String, dynamic> result,\n    Map<String, dynamic> activeBusinessFilters,\n  ) async {\n    final filters = _analyticalContext['filters'] is Map\n        ? Map<String, dynamic>.from(_analyticalContext['filters'] as Map)\n        : Map<String, dynamic>.from(activeBusinessFilters);\n    final selected = _analyticalContext['selected_entity'];\n    String? selectedEntity;\n    String? selectedEntityType;\n    if (selected is Map) {\n      selectedEntity = selected['display_value']?.toString();\n      selectedEntityType = selected['role']?.toString();\n    } else if (selected != null) {\n      selectedEntity = selected.toString();\n    }\n    final normalized = query.toLowerCase();\n    final response = result['analyst_business_response'];\n    final responseType = response is Map ? response['response_type']?.toString() : null;\n    final update = <String, dynamic>{\n      'query': query,\n      'current_scope': filters.isEmpty\n          ? 'global'\n          : filters.entries.map((entry) => '${entry.key}=${entry.value}').join(', '),\n      'active_filters': filters,\n      'selected_entity': selectedEntity,\n      'selected_entity_type': selectedEntityType,\n      'current_metric': _analyticalContext['metric']?.toString(),\n      'current_grain': _analyticalContext['grain']?.toString(),\n      'time_scope': _analyticalContext['time_scope'] == null\n          ? <String, dynamic>{}\n          : {'year': _analyticalContext['time_scope']},\n      'reset_scope': normalized.contains('reset') ||\n          (normalized.contains('overall') && normalized.contains('company')),\n      'analysis': {\n        'type': responseType ?? route.subIntent ?? route.intent.name,\n        'scope': filters.isEmpty ? 'global' : filters.toString(),\n        'grain': _analyticalContext['grain'],\n        'metric': _analyticalContext['metric'],\n        'selected_entity': selectedEntity,\n        'summary': _resultLabel(route),\n      },\n    };\n    if (result['comparison_context'] is Map) {\n      final comparison = Map<String, dynamic>.from(result['comparison_context'] as Map);\n      final entities = comparison['entities'];\n      if (entities is List) update['comparison_entities'] = entities;\n    }\n    if (result['report'] is Map) {\n      final report = Map<String, dynamic>.from(result['report'] as Map);\n      update['report'] = {\n        'filename': result['filename'] ?? report['filename'],\n        'report_type': result['report_type'] ?? report['report_type'],\n        'scope': report['scope']?.toString(),\n        'generated_at': report['generated_at'],\n      };\n    }\n    await _conversationService.update(\n      sessionId: _conversationSessionId,\n      update: update,\n    );\n  }\n\n  Future<List<Map<String, dynamic>>> _loadContextSuggestions(\n    DetailAnalysisRoute route,\n    Map<String, dynamic> result,\n  ) async {\n    String intent = route.subIntent?.startsWith('data_quality:') == true ||\n            route.intent == DetailAnalysisIntent.customerDataQuality\n        ? 'data_quality_analysis'\n        : 'business_analysis';\n    final business = result['analyst_business_response'];\n    if (business is Map && business['response_type'] == 'analyst_comparison_response') {\n      intent = 'comparison';\n    }\n    final selected = _analyticalContext['selected_entity'];\n    final context = <String, dynamic>{\n      'intent': intent,\n      if (selected is Map) ...{\n        'selected_entity': selected['display_value'],\n        'selected_entity_type': selected['role'],\n      },\n      if (_analyticalContext['grain'] != null)\n        'current_grain': _analyticalContext['grain'],\n      if (_analyticalContext['metric'] != null)\n        'current_metric': _analyticalContext['metric'],\n    };\n    if (result['comparison_context'] is Map) {\n      final comparison = Map<String, dynamic>.from(result['comparison_context'] as Map);\n      if (comparison['entities'] is List) {\n        context['comparison_entities'] = comparison['entities'];\n      }\n    }\n    final response = await _conversationService.suggestions(\n      sessionId: _conversationSessionId,\n      context: context,\n    );\n    return (response['suggestions'] as List? ?? const [])\n        .whereType<Map>()\n        .map((item) => Map<String, dynamic>.from(item))\n        .toList(growable: false);\n  }\n\n  void _sendSuggestedQuery(String query) {\n    if (_runningMessage != null || query.trim().isEmpty) return;\n    _chatController.text = query.trim();\n    _sendMessage();\n  }\n\n"""
replace_once(helpers_anchor, helpers, 'conversation helper methods')

replace_once(
    """          : _ChatMessageView(\n              message: _chatHistory[index],\n              resultBuilder: _buildResultWidget,\n            ),\n""",
    """          : _ChatMessageView(\n              message: _chatHistory[index],\n              resultBuilder: _buildResultWidget,\n              onSuggestionSelected: _sendSuggestedQuery,\n            ),\n""",
    'chat view suggestion callback',
)

replace_once(
    """            enabled: ready && _runningMessage == null,\n""",
    """            enabled: _runningMessage == null,\n""",
    'composer enabled before dataset',
)
replace_once(
    """              hintText: ready\n                  ? 'Ask about your data…'\n                  : 'Upload datasets to begin…',\n""",
    """              hintText: ready\n                  ? 'Ask about your data…'\n                  : 'Ask about InsightFlow or upload datasets to analyze…',\n""",
    'composer no-data hint',
)
replace_once(
    """          onPressed: ready && _runningMessage == null ? _sendMessage : null,\n""",
    """          onPressed: _runningMessage == null ? _sendMessage : null,\n""",
    'send enabled before dataset',
)

old_message_ctor = """class _ChatMessage {\n  const _ChatMessage({\n    required this.text,\n    required this.user,\n    this.result,\n    this.intent,\n    this.subIntent,\n  });\n"""
new_message_ctor = """class _ChatMessage {\n  const _ChatMessage({\n    required this.text,\n    required this.user,\n    this.result,\n    this.intent,\n    this.subIntent,\n    this.suggestions = const <Map<String, dynamic>>[],\n    this.sessionSummary,\n  });\n"""
replace_once(old_message_ctor, new_message_ctor, 'chat message fields constructor')

old_assistant_ctor = """  const _ChatMessage.assistant(\n    String text, {\n    Map<String, dynamic>? result,\n    DetailAnalysisIntent? intent,\n    String? subIntent,\n  }) : this(\n         text: text,\n         user: false,\n         result: result,\n         intent: intent,\n         subIntent: subIntent,\n       );\n"""
new_assistant_ctor = """  const _ChatMessage.assistant(\n    String text, {\n    Map<String, dynamic>? result,\n    DetailAnalysisIntent? intent,\n    String? subIntent,\n    List<Map<String, dynamic>> suggestions = const <Map<String, dynamic>>[],\n    Map<String, dynamic>? sessionSummary,\n  }) : this(\n         text: text,\n         user: false,\n         result: result,\n         intent: intent,\n         subIntent: subIntent,\n         suggestions: suggestions,\n         sessionSummary: sessionSummary,\n       );\n"""
replace_once(old_assistant_ctor, new_assistant_ctor, 'assistant message constructor')
replace_once(
    """  final DetailAnalysisIntent? intent;\n  final String? subIntent;\n}\n\nclass _ChatMessageView extends StatefulWidget {\n  const _ChatMessageView({required this.message, required this.resultBuilder});\n  final _ChatMessage message;\n  final Widget Function(BuildContext, _ChatMessage) resultBuilder;\n""",
    """  final DetailAnalysisIntent? intent;\n  final String? subIntent;\n  final List<Map<String, dynamic>> suggestions;\n  final Map<String, dynamic>? sessionSummary;\n}\n\nclass _ChatMessageView extends StatefulWidget {\n  const _ChatMessageView({\n    required this.message,\n    required this.resultBuilder,\n    required this.onSuggestionSelected,\n  });\n  final _ChatMessage message;\n  final Widget Function(BuildContext, _ChatMessage) resultBuilder;\n  final ValueChanged<String> onSuggestionSelected;\n""",
    'message view callback and fields',
)

old_render_tail = """            if (message.result != null) ...[\n              const SizedBox(height: 14),\n              useSharedSelection\n                  ? SelectionArea(child: widget.resultBuilder(context, message))\n                  : widget.resultBuilder(context, message),\n            ],\n"""
new_render_tail = """            if (message.result != null) ...[\n              const SizedBox(height: 14),\n              useSharedSelection\n                  ? SelectionArea(child: widget.resultBuilder(context, message))\n                  : widget.resultBuilder(context, message),\n            ],\n            if (message.sessionSummary != null)\n              AnalystSessionSummary(summary: message.sessionSummary!),\n            if (!message.user && message.suggestions.isNotEmpty)\n              AnalystSuggestions(\n                suggestions: message.suggestions,\n                onSelected: widget.onSuggestionSelected,\n              ),\n"""
replace_once(old_render_tail, new_render_tail, 'render summary and suggestions')

if text == original:
    raise SystemExit('patch produced no changes')
PATH.write_text(text, encoding='utf-8')
print('Patched', PATH)
