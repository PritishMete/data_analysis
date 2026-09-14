import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:web/web.dart' as web;

import 'app_colors.dart';
import 'core/services/powerbi_detail_analysis_service.dart';
import 'core/services/business_analysis_context.dart';
import 'core/services/chat_reasoning_service.dart';
import 'core/services/conversation_state_service.dart';
import 'detail_analysis_router.dart';
import 'embedded_report_scroll.dart';
import 'test_motion_mode.dart';
import 'star_schema_view.dart';
import 'tech_background.dart';
import 'widgets/analyst_quality_message.dart';
import 'widgets/analyst_chart.dart';
import 'widgets/analyst_suggestions.dart';
import 'widgets/system_status_button.dart';

@JS('Object.is')
external JSBoolean _sameJsObject(JSAny? left, JSAny? right);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await LiquidGlassWidgets.initialize();
  runApp(DetailAnalysisApp(testMode: isDetailAnalysisTestMode(Uri.base)));
}

class DetailAnalysisApp extends StatelessWidget {
  const DetailAnalysisApp({super.key, this.testMode = false});

  final bool testMode;

  @override
  Widget build(BuildContext context) {
    return LiquidGlassWidgets.wrap(
      adaptiveQuality: false,
      theme: GlassThemeData(
        brightness: Brightness.dark,
        dark: const GlassThemeVariant(
          settings: GlassThemeSettings(
            glassColor: Color(0x1FFFFFFF),
            thickness: 20,
            blur: 14,
            refractiveIndex: 0.9,
            saturation: 1.2,
            ambientStrength: 0.4,
            lightIntensity: 0.8,
          ),
          quality: GlassQuality.minimal,
        ),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => applyDetailAnalysisTestMotionMode(
          context,
          enabled: testMode,
          child: child ?? const SizedBox.shrink(),
        ),
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF020715),
          fontFamily: 'SFPro',
        ),
        home: const DetailAnalysisPage(),
      ),
    );
  }

  /*
  @override
  Widget build(BuildContext context) {
    final hasDatasets = _files.isNotEmpty;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: TechAnimatedBackground()),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
                      child: _header(),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: GlassCard(
                          padding: EdgeInsets.zero,
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 22,
                          ),
                          child: Column(
                            children: [
                              _DatasetSessionBar(
                                files: _files,
                                onChange: _analyze,
                              ),
                              Expanded(child: _buildChatHistory(context)),
                              _buildComposer(context, hasDatasets),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatHistory(BuildContext context) {
    if (_chatHistory.isEmpty) return _EmptyChat(onUpload: _analyze);
    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      itemCount: _chatHistory.length + (_runningMessage == null ? 0 : 1),
      itemBuilder: (context, index) {
        if (index == _chatHistory.length)
          return _TypingBubble(text: _runningMessage!);
        final message = _chatHistory[index];
        return _ChatMessageView(
          message: message,
          resultBuilder: _buildResultWidget,
        );
      },
    );
  }

  Widget _buildComposer(BuildContext context, bool hasDatasets) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Shortcuts(
              shortcuts: const <SingleActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.numpadEnter):
                    ActivateIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  ActivateIntent: CallbackAction<ActivateIntent>(
                    onInvoke: (_) {
                      _sendMessage();
                      return null;
                    },
                  ),
                },
                child: TextField(
                  controller: _chatController,
                  enabled: hasDatasets && _runningMessage == null,
                  minLines: 1,
                  maxLines: 4,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: hasDatasets
                        ? 'Ask about your data…'
                        : 'Upload datasets to begin…',
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: .07),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 13,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(
            tooltip: 'Send',
            onPressed: hasDatasets && _runningMessage == null
                ? _sendMessage
                : null,
            icon: _runningMessage == null
                ? const Icon(Icons.send_rounded)
                : const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultWidget(BuildContext context, _ChatMessage message) {
    final result = message.result;
    if (result == null) return const SizedBox.shrink();
    switch (message.intent) {
      case DetailAnalysisIntent.detailAnalysis:
        return _detailResultWidget();
      case DetailAnalysisIntent.customerCleaning:
        return _CustomerCleanSummary(result: result);
      case DetailAnalysisIntent.productCleaning:
        return _ProductCleanSummary(result: result);
      case DetailAnalysisIntent.orderCleaning:
        return _OrderCleanSummary(result: result);
      case DetailAnalysisIntent.dateDimension:
        return _DateDimensionSummary(result: result);
      case DetailAnalysisIntent.businessAnalysis:
        return result['report'] is Map
            ? _ReportSummary(result: result)
            : _BusinessAnalysisSummary(result: result);
      case DetailAnalysisIntent.dashboard:
        return _DashboardCard(
          result: result,
          selectedYear: _selectedDashboardYear,
          selectedRegion: _selectedDashboardRegion,
          selectedCategory: _selectedDashboardCategory,
          onYearChanged: (value) {
            setState(() => _selectedDashboardYear = value);
            _loadDashboard();
          },
          onRegionChanged: (value) {
            setState(() => _selectedDashboardRegion = value);
            _loadDashboard();
          },
          onCategoryChanged: (value) {
            setState(() => _selectedDashboardCategory = value);
            _loadDashboard();
          },
          onReset: _resetDashboardFilters,
        );
      case DetailAnalysisIntent.unknown:
        return const SizedBox.shrink();
    }
  }

  Widget _detailResultWidget() {
    if (_reportHtml != null &&
        _reportBeforeSchema != null &&
        _reportAfterSchema != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 2700,
            child: HtmlElementView(
              viewType: 'detail-report-before-$_reportVersion',
            ),
          ),
          const SizedBox(height: 12),
          StarSchemaView(
            schema: _result?['star_schema'] is Map
                ? Map<String, dynamic>.from(_result!['star_schema'] as Map)
                : const <String, dynamic>{},
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 520,
            child: HtmlElementView(
              viewType: 'detail-report-after-$_reportVersion',
            ),
          ),
        ],
      );
    }
    if (_reportHtml != null)
      return SizedBox(
        height: 1100,
        child: HtmlElementView(
          viewType: 'detail-report-before-$_reportVersion',
        ),
      );
    return SelectableText(_reportText());
  }

  Widget _buildLegacyPage(BuildContext context) {
    return LiquidGlassWidgets.wrap(
      adaptiveQuality: false,
      theme: GlassThemeData(
        brightness: Brightness.dark,
        dark: const GlassThemeVariant(
          settings: GlassThemeSettings(
            glassColor: Color(0x1FFFFFFF),
            thickness: 20,
            blur: 14,
            refractiveIndex: 0.9,
            saturation: 1.2,
            ambientStrength: 0.4,
            lightIntensity: 0.8,
          ),
          quality: GlassQuality.minimal,
        ),
      ),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xFF020715),
          fontFamily: 'SFPro',
        ),
        home: const DetailAnalysisPage(),
      ),
    );
  }
  */
}

class DetailAnalysisPage extends StatefulWidget {
  const DetailAnalysisPage({super.key});

  @override
  State<DetailAnalysisPage> createState() => _DetailAnalysisPageState();
}

class _DetailAnalysisPageState extends State<DetailAnalysisPage> {
  final _service = PowerBiDetailAnalysisService();
  final _reasoningService = ChatReasoningService();
  final _conversationService = ConversationStateService();
  final String _conversationSessionId =
      'detail-${DateTime.now().microsecondsSinceEpoch}';
  List<PlatformFile> _files = [];
  Map<String, dynamic>? _result;
  String? _error;
  bool _loading = false;
  int _reportVersion = 0;
  final List<JSAny> _reportFrameSources = <JSAny>[];
  String? _reportHtml;
  String? _reportBeforeSchema;
  String? _reportAfterSchema;
  final Map<String, double> _reportFrameHeights = {};
  Map<String, dynamic>? _customerCleanResult;
  Map<String, dynamic>? _productCleanResult;
  Map<String, dynamic>? _orderCleanResult;
  Map<String, dynamic>? _dateDimensionResult;
  Map<String, dynamic>? _businessAnalysisResult;
  Map<String, dynamic>? _dashboardResult;
  bool _cleaningCustomer = false;
  bool _cleaningProduct = false;
  bool _cleaningOrders = false;
  bool _buildingDateDimension = false;
  bool _runningBusinessAnalysis = false;
  bool _loadingDashboard = false;
  int? _selectedDashboardYear;
  String? _selectedDashboardRegion;
  String? _selectedDashboardCategory;
  final _chatController = TextEditingController();
  final _chatScrollController = ScrollController();
  final List<_ChatMessage> _chatHistory = [];
  List<Map<String, dynamic>> _lastFindings = [];
  String? _lastSelectedFindingId;
  String? _runningMessage;
  DetailAnalysisRoute? _lastRoute;
  Map<String, dynamic> _analyticalContext = const <String, dynamic>{};
  List<Map<String, dynamic>> _nextSuggestions = const <Map<String, dynamic>>[];
  late final JSFunction _reportMessageListener = _handleReportMessage.toJS;

  @override
  void initState() {
    super.initState();
    web.window.addEventListener('message', _reportMessageListener);
  }

  void _handleReportMessage(web.Event event) {
    final messageEvent = event as web.MessageEvent;
    final testMode = isDetailAnalysisTestMode(Uri.base);
    if (testMode) print('[DETAIL_REPORT_WHEEL] received');
    final source = messageEvent.source;
    final sourceRegistered =
        source != null &&
        _reportFrameSources.any(
          (registered) => _sameJsObject(source, registered).toDart,
        );
    final stringPayload = messageEvent.data.isA<JSString>();
    if (testMode) {
      print(
        '[DETAIL_REPORT_WHEEL] source=$sourceRegistered '
        'registered=${_reportFrameSources.length} string=$stringPayload',
      );
    }
    if (messageEvent.source == null || !sourceRegistered || !stringPayload) {
      return;
    }

    final delta = parseEmbeddedReportScrollDelta(
      (messageEvent.data as JSString).toDart,
      _conversationSessionId,
    );
    final attached = _chatScrollController.hasClients;
    if (testMode) {
      print('[DETAIL_REPORT_WHEEL] delta=${delta != null} attached=$attached');
    }
    if (delta == null || !attached) return;

    final position = _chatScrollController.position;
    final currentOffset = position.pixels;
    final nextOffset = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (testMode) {
      print(
        '[DETAIL_REPORT_WHEEL] scroll=${currentOffset != nextOffset} '
        'extent=${position.maxScrollExtent - position.minScrollExtent}',
      );
    }
    _chatScrollController.jumpTo(nextOffset);
  }

  @override
  void dispose() {
    web.window.removeEventListener('message', _reportMessageListener);
    _reportFrameSources.clear();
    _chatController.dispose();
    _chatScrollController.dispose();
    _conversationService.dispose();
    super.dispose();
  }

