/// history_repository.dart
/// ---------------------------------------------------------------------------
/// Remote conversation history repository built atop the HistoryService
/// (Flask + Postgres + pgvector backend).
///
/// Responsibilities:
/// • Provide a higher‑level, Flutter‑friendly abstraction over raw HTTP service
/// • Map remote DTOs into existing `ChatMessage` UI model
/// • Track / expose the "active" remote conversation id
/// • Offer convenience helpers for:
///     - Listing conversations (paginated)
///     - Loading (optionally fully) a conversation into memory
///     - Appending user / assistant messages
///     - Exporting a conversation (JSON payload)
///     - Similarity search against remote vector embeddings
/// • Uniform error handling via `Result` / `AppError`
///
/// Design Notes:
/// • Stateless regarding message ordering (delegated to backend; locally we
///   only ensure stable ascending timestamp after merges).
/// • Light in‑memory caches live in `HistoryService`; repository orchestrates.
/// • No local persistence layer here—persistence is *remote* only. If you need
///   hybrid offline support, compose this with a local cache layer.
/// • This mirrors the style of `conversation_repository.dart` but targets the
///   remote SQL storage rather than SharedPreferences.
/// ---------------------------------------------------------------------------

library history_repository;

import 'dart:async';

import '../services/history/history_service.dart';
import '../../core/result.dart';
import '../../core/config/constants/app_constants.dart';
import '../models/chat_message.dart';

/// Domain wrapper representing a loaded remote conversation in UI form.
class RemoteConversationDetail {
  final int conversationId;
  final List<ChatMessage> messages;
  final bool fullyLoaded;

  const RemoteConversationDetail({
    required this.conversationId,
    required this.messages,
    required this.fullyLoaded,
  });

  int get messageCount => messages.length;
  bool get hasContent => messages.hasContent;
}

/// Repository contract for remote history operations.
abstract interface class HistoryRepository {
  /// Currently active remote conversation id (if any).
  int? get activeConversationId;

  /// Explicitly set (or clear with `null`) the active conversation id.
  void setActiveConversation(int? id);

  /// List remote conversations (paged).
  Future<Result<Page<RemoteConversation>>> list({
    int page,
    int pageSize,
    bool includeCounts,
    bool forceRefresh,
  });

  /// Load messages for a conversation.
  /// If `fetchAll` is true, will page until full history is in memory.
  Future<Result<RemoteConversationDetail>> loadConversation(
    int conversationId, {
    bool includeEmbeddings,
    bool fetchAll,
    int pageSize,
  });

  /// Append a user message (creates new conversation if id omitted).
  Future<Result<ChatMessage>> addUserMessage(
    String content, {
    int? conversationId,
    String? modelName,
    List<double>? embedding,
  });

  /// Append an assistant message.
  Future<Result<ChatMessage>> addAssistantMessage(
    String content, {
    int? conversationId,
    String? modelName,
    List<double>? embedding,
  });

  /// Generic append (role = 'user' | 'ai').
  Future<Result<ChatMessage>> addMessage(
    String content, {
    required String sender,
    int? conversationId,
    String? modelName,
    List<double>? embedding,
  });

  /// Export full conversation JSON.
  Future<Result<Map<String, dynamic>>> exportConversation(int conversationId);

  /// Semantic similarity search (optional conversation scope).
  Future<Result<List<ChatMessage>>> similaritySearch({
    required List<double> queryEmbedding,
    int? conversationId,
    int topK,
  });

  /// Update the title (metadata) of a conversation.
  Future<Result<RemoteConversation>> updateTitle(
    int conversationId,
    String title,
  );

  /// Delete a conversation and its messages remotely.
  Future<Result<bool>> deleteConversation(int conversationId);

  /// Bulk delete multiple conversations.
  Future<Result<BulkDeleteResult>> bulkDelete(List<int> conversationIds);

  /// Clear cached state (e.g., after endpoint change).
  void clearCaches();
}

/// Implementation backed by `HistoryService`.
class RemoteHistoryRepository implements HistoryRepository {
  RemoteHistoryRepository._();
  static final RemoteHistoryRepository instance = RemoteHistoryRepository._();

  final HistoryService _service = HistoryService.instance;

  int? _activeConversationId;

  @override
  int? get activeConversationId => _activeConversationId;

  @override
  void setActiveConversation(int? id) {
    _activeConversationId = id;
  }

