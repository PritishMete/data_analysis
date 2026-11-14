// lib/features/neural_chat/chat_console.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../dashboard/data_screen.dart';

// Height of the scrolling message list only — does NOT include the header,
// input row, or the "RESULT SLICE" table shown below it. Adjust this one
// constant to resize just the message-history area.
const double _kChatHistoryHeight = 220;


class ChatConsole extends StatelessWidget {
  final DataScreenState state;
  final bool fullHeight;
  const ChatConsole({super.key, required this.state, this.fullHeight = false});

  @override
  Widget build(BuildContext context) {
    final chatCard = GlassCard(
      padding: EdgeInsets.zero,
      shape: const LiquidRoundedSuperellipse(borderRadius: 20),
      child: Column(
        children: [
          if (fullHeight)
            Expanded(child: _buildHistory(context))
          else
            SizedBox(height: _kChatHistoryHeight, child: _buildHistory(context)),
          GlassDivider(color: CupertinoColors.separator.resolveFrom(context)),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Expanded(
                  child: Shortcuts(
                    shortcuts: const <SingleActivator, Intent>{
                      SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                      SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
                    },
                    child: Actions(
                      actions: <Type, Action<Intent>>{
                        ActivateIntent: CallbackAction<ActivateIntent>(
                          onInvoke: (intent) {
                            if (!state.isSearchingChat) state.processChatQuery();
                            return null;
                          },
                        ),
                      },
                      child: GlassTextField(
                        controller: state.chatController,
                        placeholder: 'Ask about your data…',
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                GlassIconButton(
                  size: 40,
                  icon: state.isSearchingChat
                      ? const CupertinoActivityIndicator()
                      : const Icon(CupertinoIcons.paperplane_fill),
                  onPressed: state.isSearchingChat ? null : state.processChatQuery,
                ),
              ],
            ),
          ),
          if (state.chatFilteredRows.isNotEmpty) ...[
            GlassDivider(color: CupertinoColors.separator.resolveFrom(context)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'RESULT SLICE',
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel.resolveFrom(context),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => state.setState(() => state.chatFilteredRows.clear()),
                        child: const Text(
                          'Clear',
                          style: TextStyle(
                            color: CupertinoColors.systemRed,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _buildDataTable(context, state.chatFilteredHeaders, state.chatFilteredRows),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader('AI Chat'),
        if (fullHeight) Expanded(child: chatCard) else chatCard,
      ],
    );
  }

  Widget _buildHistory(BuildContext context) {
    if (state.chatHistory.isEmpty) {
      return Center(
        child: Text(
          'Ask something about your data',
          style: TextStyle(
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
            fontSize: 12,
          ),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: state.chatHistory.length,
      itemBuilder: (context, idx) {
        final msg = state.chatHistory[idx];
        return _ChatBubble(
          text: (msg['text'] ?? '').toString(),
          isUser: msg['sender'] == 'user',
        );
      },
    );
  }

  Widget _buildDataTable(BuildContext context, List<dynamic> headers, dynamic src) {
    final rows = src is List ? src : [];
    final labelColor = CupertinoColors.label.resolveFrom(context);
    final secondaryColor = CupertinoColors.secondaryLabel.resolveFrom(context);

    if (rows.isEmpty) {
      return Text('No matching rows.', style: TextStyle(color: secondaryColor, fontSize: 12));
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowColor: WidgetStateProperty.all(Colors.transparent),
        dataRowColor: WidgetStateProperty.all(Colors.transparent),
        headingRowHeight: 36,
        dataRowMinHeight: 32,
        dataRowMaxHeight: 38,
        columnSpacing: 20,
        dividerThickness: 0.3,
        columns: headers
            .map((h) => DataColumn(
          label: Text(
            h.toString(),
            style: TextStyle(color: secondaryColor, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ))
            .toList(),
        rows: rows
            .map((row) => DataRow(
          cells: headers.map((h) {
            final val = row is Map ? (row[h.toString()] ?? '') : '';
            return DataCell(Text(val.toString(), style: TextStyle(color: labelColor, fontSize: 12)));
          }).toList(),
        ))
            .toList(),
      ),
    );
  }
}

/// A single chat message bubble — user messages align right with an accent
/// tint, assistant replies align left on a neutral glass surface.
class _ChatBubble extends StatelessWidget {
  const _ChatBubble({required this.text, required this.isUser});

  final String text;
  final bool isUser;

  @override
  Widget build(BuildContext context) {
    final bubbleColor = isUser
        ? CupertinoColors.activeBlue.withValues(alpha: 0.9)
        : CupertinoColors.white.withValues(alpha: 0.08);
    final textColor = isUser ? CupertinoColors.white : CupertinoColors.label.resolveFrom(context);

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.72),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Text(text, style: TextStyle(color: textColor, fontSize: 13, height: 1.3)),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}