  Future<void> _analyze() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv', 'tsv', 'xlsx', 'xlsm', 'xls', 'json'],
      allowMultiple: true,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    setState(() {
      _files = picked.files;
      _chatHistory.clear();
      _result = null;
      _reportHtml = null;
      _reportBeforeSchema = null;
      _reportAfterSchema = null;
      _customerCleanResult = null;
      _productCleanResult = null;
      _orderCleanResult = null;
      _dateDimensionResult = null;
      _businessAnalysisResult = null;
      _dashboardResult = null;
      _error = null;
      _selectedDashboardYear = null;
      _selectedDashboardRegion = null;
      _selectedDashboardCategory = null;
      _lastRoute = null;
      _lastFindings = [];
      _lastSelectedFindingId = null;
      _analyticalContext = const <String, dynamic>{};
      _nextSuggestions = const <Map<String, dynamic>>[];
    });
    try {
      await _conversationService.reset(_conversationSessionId);
    } catch (_) {
      // Local analytical state remains authoritative if the state helper is unavailable.
    }
    _chatHistory.add(
      _ChatMessage.assistant(
        'Your datasets are ready. What would you like to analyze?',
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _sendMessage() async {
    final query = _chatController.text.trim();
    if (query.isEmpty || _runningMessage != null) return;
    _chatController.clear();

    if (_isSessionSummaryQuery(query)) {
      setState(() {
        _chatHistory.add(_ChatMessage.user(query));
        _runningMessage = 'Summarizing this analysis session…';
      });
      try {
        final summary = await _conversationService.summary(
          _conversationSessionId,
        );
        if (!mounted) return;
        setState(() {
          _runningMessage = null;
          _chatHistory.add(
            _ChatMessage.assistant(
              summary['summary']?.toString() ??
                  'Here is the current analysis summary.',
              sessionSummary: summary,
            ),
          );
        });
        _scrollChatToEnd();
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _runningMessage = null;
          _chatHistory.add(
            _ChatMessage.assistant(
              'I could not summarize this session right now. Your current analytical context was not changed.',
            ),
          );
        });
      }
      return;
    }

    try {
      final meta = await _conversationService.meta(query);
      if (meta['handled'] == true) {
        if (!mounted) return;
        setState(() {
          _chatHistory.add(_ChatMessage.user(query));
          _chatHistory.add(_ChatMessage.assistant(_metaResponseText(meta)));
        });
        _scrollChatToEnd();
        return;
      }
    } catch (_) {
      // Meta routing is an optional local fast path; normal analysis can continue.
    }

    if (_files.isEmpty) {
      setState(() {
        _chatHistory.add(_ChatMessage.user(query));
        _chatHistory.add(
          _ChatMessage.assistant(
            'Upload one or more datasets to run analytical questions. You can still ask who I am, who created InsightFlow, what I can do, or how privacy works.',
          ),
        );
      });
      _scrollChatToEnd();
      return;
    }

    final previousRoute = _lastRoute;
    final previousAnalyticalContext = Map<String, dynamic>.from(
      _analyticalContext,
    );
    final localFollowUp = _resolveLocalFollowUp(query);
    if (localFollowUp != null && localFollowUp['kind'] == 'why') {
      final finding = localFollowUp['finding'] as Map<String, dynamic>;
      setState(() {
        _chatHistory.add(_ChatMessage.user(query));
        _chatHistory.add(
          _ChatMessage.assistant(_localFindingExplanation(finding)),
        );
      });
      _scrollChatToEnd();
      return;
    }
    if (localFollowUp != null && localFollowUp['kind'] == 'review') {
      setState(() {
        _chatHistory.add(_ChatMessage.user(query));
        _chatHistory.add(
          _ChatMessage.assistant(localFollowUp['message'] as String),
        );
      });
      _scrollChatToEnd();
      return;
    }
    var route = routeDetailAnalysisMessage(query, previousRoute: _lastRoute);
    if (localFollowUp != null && localFollowUp['kind'] == 'clean') {
      route = localFollowUp['route'] as DetailAnalysisRoute;
    }
    if (route.intent == DetailAnalysisIntent.unknown) {
      try {
        route =
            await _reasoningService.plan(
              query,
              _files,
              previousRoute: _lastRoute,
            ) ??
            route;
      } catch (_) {
        // The local deterministic router remains the offline fallback.
      }
    }
    setState(() {
      _chatHistory.add(_ChatMessage.user(query));
      _runningMessage = _loadingLabel(route);
      _error = null;
    });
    try {
      Map<String, dynamic> result;
      Map<String, dynamic> activeBusinessFilters = const <String, dynamic>{};
      switch (route.intent) {
        case DetailAnalysisIntent.detailAnalysis:
          result = await _service.analyze(_files);
          _setDetailResult(result);
          break;
        case DetailAnalysisIntent.customerCleaning:
          result = await _service.cleanCustomer(_files);
          _customerCleanResult = result;
          break;
        case DetailAnalysisIntent.productCleaning:
          result = await _service.cleanProduct(_files);
          _productCleanResult = result;
          break;
        case DetailAnalysisIntent.orderCleaning:
          result = await _service.cleanOrders(_files);
          _orderCleanResult = result;
          break;
        case DetailAnalysisIntent.dateDimension:
          result = await _service.buildDateDimension(_files);
          _dateDimensionResult = result;
          break;
        case DetailAnalysisIntent.businessAnalysis:
          activeBusinessFilters = _resolveBusinessFilters(query, route);
          result = await _service.analyzeBusinessModel(
            _files,
            filters: activeBusinessFilters,
            query: query,
            context: _analyticalContext,
          );
          if (result['active_filters'] is Map) {
            activeBusinessFilters = Map<String, dynamic>.from(
              result['active_filters'] as Map,
            );
          }
          _updateAnalyticalContext(query, route, result, activeBusinessFilters);
          _businessAnalysisResult = result;
          break;
        case DetailAnalysisIntent.customerDataQuality:
          result = await _service.analyze(_files);
          _setDetailResult(result);
          break;
        case DetailAnalysisIntent.dashboard:
          result = await _service.buildDashboard(
            _files,
            year: _selectedDashboardYear,
            region: _selectedDashboardRegion,
            category: _selectedDashboardCategory,
          );
          _dashboardResult = result;
          break;
        case DetailAnalysisIntent.unknown:
          if (mounted) {
            setState(() {
              _runningMessage = null;
              _chatHistory.add(
                _ChatMessage.assistant(
                  "I can currently help with dataset profiling, cleaning, dimensional modeling, business analysis and dashboard exploration. Try asking 'Analyze these datasets' or 'Show monthly revenue and profit'.",
                ),
              );
            });
          }
          return;
      }
      if (mounted) {
        _lastRoute = route;
        final structuredQuality =
            route.subIntent?.startsWith('data_quality:') == true;
        final attachResult = shouldAttachDetailAnalysisResult(
          route.intent,
          _isFullReportQuery(query),
          isStructuredQuality: structuredQuality,
        );
        List<Map<String, dynamic>> suggestions = const <Map<String, dynamic>>[];
        try {
          await _recordConversationSuccess(
            query,
            route,
            result,
            activeBusinessFilters,
          );
          suggestions = await _loadContextSuggestions(route, result);
        } catch (_) {
          // Suggestions/history are enhancements and must never fail the analysis itself.
        }
        _nextSuggestions = suggestions;
        setState(() {
          _runningMessage = null;
          _chatHistory.add(
            _ChatMessage.assistant(
              route.intent == DetailAnalysisIntent.detailAnalysis ||
                      route.intent == DetailAnalysisIntent.customerDataQuality
                  ? (_isFullReportQuery(query)
                        ? _resultLabel(route)
                        : _conciseAnswer(result, query))
                  : _resultLabel(route),
              result:
                  route.intent == DetailAnalysisIntent.detailAnalysis ||
                      route.intent == DetailAnalysisIntent.customerDataQuality
                  ? (attachResult ? result : null)
                  : result,
              intent: route.intent,
              subIntent:
                  route.intent == DetailAnalysisIntent.businessAnalysis &&
                      result['analyst_business_response'] is Map &&
                      (result['analyst_business_response']
                              as Map)['response_type'] ==
                          'analyst_comparison_response'
                  ? 'comparison_analysis'
                  : route.intent == DetailAnalysisIntent.businessAnalysis &&
                        result['analyst_business_response'] is Map &&
                        (result['analyst_business_response']
                                as Map)['response_type'] ==
                            'analyst_insight_response'
                  ? 'automatic_insights'
                  : route.intent == DetailAnalysisIntent.businessAnalysis &&
                        activeBusinessFilters.isNotEmpty
                  ? 'filtered_business_performance'
                  : route.subIntent,
              suggestions: suggestions,
            ),
          );
        });
        _scrollChatToEnd();
      }
    } catch (_) {
      _lastRoute = previousRoute;
      _analyticalContext = previousAnalyticalContext;
      _nextSuggestions = const <Map<String, dynamic>>[];
      if (mounted) {
        setState(() {
          _runningMessage = null;
          _chatHistory.add(
            _ChatMessage.assistant(
              "I couldn't complete that local operation. Check that the selected files can be parsed, then try again.",
            ),
          );
        });
      }
    }
  }

  Map<String, dynamic> _resolveBusinessFilters(
    String query,
    DetailAnalysisRoute route,
  ) => resolveBusinessFiltersFromContext(_analyticalContext, query);

  bool _isSessionSummaryQuery(String query) =>
      RegExp(
        r'\b(summarize|summary|analysed|analyzed|history|current scope|looking at now)\b',
        caseSensitive: false,
      ).hasMatch(query) &&
      RegExp(
        r'\b(analysis|session|scope|so far|history|we|current)\b',
        caseSensitive: false,
      ).hasMatch(query);

  String _metaResponseText(Map<String, dynamic> meta) {
    final parts = <String>[];
    final summary = meta['summary']?.toString().trim();
    if (summary != null && summary.isNotEmpty) parts.add(summary);
    for (final section
        in (meta['sections'] as List? ?? const []).whereType<Map>()) {
      final title = section['title']?.toString().trim();
      final items = (section['items'] as List? ?? const [])
          .map((item) => item.toString().trim())
          .where((item) => item.isNotEmpty)
          .toList();
      if (title != null && title.isNotEmpty && items.isNotEmpty) {
        parts.add('$title\n${items.map((item) => '• $item').join('\n')}');
      }
    }
    final examples = (meta['examples'] as List? ?? const [])
        .map((item) => item.toString().trim())
        .where((item) => item.isNotEmpty)
        .toList();
    if (examples.isNotEmpty) {
      parts.add('Examples\n${examples.map((item) => '• $item').join('\n')}');
    }
    return parts.isEmpty
        ? 'InsightFlow help is available locally.'
        : parts.join('\n\n');
  }

  Future<void> _recordConversationSuccess(
    String query,
    DetailAnalysisRoute route,
    Map<String, dynamic> result,
    Map<String, dynamic> activeBusinessFilters,
  ) async {
    final filters = _analyticalContext['filters'] is Map
        ? Map<String, dynamic>.from(_analyticalContext['filters'] as Map)
        : Map<String, dynamic>.from(activeBusinessFilters);
    final selected = _analyticalContext['selected_entity'];
    String? selectedEntity;
    String? selectedEntityType;
    if (selected is Map) {
      selectedEntity = selected['display_value']?.toString();
      selectedEntityType = selected['role']?.toString();
    } else if (selected != null) {
      selectedEntity = selected.toString();
    }
    final normalized = query.toLowerCase();
    final response = result['analyst_business_response'];
    final responseType = response is Map
        ? response['response_type']?.toString()
        : null;
    final update = <String, dynamic>{
      'query': query,
      'current_scope': filters.isEmpty
          ? 'global'
          : filters.entries
                .map((entry) => '${entry.key}=${entry.value}')
                .join(', '),
      'active_filters': filters,
      'selected_entity': selectedEntity,
      'selected_entity_type': selectedEntityType,
      'current_metric': _analyticalContext['metric']?.toString(),
      'current_grain': _analyticalContext['grain']?.toString(),
      'time_scope': _analyticalContext['time_scope'] == null
          ? <String, dynamic>{}
          : {'year': _analyticalContext['time_scope']},
      'reset_scope':
          normalized.contains('reset') ||
          (normalized.contains('overall') && normalized.contains('company')),
      'analysis': {
        'type': responseType ?? route.subIntent ?? route.intent.name,
        'scope': filters.isEmpty ? 'global' : filters.toString(),
        'grain': _analyticalContext['grain'],
        'metric': _analyticalContext['metric'],
        'selected_entity': selectedEntity,
        'summary': _resultLabel(route),
      },
    };
    if (result['comparison_context'] is Map) {
      final comparison = Map<String, dynamic>.from(
        result['comparison_context'] as Map,
      );
      final entities = comparison['entities'];
      if (entities is List) update['comparison_entities'] = entities;
    }
    if (result['report'] is Map) {
      final report = Map<String, dynamic>.from(result['report'] as Map);
      update['report'] = {
        'filename': result['filename'] ?? report['filename'],
        'report_type': result['report_type'] ?? report['report_type'],
        'scope': report['scope']?.toString(),
        'generated_at': report['generated_at'],
      };
    }
    await _conversationService.update(
      sessionId: _conversationSessionId,
      update: update,
    );
  }