  @override
  Future<Result<Page<RemoteConversation>>> list({
    int page = 1,
    int pageSize = 20,
    bool includeCounts = true,
    bool forceRefresh = false,
  }) => _service.listConversations(
    page: page,
    pageSize: pageSize,
    includeCounts: includeCounts,
    forceRefresh: forceRefresh,
  );

  @override
  Future<Result<RemoteConversationDetail>> loadConversation(
    int conversationId, {
    bool includeEmbeddings = false,
    bool fetchAll = false,
    int pageSize = 200,
  }) async {
    // First page load
    final first = await _service.getConversationMessages(
      conversationId: conversationId,
      includeEmbeddings: includeEmbeddings,
      page: 1,
      pageSize: pageSize,
    );

    if (first.isFailure) {
      return Failure(first.error!);
    }

    var pageResult = first.data!;
    var accumulated = _service.toChatMessages(conversationId);

    // Optionally fetch all remaining pages
    if (fetchAll) {
      while (pageResult.hasNext) {
        final next = await _service.getConversationMessages(
          conversationId: conversationId,
          includeEmbeddings: includeEmbeddings,
          page: pageResult.page + 1,
          pageSize: pageSize,
        );
        if (next.isFailure) {
          // Return what we have so far but mark not fully loaded
          accumulated = _service.toChatMessages(conversationId);
          return Success(
            RemoteConversationDetail(
              conversationId: conversationId,
              messages: accumulated,
              fullyLoaded: false,
            ),
          );
        }
        pageResult = next.data!;
        accumulated = _service.toChatMessages(conversationId);
      }
    }

    setActiveConversation(conversationId);
    accumulated = _service.toChatMessages(conversationId);

    return Success(
      RemoteConversationDetail(
        conversationId: conversationId,
        messages: accumulated,
        fullyLoaded: !pageResult.hasNext,
      ),
    );
  }

  @override
  Future<Result<ChatMessage>> addUserMessage(
    String content, {
    int? conversationId,
    String? modelName,
    List<double>? embedding,
  }) => addMessage(
    content,
    sender: 'user',
    conversationId: conversationId ?? activeConversationId,
    modelName: modelName,
    embedding: embedding,
  );

  @override
  Future<Result<ChatMessage>> addAssistantMessage(
    String content, {
    int? conversationId,
    String? modelName,
    List<double>? embedding,
  }) => addMessage(
    content,
    sender: 'ai',
    conversationId: conversationId ?? activeConversationId,
    modelName: modelName,
    embedding: embedding,
  );

  @override
  Future<Result<ChatMessage>> addMessage(
    String content, {
    required String sender,
    int? conversationId,
    String? modelName,
    List<double>? embedding,
  }) async {
    if (content.trim().isEmpty) {
      return const Failure(
        AppError(
          message: ErrorMessages.emptyMessage,
          type: ErrorType.validation,
        ),
      );
    }

    final res = await _service.addMessage(
      conversationId: conversationId,
      sender: sender,
      message: content,
      modelName: modelName,
      embedding: embedding,
    );

    return res.when(
      success: (tuple) {
        final (cid, remote) = tuple;
        setActiveConversation(cid);
        return Success(remote.toChatMessage());
      },
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<Map<String, dynamic>>> exportConversation(int conversationId) =>
      _service.exportConversation(conversationId);

  @override
  Future<Result<List<ChatMessage>>> similaritySearch({
    required List<double> queryEmbedding,
    int? conversationId,
    int topK = 10,
  }) async {
    final res = await _service.similaritySearch(
      queryEmbedding: queryEmbedding,
      conversationId: conversationId,
      topK: topK,
    );
    return res.when(
      success: (remoteMessages) =>
          Success(remoteMessages.map((m) => m.toChatMessage()).toList()),
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<RemoteConversation>> updateTitle(
    int conversationId,
    String title,
  ) => _service.updateConversationTitle(conversationId, title);

  @override
  Future<Result<bool>> deleteConversation(int conversationId) =>
      _service.deleteConversation(conversationId);

  @override
  Future<Result<BulkDeleteResult>> bulkDelete(List<int> conversationIds) =>
      _service.bulkDeleteConversations(conversationIds);

  @override
  void clearCaches() {
    _service.clearCaches();
    _activeConversationId = null;
  }
}

/// Global singleton reference (mirroring pattern of local repository).
final HistoryRepository historyRepository = RemoteHistoryRepository.instance;
