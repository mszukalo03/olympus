import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../services/ai_service.dart';
import '../repositories/history_repository.dart'; // Remote history
import '../services/custom/custom_endpoint_service.dart';
import '../../core/config/constants/app_constants.dart';

/// Chat Controller (Remote History Refactor)
/// ---------------------------------------------------------------------------
/// Now persists conversation history directly to the remote Flask/Postgres
/// backend via `historyRepository` instead of local SharedPreferences.
/// Local repository calls are retained only for backward compatibility with
/// existing UI elements (e.g. HistoryDrawer / Save button) but no longer
/// perform real persistence.
/// ---------------------------------------------------------------------------
class ChatController extends ChangeNotifier {
  static final Logger _log = Logger(LogConfig.chatLogger);

  // In‑memory UI state
  final List<ChatMessage> _messages = [];
  bool _isSending = false;
  bool _isOnline = true;
  String? _lastError;
  StreamSubscription<dynamic>? _connectivitySub;
  String _sessionId = const Uuid().v4();

  // Active remote conversation id (nullable until first message persisted)
  int? _remoteConversationId;

  // Track if we've attempted to set a title for this conversation
  bool _conversationTitleSet = false;

  // Track which (user/assistant) message IDs have been persisted remotely
  final Set<String> _persistedMessageIds = {};

  // Public getters
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  bool get isSending => _isSending;
  bool get isOnline => _isOnline;
  bool get hasMessages => _messages.isNotEmpty;
  bool get hasConversation => _messages.hasContent;
  String? get lastError => _lastError;
  bool get hasError => _lastError != null;
  int get messageCount => _messages.length;
  int? get remoteConversationId => _remoteConversationId;
  String get sessionId => _sessionId;

  ChatController() {
    _initConnectivity();
    _addSystemMessage('${AppInfo.name} v${AppInfo.version} initialized');
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    super.dispose();
  }

  // Connectivity ----------------------------------------------------------------

  void _initConnectivity() {
    _connectivitySub = Connectivity().onConnectivityChanged.listen(
      _onConnectivityChanged,
    );
  }

  void _onConnectivityChanged(dynamic result) {
    final wasOnline = _isOnline;
    if (result is List<ConnectivityResult>) {
      _isOnline = result.any((r) => r != ConnectivityResult.none);
    } else if (result is ConnectivityResult) {
      _isOnline = result != ConnectivityResult.none;
    } else {
      _isOnline = true;
    }

    if (wasOnline != _isOnline) {
      notifyListeners();
      _addSystemMessage(
        _isOnline ? 'Connection restored' : 'Connection lost - working offline',
      );
      _log.info('Connectivity changed: online=$_isOnline');
    }
  }

  // Messaging -------------------------------------------------------------------

  Future<void> sendMessage(String content, {List<MessageAttachment>? attachments}) async {
    final trimmed = content.trim();
    final hasContent = trimmed.isNotEmpty || (attachments != null && attachments.isNotEmpty);
    if (!hasContent || _isSending) return;

    _clearError();
    final userMsg = ChatMessage.user(trimmed, attachments: attachments ?? []);
    _messages.add(userMsg);
    notifyListeners();

    // Check for help command
    if (trimmed.toLowerCase() == '/help' || trimmed == '?') {
      _addAssistantMessage(_getHelpText());
      return;
    }

    // Persist user message remotely (fire and await to keep order)
    await _persistUserMessage(userMsg);

    _setSending(true);
    try {
      final ctx = _messages.toContext(limit: UIConstants.maxContextMessages);
      final result = await AIService.instance.sendCompletion(
        trimmed,
        context: ctx,
        attachments: attachments ?? [],
        options: {'session_id': _sessionId},
        conversationId: _remoteConversationId,
      );

      result.when(
        success: (response) async {
          final assistantMsg = ChatMessage.assistant(response);
          _messages.add(assistantMsg);
          notifyListeners();
          _log.info('AI response received (${response.length} chars)');
          // Persist assistant message
          await _persistAssistantMessage(assistantMsg);
        },
        failure: (error) {
          _lastError = error.message;
          _addErrorMessage('AI Error: ${error.message}');
          _log.warning('AI request failed: ${error.message}');
        },
      );
    } catch (e, st) {
      _lastError = e.toString();
      _addErrorMessage('Unexpected error: $e');
      _log.severe('Unexpected error in sendMessage', e, st);
    } finally {
      _setSending(false);
    }
  }