  Future<List<Map<String, dynamic>>> _loadContextSuggestions(
    DetailAnalysisRoute route,
    Map<String, dynamic> result,
  ) async {
    String intent =
        route.subIntent?.startsWith('data_quality:') == true ||
            route.intent == DetailAnalysisIntent.customerDataQuality
        ? 'data_quality_analysis'
        : 'business_analysis';
    final business = result['analyst_business_response'];
    if (business is Map &&
        business['response_type'] == 'analyst_comparison_response') {
      intent = 'comparison';
    }
    final selected = _analyticalContext['selected_entity'];
    final context = <String, dynamic>{
      'intent': intent,
      if (selected is Map) ...{
        'selected_entity': selected['display_value'],
        'selected_entity_type': selected['role'],
      },
      if (_analyticalContext['grain'] != null)
        'current_grain': _analyticalContext['grain'],
      if (_analyticalContext['metric'] != null)
        'current_metric': _analyticalContext['metric'],
    };
    if (result['comparison_context'] is Map) {
      final comparison = Map<String, dynamic>.from(
        result['comparison_context'] as Map,
      );
      if (comparison['entities'] is List) {
        context['comparison_entities'] = comparison['entities'];
      }
    }
    final response = await _conversationService.suggestions(
      sessionId: _conversationSessionId,
      context: context,
    );
    return (response['suggestions'] as List? ?? const [])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList(growable: false);
  }

  void _sendSuggestedQuery(String query) {
    if (_runningMessage != null || query.trim().isEmpty) return;
    _chatController.text = query.trim();
    _sendMessage();
  }

  void _updateAnalyticalContext(
    String query,
    DetailAnalysisRoute route,
    Map<String, dynamic> result,
    Map<String, dynamic> filters,
  ) {
    final normalizedQuery = query.toLowerCase();
    if (normalizedQuery.contains('reset') ||
        (normalizedQuery.contains('overall') &&
            normalizedQuery.contains('company'))) {
      _analyticalContext = const <String, dynamic>{};
      return;
    }
    if (result['comparison_context'] is Map) {
      _analyticalContext = Map<String, dynamic>.from(
        result['comparison_context'] as Map,
      );
      return;
    }
    if (result['insight_context'] is Map) {
      _analyticalContext = {
        'intent': 'business_analysis',
        'analysis_family': 'automatic_insights',
        'filters': result['active_filters'] is Map
            ? Map<String, dynamic>.from(result['active_filters'] as Map)
            : const <String, dynamic>{},
        'selected_insight': Map<String, dynamic>.from(
          result['insight_context'] as Map,
        ),
        'insight_context': Map<String, dynamic>.from(
          result['insight_context'] as Map,
        ),
      };
      return;
    }
    final options = result['filter_options'] is Map
        ? Map<String, dynamic>.from(result['filter_options'] as Map)
        : const <String, dynamic>{};
    final nextFilters = Map<String, dynamic>.from(filters);
    final requestedGrain = route.subIntent == 'regional_profit'
        ? 'business_region'
        : route.subIntent == 'top_products'
        ? 'product'
        : null;
    final selectedEntity =
        requestedGrain == null || nextFilters.containsKey(requestedGrain)
        ? null
        : bindSelectedEntityFromResult(
            result,
            requestedGrain: requestedGrain,
            rankingMetric: query.toLowerCase().contains('revenue')
                ? 'revenue'
                : 'profit',
          );
    if (selectedEntity != null) {
      final role = selectedEntity['role']?.toString();
      final display = selectedEntity['display_value']?.toString();
      if (role != null && display != null) nextFilters[role] = display;
      if (role == 'product' && selectedEntity['local_key'] != null) {
        nextFilters['product_id'] = selectedEntity['local_key'];
      }
    }
    _analyticalContext = {
      'intent': 'business_analysis',
      'analysis_family': 'business_performance',
      'grain':
          route.subIntent == 'regional_profit' ||
              nextFilters.containsKey('business_region')
          ? 'business_region'
          : route.subIntent == 'top_products' ||
                nextFilters.containsKey('product')
          ? 'product'
          : route.subIntent ?? 'business_performance',
      'metric': query.toLowerCase().contains('revenue') ? 'revenue' : 'profit',
      'filters': nextFilters,
      'filter_options': options,
      'selected_entity': selectedEntity == null
          ? _analyticalContext['selected_entity']
          : selectedEntity,
      'time_scope': nextFilters['year'],
      'comparison_scope': null,
    };
  }

  String _loadingLabel(DetailAnalysisRoute route) => switch (route.intent) {
    DetailAnalysisIntent.detailAnalysis => 'Analyzing datasets…',
    DetailAnalysisIntent.customerCleaning => 'Cleaning customer data…',
    DetailAnalysisIntent.productCleaning => 'Cleaning product data…',
    DetailAnalysisIntent.orderCleaning => 'Cleaning order data…',
    DetailAnalysisIntent.dateDimension => 'Building date dimension…',
    DetailAnalysisIntent.businessAnalysis =>
      'Calculating business performance…',
    DetailAnalysisIntent.customerDataQuality =>
      'Analyzing customer data quality…',
    DetailAnalysisIntent.dashboard => 'Building dashboard…',
    DetailAnalysisIntent.unknown => 'Checking supported local workflows…',
  };

  String _resultLabel(DetailAnalysisRoute route) => switch (route.intent) {
    DetailAnalysisIntent.detailAnalysis =>
      route.subIntent?.startsWith('data_quality:') == true
          ? 'Here are the ${route.subIntent!.split(':').last} data-quality findings from Detail Analysis.'
          : 'Here is the complete Detail Analysis result.',
    DetailAnalysisIntent.customerCleaning =>
      'Customer cleaning completed locally.',
    DetailAnalysisIntent.productCleaning =>
      'Product cleaning completed locally.',
    DetailAnalysisIntent.orderCleaning => 'Order cleaning completed locally.',
    DetailAnalysisIntent.dateDimension =>
      'The date dimension was created locally.',
    DetailAnalysisIntent.businessAnalysis =>
      route.subIntent == 'regional_profit'
          ? 'Here is the regional profit analysis.'
          : 'Here is the business analysis result.',
    DetailAnalysisIntent.customerDataQuality =>
      'Here are the customer data-quality findings from Detail Analysis.',
    DetailAnalysisIntent.dashboard => 'The interactive dashboard is ready.',
    DetailAnalysisIntent.unknown => '',
  };

  void _setDetailResult(Map<String, dynamic> result) {
    _result = result;
    final answer = result['analyst_answer'];
    final findings = answer is Map ? answer['findings'] : null;
    if (findings is List) {
      _lastFindings = findings
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      _lastSelectedFindingId = _lastFindings.isEmpty
          ? null
          : _lastFindings.first['id']?.toString();
    }
    final html = result['readable_report_html'];
    if (html is! String || html.trim().isEmpty) {
      _reportHtml = null;
      return;
    }
    final parts = _splitSchemaSection(html);
    final nextVersion = _reportVersion + 1;
    _registerReportFrame(
      'detail-report-before-$nextVersion',
      parts?.$1 ?? html,
    );
    if (parts != null)
      _registerReportFrame('detail-report-after-$nextVersion', parts.$2);
    _reportHtml = html;
    _reportBeforeSchema = parts?.$1;
    _reportAfterSchema = parts?.$2;
    _reportVersion = nextVersion;
  }

  bool _isFullReportQuery(String query) => RegExp(
    r'\b(full|complete|report|profiling)\b|detail\s+analysis',
    caseSensitive: false,
  ).hasMatch(query);

  String _conciseAnswer(Map<String, dynamic> result, String query) {
    final answer = result['analyst_answer'];
    if (answer is Map && answer['short_answer'] is String) {
      final scope = RegExp(
        r'\b(customer|customers|product|products|order|orders|region|regions)\b',
        caseSensitive: false,
      ).firstMatch(query)?.group(1)?.toLowerCase();
      final normalizedScope = scope == null
          ? null
          : (scope.endsWith('s')
                ? scope.substring(0, scope.length - 1)
                : scope);
      final scoped = answer['short_answers'];
      if (normalizedScope != null &&
          scoped is Map &&
          scoped[normalizedScope] is String) {
        return scoped[normalizedScope] as String;
      }
      final findings = answer['findings'];
      if (RegExp(
            r'\b(biggest|most|highest|serious)\b',
            caseSensitive: false,
          ).hasMatch(query) &&
          findings is List &&
          findings.isNotEmpty) {
        final first = Map<String, dynamic>.from(findings.first as Map);
        return '${first['category']}: ${first['evidence'] ?? 'locally evidenced finding'}\n\nRecommendation: address this finding before modeling.';
      }
      return answer['short_answer'] as String;
    }
    return _resultLabel(
      const DetailAnalysisRoute(DetailAnalysisIntent.detailAnalysis),
    );
  }

  Map<String, dynamic>? _resolveLocalFollowUp(String query) {
    if (_lastFindings.isEmpty) return null;
    final normalized = query.toLowerCase();
    final isWhy = RegExp(
      r'\bwhy\b|\bmatters?\b|\bimportant\b|\bexplain\b',
    ).hasMatch(normalized);
    final isFix = RegExp(
      r'\bfix\b|\brepair\b|\bresolve\b|\bdo\s+that\b',
    ).hasMatch(normalized);
    if (!isWhy && !isFix) return null;
    var finding = _lastFindings.firstWhere(
      (item) => item['id']?.toString() == _lastSelectedFindingId,
      orElse: () => _lastFindings.first,
    );
    if (RegExp(r'\bmost\b|\bbiggest\b|\bserious\b').hasMatch(normalized)) {
      const order = {
        'confirmed_issue': 3,
        'needs_review': 2,
        'warning': 2,
        'minor_observation': 1,
        'passed': 0,
      };
      finding = _lastFindings.reduce(
        (left, right) =>
            (order[left['severity']] ?? 0) >= (order[right['severity']] ?? 0)
            ? left
            : right,
      );
      _lastSelectedFindingId = finding['id']?.toString();
    }
    if (isWhy) return {'kind': 'why', 'finding': finding};
    final category = finding['category']?.toString();
    final scope = _lastRoute?.subIntent?.split(':').last;
    if ((category == 'duplicate_records' ||
            category == 'business_key_not_unique') &&
        scope == 'customer') {
      return {
        'kind': 'clean',
        'route': const DetailAnalysisRoute(
          DetailAnalysisIntent.customerCleaning,
        ),
      };
    }
    return {
      'kind': 'review',
      'message':
          'This finding requires an approved local business rule before automatic fixing. No data was changed.',
    };
  }

