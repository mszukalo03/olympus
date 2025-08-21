import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../../../shared/shared.dart';
import '../../../shared/widgets/attachment_widgets.dart';
import '../../../core/core.dart';

/// MessageBubble
/// ---------------------------------------------------------------------------
/// Presentation widget for a single chat message.
///
/// Features:
/// • Distinguishes user / assistant / system / error roles via color + layout
/// • Renders assistant & system content as Markdown (selectable)
/// • Uses monospace + selectable text for user + error messages
/// • Provides constrained max width for better readability on large screens
///
/// Extend:
/// • Add copy / share / retry buttons via an overlay or trailing actions
/// • Integrate message-level metadata (tokens, latency, etc.)
/// • Add tap-to-expand for long code blocks
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  bool get _isUser => message.isUser;
  bool get _isAssistant => message.isAssistant;
  bool get _isSystem => message.isSystem;
  bool get _isError => message.isError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final Color bg = switch (message.role) {
      MessageRole.user => theme.colorScheme.primaryContainer,
      MessageRole.assistant => theme.colorScheme.surfaceVariant,
      MessageRole.system => theme.colorScheme.secondaryContainer.withOpacity(
        0.4,
      ),
      MessageRole.error => Colors.red.shade700,
    };

    final textColor = _isUser
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurface;

    final Widget content = (_isAssistant || _isSystem)
        ? MarkdownBody(
            data: message.content,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              codeblockDecoration: BoxDecoration(
                color: theme.colorScheme.surface.withOpacity(0.6),
                borderRadius: BorderRadius.circular(UIConstants.radiusS),
              ),
              blockquoteDecoration: BoxDecoration(
                color: theme.colorScheme.surfaceVariant.withOpacity(0.4),
                border: Border(
                  left: BorderSide(color: theme.colorScheme.primary, width: 3),
                ),
              ),
            ),
          )
        : SelectableText(
            message.content,
            style: TextStyle(
              color: _isError ? Colors.white : textColor,
              fontFamily: 'monospace',
            ),
          );

    return Align(
      alignment: _isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: UIConstants.spacingXS),
        padding: const EdgeInsets.symmetric(
          horizontal: UIConstants.spacingM,
          vertical: UIConstants.spacingS,
        ),
        constraints: const BoxConstraints(
          maxWidth: UIConstants.messageBubbleMaxWidth,
        ),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(UIConstants.radiusL),
            topRight: const Radius.circular(UIConstants.radiusL),
            bottomLeft: _isUser
                ? const Radius.circular(UIConstants.radiusL)
                : const Radius.circular(UIConstants.spacingXS),
            bottomRight: _isUser
                ? const Radius.circular(UIConstants.spacingXS)
                : const Radius.circular(UIConstants.radiusL),
          ),
          border: Border.all(
            color: _isError
                ? Colors.red.shade300
                : theme.dividerColor.withOpacity(0.15),
            width: 0.7,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.hasAttachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 8.0),
                child: AttachmentPreview(
                  attachments: message.attachments,
                  isUser: _isUser,
                ),
              ),
            content,
          ],
        ),
      ),
    );
  }
}