  Future<void> _persistUserMessage(ChatMessage m) async {
    // Skip if already persisted (e.g., during bulk save)
    if (_persistedMessageIds.contains(m.id)) return;

    final bool isFirstRemote = _remoteConversationId == null;

    final res = await historyRepository.addUserMessage(
      m.content,
      conversationId: _remoteConversationId,
      attachments: m.attachments.isNotEmpty ? m.attachments : null,
    );

    res.when(
      success: (_) async {
        _remoteConversationId = historyRepository.activeConversationId;
        _persistedMessageIds.add(m.id);

        // If this was the first successful persistence and we have no title yet, derive one.
        if (isFirstRemote &&
            !_conversationTitleSet &&
            _remoteConversationId != null) {
          final derived = _deriveTitleFromFirstMessage();
          if (derived != null && derived.trim().isNotEmpty) {
            final updateRes = await historyRepository.updateTitle(
              _remoteConversationId!,
              derived,
            );
            updateRes.when(
              success: (_) {
                _conversationTitleSet = true;
              },
              failure: (err) {
                _log.warning(
                  'Failed to set conversation title: ${err.message}',
                );
              },
            );
          }
        }
      },
      failure: (err) {
        _log.warning('Failed to persist user message: ${err.message}');
        _addSystemMessage(
          'Warning: user message not persisted remotely (${err.message})',
        );
      },
    );
  }

  Future<void> _persistAssistantMessage(ChatMessage m) async {
    if (_persistedMessageIds.contains(m.id)) return;
    final res = await historyRepository.addAssistantMessage(
      m.content,
      conversationId: _remoteConversationId,
      attachments: m.attachments.isNotEmpty ? m.attachments : null,
    );
    res.when(
      success: (_) {
        _remoteConversationId = historyRepository.activeConversationId;
        _persistedMessageIds.add(m.id);
      },
      failure: (err) {
        _log.warning('Failed to persist assistant message: ${err.message}');
        _addSystemMessage(
          'Warning: assistant reply not saved remotely (${err.message})',
        );
      },
    );
  }

  // Remote history loading ------------------------------------------------------

  /// Load a remote conversation (fully by default) and replace in‑memory messages.
  Future<void> loadRemoteConversation(
    int conversationId, {
    bool fetchAll = true,
    bool includeEmbeddings = false,
  }) async {
    _addSystemMessage('Loading remote conversation $conversationId ...');
    final res = await historyRepository.loadConversation(
      conversationId,
      fetchAll: fetchAll,
      includeEmbeddings: includeEmbeddings,
    );

    res.when(
      success: (detail) {
        _messages
          ..clear()
          ..addAll(detail.messages);
        _remoteConversationId = detail.conversationId;
        _clearError();
        _addSystemMessage(
          'Remote conversation loaded (${detail.messageCount} messages)',
        );
        notifyListeners();
        _log.info(
          'Remote conversation loaded: id=$conversationId messages=${detail.messageCount} fullyLoaded=${detail.fullyLoaded}',
        );
      },
      failure: (err) {
        _lastError = err.message;
        _addErrorMessage('Load failed: ${err.message}');
        _log.warning('Failed to load remote conversation: ${err.message}');
      },
    );
  }

  /// Start a brand new remote conversation context locally.
  void startNewRemoteConversation() {
    clear();
    historyRepository.setActiveConversation(null);
    _remoteConversationId = null;
    _addSystemMessage('New remote conversation started');
  }

  /// Persist any unsaved user/assistant messages to the remote history backend.
  /// System & error messages are not persisted.
  Future<void> saveConversation() async {
    if (!hasConversation) {
      _addSystemMessage('No messages to save');
      return;
    }

    // Gather unsaved chronological user/assistant messages
    final unsaved = _messages.where(
      (m) =>
          (m.isUser || m.isAssistant) && !_persistedMessageIds.contains(m.id),
    );

    final toPersist = unsaved.toList();
    if (toPersist.isEmpty) {
      _addSystemMessage(
        'All conversation messages already saved (id=${_remoteConversationId ?? "pending"})',
      );
      return;
    }

    _addSystemMessage(
      'Saving ${toPersist.length} message(s) to remote history...',
    );

    for (final msg in toPersist) {
      if (msg.isUser) {
        await _persistUserMessage(msg);
      } else if (msg.isAssistant) {
        await _persistAssistantMessage(msg);
      }
    }

    _addSystemMessage(
      'Saved ${toPersist.length} message(s) (conversation id=${_remoteConversationId ?? "pending"})',
    );
  }

  // Title derivation (moved out of _addErrorMessage)
  String? _deriveTitleFromFirstMessage() {
    final firstUser = _messages.firstWhere(
      (m) => m.isUser && m.content.trim().isNotEmpty,
      orElse: () => ChatMessage.user(''),
    );
    final raw = firstUser.content.trim();
    if (raw.isEmpty) return null;
    final firstLine = raw.split('\n').first.trim();
    if (firstLine.isEmpty) return null;
    return firstLine.length <= 60
        ? firstLine
        : '${firstLine.substring(0, 60)}…';
  }