  String _localFindingExplanation(Map<String, dynamic> finding) {
    final category = finding['category']?.toString() ?? 'finding';
    final evidence = finding['evidence'];
    final detail = evidence is Map && evidence.isNotEmpty
        ? ' Local evidence: ${evidence.entries.map((entry) => '${entry.key}=${entry.value}').join(', ')}.'
        : '';
    return 'Why this matters: $category can affect downstream analytical reliability and should be addressed according to its documented data-quality rule.$detail';
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.animateTo(
          _chatScrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _cleanCustomer() async {
    if (_files.isEmpty || _cleaningCustomer) return;
    setState(() => _cleaningCustomer = true);
    try {
      final result = await _service.cleanCustomer(_files);
      if (mounted) setState(() => _customerCleanResult = result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _cleaningCustomer = false);
    }
  }

  Future<void> _cleanProduct() async {
    if (_files.isEmpty || _cleaningProduct) return;
    setState(() => _cleaningProduct = true);
    try {
      final result = await _service.cleanProduct(_files);
      if (mounted) setState(() => _productCleanResult = result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _cleaningProduct = false);
    }
  }

  Future<void> _cleanOrders() async {
    if (_files.isEmpty || _cleaningOrders) return;
    setState(() => _cleaningOrders = true);
    try {
      final result = await _service.cleanOrders(_files);
      if (mounted) setState(() => _orderCleanResult = result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _cleaningOrders = false);
    }
  }

  Future<void> _buildDateDimension() async {
    if (_files.isEmpty || _buildingDateDimension) return;
    setState(() => _buildingDateDimension = true);
    try {
      final result = await _service.buildDateDimension(_files);
      if (mounted) setState(() => _dateDimensionResult = result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _buildingDateDimension = false);
    }
  }

  Future<void> _runBusinessAnalysis() async {
    if (_files.isEmpty || _runningBusinessAnalysis) return;
    setState(() => _runningBusinessAnalysis = true);
    try {
      final result = await _service.analyzeBusinessModel(_files);
      if (mounted) setState(() => _businessAnalysisResult = result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _runningBusinessAnalysis = false);
    }
  }

  Future<void> _loadDashboard() async {
    if (_files.isEmpty || _loadingDashboard) return;
    setState(() => _loadingDashboard = true);
    try {
      final result = await _service.buildDashboard(
        _files,
        year: _selectedDashboardYear,
        region: _selectedDashboardRegion,
        category: _selectedDashboardCategory,
      );
      if (mounted) setState(() => _dashboardResult = result);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loadingDashboard = false);
    }
  }

  void _resetDashboardFilters() {
    setState(() {
      _selectedDashboardYear = null;
      _selectedDashboardRegion = null;
      _selectedDashboardCategory = null;
    });
    _loadDashboard();
  }

  String _reportText() {
    final readable = _result?['readable_report'];
    if (readable is String && readable.trim().isNotEmpty) return readable;
    return const JsonEncoder.withIndent('  ').convert(_result);
  }

  void _registerReportFrame(String viewType, String html) {
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
      final frame = web.HTMLIFrameElement()
        ..srcdoc = _reportDocument(html).toJS
        ..style.border = '0'
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.overflow = 'hidden';
      void resizeFrame(web.Event _) {
        final frameSource = frame.contentWindow;
        if (frameSource != null &&
            !_reportFrameSources.any(
              (registered) => _sameJsObject(frameSource, registered).toDart,
            )) {
          _reportFrameSources.add(frameSource);
        }
        final body = frame.contentDocument?.body;
        if (!mounted || body == null) return;
        final height = (body.scrollHeight + 16).toDouble();
        if ((_reportFrameHeights[viewType] ?? 0) == height) return;
        setState(() => _reportFrameHeights[viewType] = height);
      }

      frame.addEventListener('load', resizeFrame.toJS);
      return frame;
    });
  }

  (String, String)? _splitSchemaSection(String html) {
    const start = '<h2>15. Proposed star schema</h2>';
    const end = '<h2>17. Assumptions and recommendation</h2>';
    final startIndex = html.indexOf(start);
    final endIndex = html.indexOf(end, startIndex + start.length);
    if (startIndex < 0 || endIndex < 0) return null;
    return (html.substring(0, startIndex), html.substring(endIndex));
  }

  String _reportDocument(String html) =>
      '''
<!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
html,body{overflow:hidden}body{margin:0;padding:8px;background:#0b1020;color:#e3e6ed;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:14px;line-height:1.45}
h1{color:#00e5ff;font-size:25px}h2{color:#66e7ff;font-size:18px;border-bottom:1px solid #26334d;padding-bottom:6px;margin-top:24px}
h3{color:#a8b8d8;font-size:15px}table{width:100%;border-collapse:collapse}th,td{border:1px solid #26334d;padding:7px;text-align:left;vertical-align:top}th{background:#14213a;color:#00e5ff}td{background:#0f172a}.muted{color:#9aa8c0}
.star-schema-diagram{position:relative;min-height:470px;overflow:hidden;border:1px solid #26334d;border-radius:14px;background:linear-gradient(145deg,#0f172a,#082f49)}.star-schema-links{position:absolute;inset:0;width:100%;height:100%;z-index:0}.schema-link{stroke:#7dd3fc;stroke-width:.55;stroke-dasharray:none}.schema-link-warning{stroke:#fbbf24;stroke-dasharray:2 1}.schema-link-label{fill:#b8c5d9;font-size:2.6px;text-anchor:middle}.star-node{position:absolute;z-index:1;transform:translate(-50%,-50%);width:210px;min-height:78px;padding:13px;border:1px solid #7dd3fc;border-radius:10px;background:#0f172a;box-shadow:0 8px 24px #02061799}.star-center{border-color:#00e5ff;background:#0e749066}.star-node span{display:block;color:#7dd3fc;font-size:10px;letter-spacing:.08em}.star-node small,.star-node em{display:block;margin-top:7px;color:#cbd5e1;font-size:11px;line-height:1.35}.star-node-warning{border-color:#fbbf24}.schema-warning{display:block;margin-top:7px;color:#fbbf24;font-size:10px}
@media(max-width:720px){.star-schema-diagram{display:flex;flex-direction:column;gap:12px;min-height:0;padding:14px}.star-schema-links{display:none}.star-node,.star-center{position:relative;left:auto!important;top:auto!important;transform:none;width:100%}.star-center{order:-1}}
</style></head><body>$html<script>
window.addEventListener('wheel', event => {
  if (!window.frameElement) return;
  event.preventDefault();
  parent.postMessage('detail-analysis-scroll|$_conversationSessionId|'
      + event.deltaY, '*');
}, {passive: false});
</script></body></html>''';

  /* duplicate migration helpers retained in the earlier state section
  Future<void> _sendMessage() async {
    final query = _chatController.text.trim();
    if (query.isEmpty || _files.isEmpty || _runningMessage != null) return;
    _chatController.clear();
    final route = routeDetailAnalysisMessage(query);
    setState(() {
      _chatHistory.add(_ChatMessage.user(query));
      _runningMessage = _loadingLabel(route);
    });
    try {
      Map<String, dynamic> result;
      switch (route.intent) {
        case DetailAnalysisIntent.detailAnalysis:
          result = await _service.analyze(_files);
          _setDetailResult(result);
          break;
        case DetailAnalysisIntent.customerCleaning:
          result = await _service.cleanCustomer(_files);
          _customerCleanResult = result;
          break;
        case DetailAnalysisIntent.productCleaning:
          result = await _service.cleanProduct(_files);
          _productCleanResult = result;
          break;
        case DetailAnalysisIntent.orderCleaning:
          result = await _service.cleanOrders(_files);
          _orderCleanResult = result;
          break;
        case DetailAnalysisIntent.dateDimension:
          result = await _service.buildDateDimension(_files);
          _dateDimensionResult = result;
          break;
        case DetailAnalysisIntent.businessAnalysis:
          result = await _service.analyzeBusinessModel(_files);
          _businessAnalysisResult = result;
          break;
        case DetailAnalysisIntent.dashboard:
          result = await _service.buildDashboard(
            _files,
            year: _selectedDashboardYear,
            region: _selectedDashboardRegion,
            category: _selectedDashboardCategory,
          );
          _dashboardResult = result;
          break;
        case DetailAnalysisIntent.unknown:
          setState(() {
            _runningMessage = null;
            _chatHistory.add(
              _ChatMessage.assistant(
                "I can help with profiling, cleaning, dimensional modeling, business analysis, and dashboards. Try 'Analyze these datasets'.",
              ),
            );
          });
          return;
      }
      if (mounted) {
        setState(() {
          _runningMessage = null;
          _chatHistory.add(
            _ChatMessage.assistant(
              _resultLabel(route),
              result: result,
              intent: route.intent,
            ),
          );
        });
        _scrollChatToEnd();
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _runningMessage = null;
          _chatHistory.add(
            _ChatMessage.assistant(
              "I couldn't complete that local operation. Check the selected files and try again.",
            ),
          );
        });
    }
  }

  String _loadingLabel(DetailAnalysisRoute route) => switch (route.intent) {
    DetailAnalysisIntent.detailAnalysis => 'Analyzing datasets…',
    DetailAnalysisIntent.customerCleaning => 'Cleaning customer data…',
    DetailAnalysisIntent.productCleaning => 'Cleaning product data…',
    DetailAnalysisIntent.orderCleaning => 'Cleaning order data…',
    DetailAnalysisIntent.dateDimension => 'Building date dimension…',
    DetailAnalysisIntent.businessAnalysis =>
      'Calculating business performance…',
    DetailAnalysisIntent.dashboard => 'Building dashboard…',
    DetailAnalysisIntent.unknown => 'Checking supported local workflows…',
  };

  String _resultLabel(DetailAnalysisRoute route) => switch (route.intent) {
    DetailAnalysisIntent.detailAnalysis =>
      'Here is the complete Detail Analysis result.',
    DetailAnalysisIntent.customerCleaning =>
      'Customer cleaning completed locally.',
    DetailAnalysisIntent.productCleaning =>
      'Product cleaning completed locally.',
    DetailAnalysisIntent.orderCleaning => 'Order cleaning completed locally.',
    DetailAnalysisIntent.dateDimension =>
      'The date dimension was created locally.',
    DetailAnalysisIntent.businessAnalysis =>
      route.subIntent == 'regional_profit'
          ? 'Here is the regional profit analysis.'
          : 'Here is the business analysis result.',
    DetailAnalysisIntent.dashboard => 'The interactive dashboard is ready.',
    DetailAnalysisIntent.unknown => '',
  };

  void _setDetailResult(Map<String, dynamic> result) {
    _result = result;
    final html = result['readable_report_html'];
    if (html is! String || html.trim().isEmpty) {
      _reportHtml = null;
      return;
    }
    final parts = _splitSchemaSection(html);
    final version = ++_reportVersion;
    _registerReportFrame('detail-report-before-$version', parts?.$1 ?? html);
    if (parts != null)
      _registerReportFrame('detail-report-after-$version', parts.$2);
    _reportHtml = html;
    _reportBeforeSchema = parts?.$1;
    _reportAfterSchema = parts?.$2;
  }

  void _scrollChatToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients)
        _chatScrollController.jumpTo(
          _chatScrollController.position.maxScrollExtent,
        );
    });
  }

  */

  Widget _buildChatFirst(BuildContext context) {
    final ready = _files.isNotEmpty;
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: TechAnimatedBackground()),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 18, 22, 10),
                      child: _header(),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 22),
                        child: GlassCard(
                          padding: EdgeInsets.zero,
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 22,
                          ),
                          child: Column(
                            children: [
                              _DatasetSessionBar(
                                files: _files,
                                onChange: _analyze,
                              ),
                              Expanded(child: _buildChatHistory(context)),
                              _buildComposer(context, ready),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatHistory(BuildContext context) {
    if (_chatHistory.isEmpty) return _EmptyChat(onUpload: _analyze);
    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
      itemCount: _chatHistory.length + (_runningMessage == null ? 0 : 1),
      itemBuilder: (context, index) => index == _chatHistory.length
          ? _TypingBubble(text: _runningMessage!)
          : _ChatMessageView(
              message: _chatHistory[index],
              resultBuilder: _buildResultWidget,
              onSuggestionSelected: _sendSuggestedQuery,
            ),
    );
  }

  Widget _buildComposer(BuildContext context, bool ready) => Padding(
    padding: const EdgeInsets.all(14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _chatController,
            enabled: _runningMessage == null,
            minLines: 1,
            maxLines: 4,
            onSubmitted: (_) => _sendMessage(),
            decoration: InputDecoration(
              hintText: ready
                  ? 'Ask about your data…'
                  : 'Ask about InsightFlow or upload datasets to analyze…',
              filled: true,
              fillColor: Colors.white.withValues(alpha: .07),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        IconButton.filled(
          onPressed: _runningMessage == null ? _sendMessage : null,
          icon: const Icon(Icons.send_rounded),
        ),
      ],
    ),
  );

  Widget _buildResultWidget(BuildContext context, _ChatMessage message) {
    final result = message.result;
    if (result == null) return const SizedBox.shrink();
    return switch (message.intent ?? DetailAnalysisIntent.unknown) {
      DetailAnalysisIntent.detailAnalysis =>
        message.subIntent?.startsWith('data_quality:') == true
            ? _analystQualityWidget(
                result,
                scope: message.subIntent!.split(':').last,
              )
            : _detailResultWidget(),
      DetailAnalysisIntent.customerCleaning => _CustomerCleanSummary(
        result: result,
      ),
      DetailAnalysisIntent.productCleaning => _ProductCleanSummary(
        result: result,
      ),
      DetailAnalysisIntent.orderCleaning => _OrderCleanSummary(result: result),
      DetailAnalysisIntent.dateDimension => _DateDimensionSummary(
        result: result,
      ),
      DetailAnalysisIntent.businessAnalysis =>
        result['report'] is Map
            ? _ReportSummary(result: result)
            : _BusinessAnalysisSummary(
                result: result,
                subIntent: message.subIntent,
              ),
      DetailAnalysisIntent.customerDataQuality => _analystQualityWidget(
        result,
        scope: 'customer',
      ),
      DetailAnalysisIntent.dashboard => _DashboardCard(
        result: result,
        selectedYear: _selectedDashboardYear,
        selectedRegion: _selectedDashboardRegion,
        selectedCategory: _selectedDashboardCategory,
        onYearChanged: (value) {
          setState(() => _selectedDashboardYear = value);
          _loadDashboard();
        },
        onRegionChanged: (value) {
          setState(() => _selectedDashboardRegion = value);
          _loadDashboard();
        },
        onCategoryChanged: (value) {
          setState(() => _selectedDashboardCategory = value);
          _loadDashboard();
        },
        onReset: _resetDashboardFilters,
      ),
      DetailAnalysisIntent.unknown => const SizedBox.shrink(),
    };
  }

  Widget _detailResultWidget() {
    if (_reportHtml != null &&
        _reportBeforeSchema != null &&
        _reportAfterSchema != null) {
      return Column(
        children: [
          SizedBox(
            height:
                _reportFrameHeights['detail-report-before-$_reportVersion'] ??
                2700,
            child: HtmlElementView(
              viewType: 'detail-report-before-$_reportVersion',
            ),
          ),
          StarSchemaView(
            schema: _result?['star_schema'] is Map
                ? Map<String, dynamic>.from(_result!['star_schema'] as Map)
                : const <String, dynamic>{},
          ),
          SizedBox(
            height:
                _reportFrameHeights['detail-report-after-$_reportVersion'] ??
                520,
            child: HtmlElementView(
              viewType: 'detail-report-after-$_reportVersion',
            ),
          ),
        ],
      );
    }
    if (_reportHtml != null)
      return SizedBox(
        height:
            _reportFrameHeights['detail-report-before-$_reportVersion'] ?? 1100,
        child: HtmlElementView(
          viewType: 'detail-report-before-$_reportVersion',
        ),
      );
    return SelectableText(_reportText());
  }

  Widget _analystQualityWidget(
    Map<String, dynamic> result, {
    String scope = 'customer',
  }) {
    final answer = result['analyst_answer'];
    if (answer is Map) {
      final response = AnalystQualityMessage.fromAnalystAnswer(
        Map<String, dynamic>.from(answer),
        scope: scope,
      );
      if (response != null) {
        return AnalystQualityMessage(response: response);
      }
    }
    return SelectableText(_conciseAnswer(result, 'customer issues'));
  }

  @override
  Widget build(BuildContext context) {
    return _buildChatFirst(context);
    /* legacy action-centric layout retained below for reference during migration
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: TechAnimatedBackground()),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1180),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(),
                      const SizedBox(height: 18),
                      GlassCard(
                        padding: const EdgeInsets.all(20),
                        shape: const LiquidRoundedSuperellipse(
                          borderRadius: 22,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Profile exported Power BI tables without changing them.',
                              style: TextStyle(fontSize: 14, height: 1.4),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Read-only analysis of CSV, TSV, Excel, and JSON datasets.',
                              style: TextStyle(
                                fontSize: 12,
                                color: CupertinoColors.secondaryLabel
                                    .resolveFrom(context),
                              ),
                            ),
                            const SizedBox(height: 16),
                            if (_files.isNotEmpty)
                              Text(
                                '${_files.length} file(s): ${_files.map((file) => file.name).join(', ')}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            const SizedBox(height: 14),
                            GlassButton(
                              onTap: _loading ? () {} : _analyze,
                              enabled: !_loading,
                              width: double.infinity,
                              height: 48,
                              shape: const LiquidRoundedSuperellipse(
                                borderRadius: 14,
                              ),
                              icon: _loading
                                  ? const CupertinoActivityIndicator()
                                  : const Icon(CupertinoIcons.folder_open),
                              label: _loading
                                  ? 'Profiling datasets…'
                                  : (_result == null
                                        ? 'Choose Files and Analyze'
                                        : 'Analyze Again'),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: Theme.of(context).colorScheme.error,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (_result != null) ...[
                        const SizedBox(height: 18),
                        GlassCard(
                          padding: const EdgeInsets.all(12),
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 22,
                          ),
                          child:
                              _reportHtml != null &&
                                  _reportBeforeSchema != null &&
                                  _reportAfterSchema != null
                              ? Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    SizedBox(
                                      height: 2700,
                                      child: HtmlElementView(
                                        viewType:
                                            'detail-report-before-$_reportVersion',
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    StarSchemaView(
                                      schema: _result?['star_schema'] is Map
                                          ? Map<String, dynamic>.from(
                                              _result!['star_schema'] as Map,
                                            )
                                          : const <String, dynamic>{},
                                    ),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      height: 520,
                                      child: HtmlElementView(
                                        viewType:
                                            'detail-report-after-$_reportVersion',
                                      ),
                                    ),
                                  ],
                                )
                              : _reportHtml != null
                              ? SizedBox(
                                  height: 1100,
                                  child: HtmlElementView(
                                    viewType:
                                        'detail-report-before-$_reportVersion',
                                  ),
                                )
                              : SelectableText(_reportText()),
                        ),
                        const SizedBox(height: 18),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 18,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Clean customer dimension',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Create a new dim_customer result without modifying raw files.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                              const SizedBox(height: 10),
                              GlassButton(
                                onTap: _cleaningCustomer
                                    ? () {}
                                    : _cleanCustomer,
                                enabled: !_cleaningCustomer,
                                width: double.infinity,
                                height: 42,
                                icon: _cleaningCustomer
                                    ? const CupertinoActivityIndicator()
                                    : const Icon(CupertinoIcons.layers_alt),
                                label: _cleaningCustomer
                                    ? 'Creating dimension…'
                                    : 'Create dim_customer',
                              ),
                              if (_customerCleanResult != null) ...[
                                const SizedBox(height: 12),
                                _CustomerCleanSummary(
                                  result: _customerCleanResult!,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 18,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Clean product dimension',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Create a new dim_product result with audited category mappings.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                              const SizedBox(height: 10),
                              GlassButton(
                                onTap: _cleaningProduct ? () {} : _cleanProduct,
                                enabled: !_cleaningProduct,
                                width: double.infinity,
                                height: 42,
                                icon: _cleaningProduct
                                    ? const CupertinoActivityIndicator()
                                    : const Icon(CupertinoIcons.tag),
                                label: _cleaningProduct
                                    ? 'Creating dimension…'
                                    : 'Create dim_product',
                              ),
                              if (_productCleanResult != null) ...[
                                const SizedBox(height: 12),
                                _ProductCleanSummary(
                                  result: _productCleanResult!,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 18,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Clean order fact',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Create a new fact_orders result with audited duplicate, date, and FK handling.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                              const SizedBox(height: 10),
                              GlassButton(
                                onTap: _cleaningOrders ? () {} : _cleanOrders,
                                enabled: !_cleaningOrders,
                                width: double.infinity,
                                height: 42,
                                icon: _cleaningOrders
                                    ? const CupertinoActivityIndicator()
                                    : const Icon(CupertinoIcons.cart),
                                label: _cleaningOrders
                                    ? 'Creating fact…'
                                    : 'Create fact_orders',
                              ),
                              if (_orderCleanResult != null) ...[
                                const SizedBox(height: 12),
                                _OrderCleanSummary(result: _orderCleanResult!),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 18,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Build date dimension',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Create dim_date from valid dates in the cleaned fact.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                              const SizedBox(height: 10),
                              GlassButton(
                                onTap: _buildingDateDimension
                                    ? () {}
                                    : _buildDateDimension,
                                enabled: !_buildingDateDimension,
                                width: double.infinity,
                                height: 42,
                                icon: _buildingDateDimension
                                    ? const CupertinoActivityIndicator()
                                    : const Icon(CupertinoIcons.calendar),
                                label: _buildingDateDimension
                                    ? 'Building dimension…'
                                    : 'Create dim_date',
                              ),
                              if (_dateDimensionResult != null) ...[
                                const SizedBox(height: 12),
                                _DateDimensionSummary(
                                  result: _dateDimensionResult!,
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),
                        GlassCard(
                          padding: const EdgeInsets.all(16),
                          shape: const LiquidRoundedSuperellipse(
                            borderRadius: 18,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Business analysis',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                'Analyze the cleaned fact and dimensions with deterministic Chapter 6 metrics.',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: CupertinoColors.secondaryLabel,
                                ),
                              ),
                              const SizedBox(height: 10),
                              GlassButton(
                                onTap: _runningBusinessAnalysis
                                    ? () {}
                                    : _runBusinessAnalysis,
                                enabled: !_runningBusinessAnalysis,
                                width: double.infinity,
                                height: 42,
                                icon: _runningBusinessAnalysis
                                    ? const CupertinoActivityIndicator()
                                    : const Icon(
                                        CupertinoIcons.chart_bar_square,
                                      ),
                                label: _runningBusinessAnalysis
                                    ? 'Analyzing model…'
                                    : 'Run business analysis',
                              ),
                              if (_businessAnalysisResult != null) ...[
                                const SizedBox(height: 12),
                                _BusinessAnalysisSummary(
                                  result: _businessAnalysisResult!,
                                ),
                                const SizedBox(height: 14),
                                GlassButton(
                                  onTap: _loadingDashboard
                                      ? () {}
                                      : _loadDashboard,
                                  enabled: !_loadingDashboard,
                                  width: double.infinity,
                                  height: 42,
                                  icon: _loadingDashboard
                                      ? const CupertinoActivityIndicator()
                                      : const Icon(CupertinoIcons.chart_bar),
                                  label: _loadingDashboard
                                      ? 'Loading dashboard…'
                                      : 'Open interactive dashboard',
                                ),
                              ],
                            ],
                          ),
                        ),
                        if (_dashboardResult != null) ...[
                          const SizedBox(height: 18),
                          _DashboardCard(
                            result: _dashboardResult!,
                            selectedYear: _selectedDashboardYear,
                            selectedRegion: _selectedDashboardRegion,
                            selectedCategory: _selectedDashboardCategory,
                            onYearChanged: (value) {
                              setState(() => _selectedDashboardYear = value);
                              _loadDashboard();
                            },
                            onRegionChanged: (value) {
                              setState(() => _selectedDashboardRegion = value);
                              _loadDashboard();
                            },
                            onCategoryChanged: (value) {
                              setState(
                                () => _selectedDashboardCategory = value,
                              );
                              _loadDashboard();
                            },
                            onReset: _resetDashboardFilters,
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

    */
  }

  Widget _header() {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: TechColors.borderActive.withValues(alpha: 0.16),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            CupertinoIcons.chart_bar_fill,
            color: TechColors.borderActive,
          ),
        ),
        const SizedBox(width: 12),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'DETAIL ANALYSIS',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
              ),
            ),
            Text(
              'Power BI data-model readiness',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        const Spacer(),
        Semantics(
          label: 'System status and diagnostics',
          button: true,
          child: const SystemStatusButton(),
        ),
      ],
    );
  }
}