  // Utilities ------------------------------------------------------------------

  void clear() {
    _messages.clear();
    _persistedMessageIds.clear();
    _clearError();
    _sessionId = const Uuid().v4();
    _addSystemMessage('Conversation cleared (new session started)');
    _log.info('Conversation cleared; new sessionId=$_sessionId');
    notifyListeners();
  }

  void clearError() {
    _clearError();
    notifyListeners();
  }

  Future<void> retryLastMessage() async {
    final lastUser = _messages.lastByRole(MessageRole.user);
    if (lastUser != null && !_isSending) {
      final userIndex = _messages.lastIndexWhere((m) => m.id == lastUser.id);
      if (userIndex >= 0 && userIndex < _messages.length - 1) {
        _messages.removeRange(userIndex + 1, _messages.length);
        notifyListeners();
      }
      await sendMessage(lastUser.content);
    }
  }

  // Internal mutators ----------------------------------------------------------

  void _addSystemMessage(String content) {
    _messages.add(ChatMessage.system(content));
    notifyListeners();
  }

  void _addErrorMessage(String content) {
    _messages.add(ChatMessage.error(content));
    notifyListeners();
  }

  void _addAssistantMessage(String content) {
    _messages.add(ChatMessage.assistant(content));
    notifyListeners();
  }

  void _setSending(bool sending) {
    if (_isSending != sending) {
      _isSending = sending;
      notifyListeners();
    }
  }

  void _clearError() {
    if (_lastError != null) {
      _lastError = null;
    }
  }

  /// Get help text for available commands and shortcuts
  String _getHelpText() {
    final buffer = StringBuffer();
    buffer.writeln('**${AppInfo.name} Help**\n');

    buffer.writeln('**Basic Commands:**');
    buffer.writeln('• `/help` or `?` - Show this help');
    buffer.writeln('• Regular messages - Send to AI assistant\n');

    // Add custom endpoint help
    final customService = CustomEndpointService.instance;
    final shortcuts = customService.getAvailableShortcuts();

    if (shortcuts.isNotEmpty) {
      buffer.writeln('**Custom Endpoints:**');
      shortcuts.forEach((shortcut, config) {
        final name = config['name'] ?? shortcut;
        final type = config['type'] ?? 'unknown';
        buffer.writeln('• `/$shortcut <query>` - $name ($type)');
      });
      buffer.writeln(
        '\n*Examples: `/j The Matrix`, `/search flutter tutorials`, `/ddg weather NYC`*\n',
      );
      buffer.writeln('**Search Options:**');
      buffer.writeln('• SearXNG - Full web search (requires configuration)');
      buffer.writeln(
        '• DuckDuckGo - Instant answers & facts (no setup needed)',
      );
      buffer.writeln('');
    }

    buffer.writeln('**Features:**');
    buffer.writeln('• Conversation history is automatically saved');
    buffer.writeln('• Use the sidebar to load previous conversations');
    buffer.writeln('• Configure endpoints and API keys in Settings');
    buffer.writeln('• Some services (like Jellyseerr) require API keys');

    return buffer.toString();
  }

  // Debug ----------------------------------------------------------------------

  Map<String, dynamic> toDebugJson() => {
    'messageCount': messageCount,
    'isSending': isSending,
    'isOnline': isOnline,
    'hasError': hasError,
    'lastError': lastError,
    'hasConversation': hasConversation,
    'remoteConversationId': _remoteConversationId,
    'remoteActiveId': historyRepository.activeConversationId,
    'fullyPersisted': _remoteConversationId != null,
    'userMessages': _messages.byRole(MessageRole.user).length,
    'assistantMessages': _messages.byRole(MessageRole.assistant).length,
    'systemMessages': _messages.byRole(MessageRole.system).length,
    'errorMessages': _messages.byRole(MessageRole.error).length,
    'conversationTitleSet': _conversationTitleSet,
    'persistedMessageCount': _persistedMessageIds.length,
    'pendingUnsavedMessages': _messages
        .where(
          (m) =>
              (m.isUser || m.isAssistant) &&
              !_persistedMessageIds.contains(m.id),
        )
        .length,
    'persistedRatio': (() {
      final total = _messages.where((m) => m.isUser || m.isAssistant).length;
      return total == 0 ? 1.0 : _persistedMessageIds.length / total;
    })(),
    'sessionId': _sessionId,
    'timestamp': DateTime.now().toIso8601String(),
  };
}