class _ChatMessage {
  const _ChatMessage({
    required this.text,
    required this.user,
    this.result,
    this.intent,
    this.subIntent,
    this.suggestions = const <Map<String, dynamic>>[],
    this.sessionSummary,
  });
  const _ChatMessage.user(String text) : this(text: text, user: true);
  const _ChatMessage.assistant(
    String text, {
    Map<String, dynamic>? result,
    DetailAnalysisIntent? intent,
    String? subIntent,
    List<Map<String, dynamic>> suggestions = const <Map<String, dynamic>>[],
    Map<String, dynamic>? sessionSummary,
  }) : this(
         text: text,
         user: false,
         result: result,
         intent: intent,
         subIntent: subIntent,
         suggestions: suggestions,
         sessionSummary: sessionSummary,
       );

  final String text;
  final bool user;
  final Map<String, dynamic>? result;
  final DetailAnalysisIntent? intent;
  final String? subIntent;
  final List<Map<String, dynamic>> suggestions;
  final Map<String, dynamic>? sessionSummary;
}

class _ChatMessageView extends StatefulWidget {
  const _ChatMessageView({
    required this.message,
    required this.resultBuilder,
    required this.onSuggestionSelected,
  });
  final _ChatMessage message;
  final Widget Function(BuildContext, _ChatMessage) resultBuilder;
  final ValueChanged<String> onSuggestionSelected;

  @override
  State<_ChatMessageView> createState() => _ChatMessageViewState();
}

class _ChatMessageViewState extends State<_ChatMessageView> {
  bool _copied = false;

  String _copyText(_ChatMessage message) {
    if (!message.user &&
        message.intent == DetailAnalysisIntent.businessAnalysis) {
      return _BusinessAnalysisSummary.copyText(
        message.result ?? const <String, dynamic>{},
        subIntent: message.subIntent,
      );
    }
    if (!message.user &&
        (message.intent == DetailAnalysisIntent.customerDataQuality ||
            message.subIntent?.startsWith('data_quality:') == true) &&
        message.result?['analyst_answer'] is Map) {
      final scope = message.subIntent?.split(':').last ?? 'customer';
      final response = AnalystQualityMessage.fromAnalystAnswer(
        Map<String, dynamic>.from(message.result!['analyst_answer'] as Map),
        scope: scope,
      );
      if (response != null) return AnalystQualityMessage.toCopyText(response);
    }
    return message.text;
  }

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final isStructuredQuality =
        !message.user &&
        (message.intent == DetailAnalysisIntent.customerDataQuality ||
            message.subIntent?.startsWith('data_quality:') == true);
    final hasStructuredQualityResponse =
        isStructuredQuality &&
        message.result?['analyst_answer'] is Map &&
        AnalystQualityMessage.fromAnalystAnswer(
              Map<String, dynamic>.from(
                message.result!['analyst_answer'] as Map,
              ),
              scope: message.subIntent?.split(':').last ?? 'customer',
            ) !=
            null;
    final hasStructuredBusinessResponse =
        !message.user &&
        message.intent == DetailAnalysisIntent.businessAnalysis &&
        message.result?['analyst_business_response'] is Map;
    final useSharedSelection =
        hasStructuredQualityResponse || hasStructuredBusinessResponse;
    final color = message.user
        ? TechColors.borderActive.withValues(alpha: .22)
        : Colors.white.withValues(alpha: .06);
    return Align(
      alignment: message.user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        width: message.result == null ? null : double.infinity,
        constraints: BoxConstraints(
          maxWidth: message.result == null
              ? MediaQuery.sizeOf(context).width * .78
              : double.infinity,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(17),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.user ? 'YOU' : 'VIBE ANALYSIS',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 1,
                color: message.user
                    ? TechColors.borderActive
                    : CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 6),
            if (!hasStructuredQualityResponse && !hasStructuredBusinessResponse)
              SelectableText(
                message.text,
                style: const TextStyle(fontSize: 13, height: 1.35),
              ),
            if (!message.user)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(text: _copyText(message)),
                    );
                    if (!mounted) return;
                    setState(() => _copied = true);
                    Future<void>.delayed(const Duration(seconds: 2), () {
                      if (mounted) setState(() => _copied = false);
                    });
                  },
                  icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
                  label: Text(_copied ? 'Copied' : 'Copy'),
                ),
              ),
            if (message.result != null) ...[
              const SizedBox(height: 14),
              useSharedSelection
                  ? SelectionArea(child: widget.resultBuilder(context, message))
                  : widget.resultBuilder(context, message),
            ],
            if (message.sessionSummary != null)
              AnalystSessionSummary(summary: message.sessionSummary!),
            if (!message.user && message.suggestions.isNotEmpty)
              AnalystSuggestions(
                suggestions: message.suggestions,
                onSelected: widget.onSuggestionSelected,
              ),
          ],
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 14),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text(
            text,
            style: TextStyle(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
              fontSize: 12,
            ),
          ),
        ],
      ),
    ),
  );
}

class _DatasetSessionBar extends StatelessWidget {
  const _DatasetSessionBar({required this.files, required this.onChange});
  final List<PlatformFile> files;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final ready = files.isNotEmpty;
      final compact = constraints.maxWidth < 520;
      final title = Row(
        children: [
          Icon(
            ready ? Icons.folder_copy_rounded : Icons.upload_file_rounded,
            color: TechColors.borderActive,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ready
                  ? '${files.length} dataset${files.length == 1 ? '' : 's'} ready'
                  : 'Upload datasets to start',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
          TextButton(
            onPressed: onChange,
            child: Text(ready ? 'Change' : 'Choose files'),
          ),
        ],
      );
      final filenames = Text(
        files.map((file) => file.name).join('  •  '),
        maxLines: compact ? 2 : 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 11,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      );
      return Container(
        padding: const EdgeInsets.fromLTRB(18, 15, 14, 13),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .04),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
        ),
        child: compact
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  title,
                  if (ready) ...[
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.only(left: 30),
                      child: filenames,
                    ),
                  ],
                ],
              )
            : Row(
                children: [
                  Icon(
                    ready
                        ? Icons.folder_copy_rounded
                        : Icons.upload_file_rounded,
                    color: TechColors.borderActive,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    ready
                        ? '${files.length} dataset${files.length == 1 ? '' : 's'} ready'
                        : 'Upload datasets to start',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (ready) Expanded(child: filenames),
                  TextButton(
                    onPressed: onChange,
                    child: Text(ready ? 'Change' : 'Choose files'),
                  ),
                ],
              ),
      );
    },
  );
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({required this.onUpload});
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.auto_awesome_rounded,
            color: TechColors.borderActive,
            size: 34,
          ),
          const SizedBox(height: 12),
          const Text(
            'Your local AI Data Analyst',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            'Upload one or more datasets, then ask for profiling, cleaning, modeling, business analysis, or a dashboard.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
              fontSize: 13,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onUpload,
            icon: const Icon(Icons.upload_file_rounded),
            label: const Text('Choose datasets'),
          ),
        ],
      ),
    ),
  );
}

class _CustomerCleanSummary extends StatelessWidget {
  const _CustomerCleanSummary({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final summary = result['summary'] is Map
        ? Map<String, dynamic>.from(result['summary'] as Map)
        : const <String, dynamic>{};
    return SelectableText(
      'CUSTOMER CLEANING SUMMARY\n'
      'Source: ${result['source_dataset'] ?? 'not identified'}\n'
      'Raw rows: ${summary['raw_rows'] ?? 0}    Clean rows: ${summary['clean_rows'] ?? 0}\n'
      'Business key: ${summary['business_key'] ?? 'none'}\n'
      'Exact duplicates removed: ${summary['exact_duplicate_rows_removed'] ?? 0}\n'
      'Identical groups resolved: ${summary['identical_duplicate_key_groups_resolved'] ?? 0}\n'
      'Conflicting groups: ${summary['conflicting_duplicate_key_groups'] ?? 0}\n'
      'Final key uniqueness: ${summary['final_key_uniqueness_percent'] ?? 0}%\n'
      'Final dimension status: ${summary['status'] ?? result['status'] ?? 'unknown'}',
      style: const TextStyle(fontSize: 12, height: 1.45),
    );
  }
}

class _ProductCleanSummary extends StatelessWidget {
  const _ProductCleanSummary({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final summary = result['summary'] is Map
        ? Map<String, dynamic>.from(result['summary'] as Map)
        : const <String, dynamic>{};
    return SelectableText(
      'PRODUCT CLEANING SUMMARY\n'
      'Source: ${result['source_dataset'] ?? 'not identified'}\n'
      'Raw rows: ${summary['raw_rows'] ?? 0}    Clean rows: ${summary['clean_rows'] ?? 0}\n'
      'Business key: ${summary['business_key'] ?? 'none'}\n'
      'Representation issues resolved: ${summary['representation_issues_resolved'] ?? 0}\n'
      'Category/sub-category mismatches: ${summary['category_subcategory_mismatch_rows'] ?? 0}\n'
      'Review-required conflicts: ${summary['unresolved_business_conflicts'] ?? 0}\n'
      'Final key uniqueness: ${summary['final_key_uniqueness_percent'] ?? 0}%\n'
      'Final dimension status: ${summary['status'] ?? result['status'] ?? 'unknown'}',
      style: const TextStyle(fontSize: 12, height: 1.45),
    );
  }
}

class _OrderCleanSummary extends StatelessWidget {
  const _OrderCleanSummary({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final summary = result['summary'] is Map
        ? Map<String, dynamic>.from(result['summary'] as Map)
        : const <String, dynamic>{};
    final dates = result['date_handling'] is Map
        ? Map<String, dynamic>.from(result['date_handling'] as Map)
        : const <String, dynamic>{};
    final relationships = result['relationships'] is List
        ? (result['relationships'] as List).length
        : 0;
    final measures = result['measure_reconciliation'] is Map
        ? (result['measure_reconciliation'] as Map).length
        : 0;
    return SelectableText(
      'ORDER / FACT CLEANING SUMMARY\n'
      'Source: ${result['source_dataset'] ?? 'not identified'}    Fact: ${result['fact_name'] ?? 'not created'}\n'
      'BEFORE → AFTER rows: ${summary['raw_rows'] ?? 0} → ${summary['clean_rows'] ?? 0}\n'
      'Exact duplicates removed: ${summary['exact_duplicates_removed'] ?? 0}    Conflicting event keys: ${summary['conflicting_event_key_groups'] ?? 0}\n'
      'Invalid dates: ${summary['invalid_date_rows'] ?? dates['invalid_date_rows'] ?? 0}    Missing FK rows: ${summary['null_fk_rows'] ?? {}}\n'
      'Orphan FK rows: ${summary['orphan_fk_rows'] ?? {}}    Returns: ${summary['is_return_true'] ?? 0}\n'
      'Measures reconciled: $measures    Relationships: $relationships\n'
      'Status: ${result['status'] ?? 'unknown'}\n'
      'Next step: ${(result['model_readiness'] as Map?)?['next_step'] ?? 'Review unresolved quality items.'}',
      style: const TextStyle(fontSize: 12, height: 1.45),
    );
  }
}

class _DateDimensionSummary extends StatelessWidget {
  const _DateDimensionSummary({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final summary = result['summary'] is Map
        ? Map<String, dynamic>.from(result['summary'] as Map)
        : const <String, dynamic>{};
    final relationship = result['relationship'] is Map
        ? Map<String, dynamic>.from(result['relationship'] as Map)
        : const <String, dynamic>{};
    final preview = result['preview'] is List
        ? result['preview'] as List
        : const [];
    final rows = preview
        .take(3)
        .map((row) {
          final item = Map<String, dynamic>.from(row as Map);
          return '${item['date_key']} | ${item['date']} | ${item['day']} | ${item['month']} | ${item['month_name']} | ${item['quarter']} | ${item['year']}';
        })
        .join('\n');
    return SelectableText(
      'DATE DIMENSION BUILD SUMMARY\n'
      'Source fact: ${result['source_fact'] ?? 'not identified'}    Date field: ${result['date_field'] ?? 'none'}\n'
      'Valid dates: ${summary['valid_fact_date_rows'] ?? 0}    Invalid excluded: ${summary['invalid_fact_date_rows_excluded'] ?? 0}    Null excluded: ${summary['null_fact_date_rows_excluded'] ?? 0}\n'
      'Unique dates: ${summary['unique_valid_dates'] ?? 0}    Range: ${summary['earliest_date'] ?? 'none'} → ${summary['latest_date'] ?? 'none'}\n'
      'date_key: YYYYMMDD    Key uniqueness: ${summary['key_uniqueness_percent'] ?? 0}%\n'
      'Relationship: ${relationship['cardinality'] ?? 'unknown'}    Coverage: ${relationship['valid_fact_date_coverage'] ?? 0}%\n'
      'Status: ${result['status'] ?? 'unknown'}\n'
      'PREVIEW: date_key | date | day | month | month_name | quarter | year\n'
      '$rows',
      style: const TextStyle(fontSize: 12, height: 1.45),
    );
  }
}

class _ReportSummary extends StatelessWidget {
  const _ReportSummary({required this.result});
  final Map<String, dynamic> result;

  @override
  Widget build(BuildContext context) {
    final report = Map<String, dynamic>.from(result['report'] as Map);
    final scope = report['scope'] is Map ? report['scope'] as Map : const {};
    final filename =
        result['filename']?.toString() ?? 'Vibe_Analysis_Report.pdf';
    final url = result['download_url']?.toString();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'REPORT GENERATED',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text('Type: ${result['report_type'] ?? 'detailed'}'),
        Text('Scope: ${scope.isEmpty ? 'All validated data' : scope}'),
        Text('Filename: $filename'),
        if (url != null) ...[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => web.window.open(
              Uri.parse('http://127.0.0.1:8000$url').toString(),
              '_blank',
            ),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open PDF'),
          ),
        ],
      ],
    );
  }
}

class _BusinessAnalysisSummary extends StatelessWidget {
  const _BusinessAnalysisSummary({required this.result, this.subIntent});
  final Map<String, dynamic> result;
  final String? subIntent;

  static String copyText(Map<String, dynamic> result, {String? subIntent}) {
    final model = result['analyst_business_response'] is Map
        ? Map<String, dynamic>.from(result['analyst_business_response'] as Map)
        : null;
    if (model == null) return 'Business analysis is unavailable.';
    final lines = <String>[model['intro']?.toString() ?? ''];
    final tables = model['tables'] is Map
        ? Map<String, dynamic>.from(model['tables'] as Map)
        : const <String, dynamic>{};
    void addTable(String key) {
      final table = tables[key] is Map
          ? Map<String, dynamic>.from(tables[key] as Map)
          : null;
      if (table == null) return;
      final columns = (table['columns'] as List? ?? const [])
          .map((value) => value.toString())
          .toList();
      lines.addAll([
        '',
        table['title']?.toString() ?? key,
        columns.join(' | '),
      ]);
      for (final row in (table['rows'] as List? ?? const [])) {
        final item = Map<String, dynamic>.from(row as Map);
        lines.add(
          columns.map((column) => item[column]?.toString() ?? '').join(' | '),
        );
      }
    }

    if (model['response_type'] == 'analyst_insight_response') {
      lines.addAll(['', 'KEY INSIGHTS']);
      final filters = model['active_filters'] is Map
          ? Map<String, dynamic>.from(model['active_filters'] as Map)
          : const <String, dynamic>{};
      if (filters.isNotEmpty)
        lines.add(
          'Scope: ${filters.entries.map((entry) => '${entry.key}=${entry.value}').join(', ')}',
        );
      for (
        var index = 0;
        index < (model['insights'] as List? ?? const []).length;
        index++
      ) {
        final insight = Map<String, dynamic>.from(
          (model['insights'] as List)[index] as Map,
        );
        lines.addAll([
          '',
          '${index + 1}. ${insight['title']}',
          insight['summary'].toString(),
          'Evidence: ${(insight['evidence'] as List? ?? const []).join('; ')}',
        ]);
      }
      lines.addAll([
        '',
        'RECOMMENDATIONS',
        ...((model['recommendations'] as List? ?? const []).map(
          (value) => '- $value',
        )),
      ]);
      return lines.join('\n').trim();
    }

    if (model['response_type'] == 'analyst_comparison_response') {
      final scope = model['comparison_scope'] is Map
          ? Map<String, dynamic>.from(model['comparison_scope'] as Map)
          : const <String, dynamic>{};
      final comparison = model['comparison'] is Map
          ? Map<String, dynamic>.from(model['comparison'] as Map)
          : const <String, dynamic>{};
      lines.addAll([
        '',
        'COMPARISON',
        'Grain: ${scope['grain'] ?? 'n/a'}',
        'Entities: ${(scope['entities'] as List? ?? const []).join(' vs ')}',
        if (scope['time_scope'] != null) 'Time scope: ${scope['time_scope']}',
        '',
        (comparison['columns'] as List? ?? const [])
            .map((value) => value.toString())
            .join(' | '),
      ]);
      for (final raw in (comparison['rows'] as List? ?? const [])) {
        final row = Map<String, dynamic>.from(raw as Map);
        final columns = (comparison['columns'] as List? ?? const []).map(
          (value) => value.toString(),
        );
        lines.add(
          columns.map((column) => row[column]?.toString() ?? '').join(' | '),
        );
      }
      if (model['explanation'] != null)
        lines.addAll(['', 'EXPLANATION', model['explanation'].toString()]);
      lines.addAll([
        '',
        'RECOMMENDATIONS',
        ...((model['recommendations'] as List? ?? const []).map(
          (value) => '- $value',
        )),
      ]);
      return lines.join('\n').trim();
    }

    if (subIntent == 'filtered_business_performance') {
      final filters = model['active_filters'] is Map
          ? Map<String, dynamic>.from(model['active_filters'] as Map)
          : const <String, dynamic>{};
      lines.addAll([
        '',
        'BUSINESS PERFORMANCE',
        'ANALYSIS SCOPE',
        ...filters.entries.map(
          (entry) => '${_scopeLabel(entry.key)}: ${entry.value}',
        ),
        '',
        ...((model['kpis'] as List? ?? const []).whereType<Map>().map(
          (item) => '${item['label']}: ${item['value']}',
        )),
      ]);
      return lines.join('\n').trim();
    } else if (subIntent == 'regional_profit') {
      lines.addAll([
        '',
        'KEY INSIGHTS',
        ...((model['key_insights'] as List? ?? const [])
            .take(2)
            .map((value) => '- $value')),
      ]);
      addTable('business_regions');
    } else if (subIntent == 'region_member_profit') {
      lines.addAll([
        '',
        'KEY INSIGHTS',
        ...((model['key_insights'] as List? ?? const [])
            .take(2)
            .map((value) => '- $value')),
      ]);
      addTable('region_members');
    } else if (subIntent == 'margin_watchlist') {
      addTable('watchlist');
    } else if (subIntent == 'monthly_performance') {
      final trend = model['trend_summary'] is Map
          ? Map<String, dynamic>.from(model['trend_summary'] as Map)
          : const <String, dynamic>{};
      lines.addAll([
        '',
        'MONTHLY PERFORMANCE',
        'Period: ${trend['period'] ?? 'n/a'}',
        '',
        'TREND SUMMARY',
        ...((model['monthly_trend_insights'] as List? ?? const []).map(
          (value) => '- $value',
        )),
        '',
        'KEY MONTHS',
        'Highest revenue: ${trend['highest_revenue'] ?? 'n/a'}',
        'Highest profit: ${trend['highest_profit'] ?? 'n/a'}',
        'Lowest profit: ${trend['lowest_profit'] ?? 'n/a'}',
      ]);
      addTable('monthly');
      final caveat = (model['caveats'] as List? ?? const [])
          .map((value) => value.toString())
          .firstWhere(
            (value) =>
                value.toLowerCase().contains('invalid') ||
                value.toLowerCase().contains('unresolved'),
            orElse: () => '',
          );
      if (caveat.isNotEmpty) lines.addAll(['', 'ANALYTICAL NOTE', '- $caveat']);
      return lines.join('\n').trim();
    } else {
      lines.addAll([
        '',
        'BUSINESS PERFORMANCE OVERVIEW',
        ...((model['kpis'] as List? ?? const []).whereType<Map>().map(
          (item) => '${item['label']}: ${item['value']}',
        )),
        '',
        'KEY INSIGHTS',
        ...((model['key_insights'] as List? ?? const []).map(
          (value) => '- $value',
        )),
      ]);
      addTable('top_products');
      addTable('business_regions');
      addTable('watchlist');
      final trend = model['trend_summary'] is Map
          ? Map<String, dynamic>.from(model['trend_summary'] as Map)
          : const <String, dynamic>{};
      lines.addAll([
        '',
        'MONTHLY PERFORMANCE',
        'Period: ${trend['period'] ?? 'n/a'}',
        'Highest revenue: ${trend['highest_revenue'] ?? 'n/a'}',
        'Highest profit: ${trend['highest_profit'] ?? 'n/a'}',
        'Lowest profit: ${trend['lowest_profit'] ?? 'n/a'}',
      ]);
      addTable('monthly');
    }
    lines.addAll([
      '',
      'CAVEATS',
      ...((model['caveats'] as List? ?? const []).map((value) => '- $value')),
      '',
      'RECOMMENDATIONS',
      ...((model['recommendations'] as List? ?? const []).map(
        (value) => '- $value',
      )),
    ]);
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final model = result['analyst_business_response'] is Map
        ? Map<String, dynamic>.from(result['analyst_business_response'] as Map)
        : null;
    if (model == null) return const Text('Business analysis is unavailable.');
    final kpis = (model['kpis'] as List? ?? const []).whereType<Map>().toList();
    final insights = (model['key_insights'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final tables = model['tables'] is Map
        ? Map<String, dynamic>.from(model['tables'] as Map)
        : const <String, dynamic>{};
    final children = <Widget>[
      Text(
        model['intro']?.toString() ?? '',
        style: const TextStyle(fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 12),
      Text(
        subIntent == 'filtered_business_performance'
            ? 'FILTERED BUSINESS PERFORMANCE'
            : subIntent == 'regional_profit'
            ? 'BUSINESS REGION PROFIT'
            : subIntent == 'margin_watchlist'
            ? 'HIGH REVENUE / LOW MARGIN'
            : subIntent == 'monthly_performance'
            ? 'MONTHLY PERFORMANCE'
            : 'BUSINESS PERFORMANCE OVERVIEW',
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ];
    final chartSpec = model['chart_spec'] is Map
        ? Map<String, dynamic>.from(model['chart_spec'] as Map)
        : null;
    if (chartSpec != null &&
        (chartSpec['rows'] as List? ?? const []).isNotEmpty) {
      children.add(AnalystChart(spec: chartSpec));
    }
    if (model['response_type'] == 'analyst_insight_response') {
      final filters = model['active_filters'] is Map
          ? Map<String, dynamic>.from(model['active_filters'] as Map)
          : const <String, dynamic>{};
      final insightItems = (model['insights'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      children.addAll([
        const SizedBox(height: 10),
        const Text(
          'KEY INSIGHTS',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        if (filters.isNotEmpty)
          Text(
            'Scope: ${filters.entries.map((entry) => '${entry.key} = ${entry.value}').join(' • ')}',
          ),
        ...List<Widget>.generate(insightItems.length, (index) {
          final insight = Map<String, dynamic>.from(insightItems[index]);
          return Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: .035),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${index + 1}. ${insight['title'] ?? 'Insight'}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(insight['summary']?.toString() ?? ''),
                  const SizedBox(height: 6),
                  ...((insight['evidence'] as List? ?? const []).map(
                    (value) =>
                        Text('• $value', style: const TextStyle(fontSize: 12)),
                  )),
                ],
              ),
            ),
          );
        }),
        if (insightItems.isEmpty)
          Text(
            model['message']?.toString() ??
                'Not enough evidence for reliable insight discovery in this scope.',
          ),
        const SizedBox(height: 10),
        const Text(
          'RECOMMENDATIONS',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...((model['recommendations'] as List? ?? const []).map(
          (value) => Text('• $value'),
        )),
      ]);
    } else if (model['response_type'] == 'analyst_comparison_response') {
      final scope = model['comparison_scope'] is Map
          ? Map<String, dynamic>.from(model['comparison_scope'] as Map)
          : const <String, dynamic>{};
      children.addAll([
        const SizedBox(height: 10),
        const Text(
          'COMPARISON',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        Text('Grain: ${scope['grain'] ?? 'n/a'}'),
        Text(
          'Entities: ${(scope['entities'] as List? ?? const []).join(' vs ')}',
        ),
        if (scope['time_scope'] != null)
          Text('Time scope: ${scope['time_scope']}'),
        _table(model['comparison'], 'comparison'),
        if (model['explanation'] != null) ...[
          const SizedBox(height: 10),
          const Text(
            'EXPLANATION',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(model['explanation'].toString()),
        ],
        const SizedBox(height: 10),
        const Text(
          'RECOMMENDATIONS',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...((model['recommendations'] as List? ?? const []).map(
          (value) => Text('• $value'),
        )),
      ]);
    } else if (subIntent == null || subIntent == 'comparison_analysis') {
      children.add(
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kpis
              .map(
                (item) =>
                    Chip(label: Text('${item['label']}: ${item['value']}')),
              )
              .toList(),
        ),
      );
      children.addAll([
        const SizedBox(height: 12),
        const Text(
          'KEY INSIGHTS',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...insights.map((value) => Text('• $value')),
      ]);
      children.add(_table(tables['top_products'], 'top_products'));
      children.add(_table(tables['business_regions'], 'business_regions'));
      children.add(_table(tables['watchlist'], 'watchlist'));
    } else if (subIntent == 'filtered_business_performance') {
      final filters = model['active_filters'] is Map
          ? Map<String, dynamic>.from(model['active_filters'] as Map)
          : const <String, dynamic>{};
      children.addAll([
        const SizedBox(height: 10),
        const Text(
          'ANALYSIS SCOPE',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...filters.entries.map(
          (entry) => Text('${_scopeLabel(entry.key)}: ${entry.value}'),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: kpis
              .map(
                (item) =>
                    Chip(label: Text('${item['label']}: ${item['value']}')),
              )
              .toList(),
        ),
      ]);
    } else if (subIntent == 'regional_profit') {
      children.addAll(insights.take(2).map((value) => Text('• $value')));
      children.add(_table(tables['business_regions'], 'business_regions'));
    } else if (subIntent == 'region_member_profit') {
      children.addAll(insights.take(2).map((value) => Text('• $value')));
      children.add(_table(tables['region_members'], 'region_members'));
    } else if (subIntent == 'margin_watchlist') {
      children.add(_table(tables['watchlist'], 'watchlist'));
    } else {
      final trend = model['trend_summary'] is Map
          ? Map<String, dynamic>.from(model['trend_summary'] as Map)
          : const <String, dynamic>{};
      children.addAll([
        const SizedBox(height: 10),
        const Text(
          'TREND SUMMARY',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...((model['monthly_trend_insights'] as List? ?? const []).map(
          (value) => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('• $value'),
          ),
        )),
        const SizedBox(height: 10),
        const Text('KEY MONTHS', style: TextStyle(fontWeight: FontWeight.w700)),
        Text('Period: ${trend['period'] ?? 'n/a'}'),
        Text('Highest revenue: ${trend['highest_revenue'] ?? 'n/a'}'),
        Text('Highest profit: ${trend['highest_profit'] ?? 'n/a'}'),
        Text('Lowest profit: ${trend['lowest_profit'] ?? 'n/a'}'),
        _table(tables['monthly'], 'monthly'),
        const SizedBox(height: 10),
        const Text(
          'ANALYTICAL NOTE',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...((model['caveats'] as List? ?? const [])
            .map((value) => value.toString())
            .where(
              (value) =>
                  value.toLowerCase().contains('invalid') ||
                  value.toLowerCase().contains('unresolved'),
            )
            .map((value) => Text('• $value'))),
      ]);
    }
    if (subIntent != 'monthly_performance' &&
        subIntent != 'filtered_business_performance') {
      children.addAll([
        const SizedBox(height: 12),
        const Text(
          'RECOMMENDATIONS',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        ...((model['recommendations'] as List? ?? const []).map(
          (value) => Text('• $value'),
        )),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _table(dynamic raw, String key) {
    if (raw is! Map) return const SizedBox.shrink();
    final table = Map<String, dynamic>.from(raw);
    final columns = (table['columns'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final rows = (table['rows'] as List? ?? const [])
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            table['title']?.toString() ?? key,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: columns
                  .map((column) => DataColumn(label: Text(column)))
                  .toList(),
              rows: rows
                  .map(
                    (row) => DataRow(
                      cells: columns
                          .map(
                            (column) =>
                                DataCell(Text(row[column]?.toString() ?? '')),
                          )
                          .toList(),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  static String _scopeLabel(String key) => switch (key) {
    'business_region' => 'Business Region',
    'category' => 'Category',
    'product' => 'Product',
    'year' => 'Year',
    _ => key,
  };
}

String _scopeLabel(String key) => _BusinessAnalysisSummary._scopeLabel(key);

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({
    required this.result,
    required this.selectedYear,
    required this.selectedRegion,
    required this.selectedCategory,
    required this.onYearChanged,
    required this.onRegionChanged,
    required this.onCategoryChanged,
    required this.onReset,
  });
  final Map<String, dynamic> result;
  final int? selectedYear;
  final String? selectedRegion;
  final String? selectedCategory;
  final ValueChanged<int?> onYearChanged;
  final ValueChanged<String?> onRegionChanged;
  final ValueChanged<String?> onCategoryChanged;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final filters = result['available_filters'] is Map
        ? Map<String, dynamic>.from(result['available_filters'] as Map)
        : const <String, dynamic>{};
    final kpis = result['kpis'] is Map
        ? Map<String, dynamic>.from(result['kpis'] as Map)
        : const <String, dynamic>{};
    final monthly = result['monthly_trend'] is List
        ? result['monthly_trend'] as List
        : const [];
    final categories = result['revenue_by_category'] is List
        ? result['revenue_by_category'] as List
        : const [];
    final regions = result['profit_by_region'] is List
        ? result['profit_by_region'] as List
        : const [];
    final top = result['top_products'] is List
        ? result['top_products'] as List
        : const [];
    final years = (filters['year'] as List? ?? const [])
        .map((value) => int.tryParse(value.toString()))
        .whereType<int>()
        .toList();
    final regionValues = (filters['region'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final categoryValues = (filters['category'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final kpiText =
        'REVENUE ${_dashboardMoney(kpis['revenue'])}    PROFIT ${_dashboardMoney(kpis['profit'])}    ORDERS ${_dashboardCount(kpis['orders'])}    CUSTOMERS ${_dashboardCount(kpis['customers'])}    MARGIN ${_dashboardPercent(kpis['profit_margin'])}';
    String rows(
      List<dynamic> values,
      String Function(Map<String, dynamic>) line,
    ) => values
        .map((row) => line(Map<String, dynamic>.from(row as Map)))
        .join('\n');
    final topText = rows(
      top,
      (item) =>
          '${item['rank']}. ${item['product'] ?? item['product_id']} | ${_dashboardMoney(item['revenue'])} | ${_dashboardMoney(item['profit'])} | ${_dashboardPercent(item['profit_margin'])}',
    );
    final regionText = rows(
      regions,
      (item) =>
          '${item['rank']}. ${item['region']} | ${_dashboardMoney(item['revenue'])} | ${_dashboardMoney(item['profit'])} | ${_dashboardPercent(item['profit_margin'])}',
    );
    final categoryText = rows(
      categories,
      (item) => '${item['category']} | ${_dashboardMoney(item['revenue'])}',
    );
    final monthText = rows(
      monthly,
      (item) =>
          '${item['month_key']} | ${_dashboardMoney(item['revenue'])} | ${_dashboardMoney(item['profit'])}',
    );
    return GlassCard(
      padding: const EdgeInsets.all(16),
      shape: const LiquidRoundedSuperellipse(borderRadius: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Vibe Analysis - Sales Performance Dashboard',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 5),
          Text(
            result['filter_summary']?.toString() ?? 'All data',
            style: const TextStyle(
              fontSize: 12,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _DashboardPicker<int>(
                label: 'Year',
                value: selectedYear,
                values: years,
                onChanged: onYearChanged,
              ),
              _DashboardPicker<String>(
                label: 'Region',
                value: selectedRegion,
                values: regionValues,
                onChanged: onRegionChanged,
              ),
              _DashboardPicker<String>(
                label: 'Category',
                value: selectedCategory,
                values: categoryValues,
                onChanged: onCategoryChanged,
              ),
              TextButton(
                onPressed: onReset,
                child: const Text('Reset Filters'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            kpiText,
            style: const TextStyle(fontSize: 12, height: 1.45),
          ),
          if (result['empty'] == true) ...[
            const SizedBox(height: 14),
            const Text(
              'No data for selected filters.',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ] else ...[
            const SizedBox(height: 14),
            const Text(
              'MONTHLY SALES TREND',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const Text(
              'Revenue (blue) | Profit (amber)',
              style: TextStyle(
                fontSize: 11,
                color: CupertinoColors.secondaryLabel,
              ),
            ),
            SizedBox(
              height: 150,
              child: _DashboardChart(
                values: monthly,
                valueKey: 'revenue',
                secondaryKey: 'profit',
                labelKey: 'month_key',
              ),
            ),
            SelectableText(
              monthText,
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 14),
            const Text(
              'REVENUE BY CATEGORY',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SizedBox(
              height: 120,
              child: _DashboardChart(
                values: categories,
                valueKey: 'revenue',
                labelKey: 'category',
              ),
            ),
            SelectableText(
              categoryText,
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 14),
            const Text(
              'PROFIT BY REGION',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SizedBox(
              height: 120,
              child: _DashboardChart(
                values: regions,
                valueKey: 'profit',
                labelKey: 'region',
              ),
            ),
            SelectableText(
              regionText,
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 14),
            const Text(
              'TOP PRODUCTS',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            SelectableText(
              'Rank | Product | Revenue | Profit | Margin\n$topText',
              style: const TextStyle(fontSize: 11, height: 1.4),
            ),
          ],
          const SizedBox(height: 12),
          SelectableText(
            'DATA NOTES\n${(result['caveats'] as List? ?? const []).join('\n')}',
            style: const TextStyle(
              fontSize: 11,
              height: 1.4,
              color: CupertinoColors.secondaryLabel,
            ),
          ),
        ],
      ),
    );
  }
}

String _dashboardMoney(dynamic value) {
  final amount = value is num ? value.toDouble() : double.tryParse('$value');
  if (amount == null) return 'N/A';
  final absolute = amount.abs();
  if (absolute >= 1000000)
    return NumberFormat.compactCurrency(
      symbol: '\u20b9',
      decimalDigits: 2,
    ).format(amount);
  return NumberFormat.currency(
    symbol: '\u20b9',
    decimalDigits: 2,
  ).format(amount);
}

String _dashboardCount(dynamic value) {
  final count = value is num ? value.toInt() : int.tryParse('$value');
  return count == null ? 'N/A' : NumberFormat.decimalPattern().format(count);
}

String _dashboardPercent(dynamic value) {
  final ratio = value is num ? value.toDouble() : double.tryParse('$value');
  return ratio == null ? 'N/A' : NumberFormat.percentPattern().format(ratio);
}

class _DashboardPicker<T> extends StatelessWidget {
  const _DashboardPicker({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });
  final String label;
  final T? value;
  final List<T> values;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 170,
    child: InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          isExpanded: true,
          value: value,
          hint: const Text('All'),
          items: [
            DropdownMenuItem<T>(value: null, child: const Text('All')),
            ...values.map(
              (item) => DropdownMenuItem<T>(
                value: item,
                child: Text(item.toString(), overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
          onChanged: onChanged,
        ),
      ),
    ),
  );
}

class _DashboardChart extends StatelessWidget {
  const _DashboardChart({
    required this.values,
    required this.valueKey,
    this.secondaryKey,
    required this.labelKey,
  });
  final List values;
  final String valueKey;
  final String? secondaryKey;
  final String labelKey;

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _DashboardChartPainter(
      values: values,
      valueKey: valueKey,
      secondaryKey: secondaryKey,
      labelKey: labelKey,
    ),
    child: const SizedBox.expand(),
  );
}

class _DashboardChartPainter extends CustomPainter {
  const _DashboardChartPainter({
    required this.values,
    required this.valueKey,
    required this.secondaryKey,
    required this.labelKey,
  });
  final List values;
  final String valueKey;
  final String? secondaryKey;
  final String labelKey;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final primary = values
        .map((row) => (row[valueKey] as num?)?.toDouble() ?? 0)
        .toList();
    final secondary = secondaryKey == null
        ? <double>[]
        : values
              .map((row) => (row[secondaryKey] as num?)?.toDouble() ?? 0)
              .toList();
    final maxValue = [...primary, ...secondary]
        .map((value) => value.abs())
        .fold<double>(1, (max, value) => value > max ? value : max);
    final chart = Rect.fromLTWH(8, 8, size.width - 16, size.height - 28);
    final axis = Paint()..color = const Color(0x55777788);
    canvas.drawLine(
      Offset(chart.left, chart.bottom),
      Offset(chart.right, chart.bottom),
      axis,
    );
    void drawSeries(List<double> series, Color color) {
      if (series.isEmpty) return;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var index = 0; index < series.length; index++) {
        final x =
            chart.left +
            (series.length == 1
                ? chart.width / 2
                : chart.width * index / (series.length - 1));
        final y = chart.bottom - (series[index] / maxValue) * chart.height;
        if (index == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    drawSeries(primary, const Color(0xFF5CB8FF));
    drawSeries(secondary, const Color(0xFFFFB45C));
  }

  @override
  bool shouldRepaint(covariant _DashboardChartPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.valueKey != valueKey ||
      oldDelegate.secondaryKey != secondaryKey;
}
