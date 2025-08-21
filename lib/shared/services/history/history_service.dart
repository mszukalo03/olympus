// history_service.dart
//
// Remote conversation history service interacting with the Flask / Postgres backend.
// Features:
// • Configurable base URL (Settings -> history_api)
// • Pagination support for conversations and messages
// • Create / continue conversations by posting messages
// • Export conversation (returns JSON map)
// • Optional embedding submission & similarity search
// • Lightweight in‑memory caching & optimistic updates
// • Uniform error handling via Result / AppError abstractions
//
// NOTE: This service intentionally avoids persistence; it mirrors remote state.
// Local/offline caching strategies can be layered above if needed.

library history_service;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/core.dart';
import '../../models/chat_message.dart';

/// Data model representing a remote conversation summary.
class RemoteConversation {
  final int id;
  final DateTime createdAt;
  final int? messageCount;
  final String? title;

  const RemoteConversation({
    required this.id,
    required this.createdAt,
    this.messageCount,
    this.title,
  });

  factory RemoteConversation.fromJson(Map<String, dynamic> json) {
    return RemoteConversation(
      id: json['id'] as int,
      createdAt: _parseDate(json['created_at']),
      messageCount: json['message_count'] as int?,
      title: (json['title'] as String?)?.trim().isEmpty == true
          ? null
          : json['title'] as String?,
    );
  }
}

/// Data model for a remote chat message.
class RemoteMessage {
  final int id;
  final int conversationId;
  final String sender; // 'user' | 'ai'
  final String content;
  final DateTime createdAt;
  final String? modelName;
  final List<double>? embedding;

  const RemoteMessage({
    required this.id,
    required this.conversationId,
    required this.sender,
    required this.content,
    required this.createdAt,
    this.modelName,
    this.embedding,
  });

  factory RemoteMessage.fromJson(Map<String, dynamic> json) {
    return RemoteMessage(
      id: json['id'] as int,
      conversationId: json['conversation_id'] as int,
      sender: json['sender'] as String,
      content: json['message'] as String,
      createdAt: _parseDate(json['created_at']),
      modelName: json['model_name'] as String?,
      embedding: (json['embedding'] as List?)
          ?.whereType<num>()
          .map((e) => e.toDouble())
          .toList(),
    );
  }

  /// Convert to UI layer ChatMessage role mapping.
  ChatMessage toChatMessage() {
    final role = sender == 'user'
        ? MessageRole.user
        : sender == 'ai'
        ? MessageRole.assistant
        : MessageRole.system;
    return ChatMessage.create(
      role: role,
      content: content,
      timestamp: createdAt,
    );
  }
}

/// Paginated response container.
class Page<T> {
  final List<T> items;
  final int page;
  final int pageSize;
  final int total;
  final bool hasNext;

  const Page({
    required this.items,
    required this.page,
    required this.pageSize,
    required this.total,
    required this.hasNext,
  });
}

/// History service for remote backend.
class HistoryService {
  HistoryService._();
  static final HistoryService instance = HistoryService._();

  final Map<int, List<RemoteMessage>> _messageCache = {};
  final Map<int, bool> _messagesFullyLoaded = {};
  final Map<String, Page<RemoteConversation>> _conversationPageCache = {};

  http.Client _client = http.Client();

  /// Replace HTTP client (useful for tests / mocking).
  void setClient(http.Client client) {
    _client.close();
    _client = client;
  }

  String get _baseUrl =>
      AppConfig.instance.historyEndpoint.trim().replaceAll(RegExp(r'/$'), '');

  Uri _u(String path, [Map<String, dynamic>? q]) {
    final query = q == null
        ? null
        : q.map((k, v) => MapEntry(k, v == null ? '' : v.toString()));
    return Uri.parse('$_baseUrl$path').replace(queryParameters: query);
  }

  Map<String, String> get _headers => const {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  /// List conversations (cached per (page,pageSize,includeCounts)).
  Future<Result<Page<RemoteConversation>>> listConversations({
    int page = 1,
    int pageSize = 20,
    bool includeCounts = true,
    bool forceRefresh = false,
  }) async {
    final key = 'p=$page|s=$pageSize|c=$includeCounts';
    if (!forceRefresh && _conversationPageCache.containsKey(key)) {
      final cached = _conversationPageCache[key]!;
      return Success(cached);
    }
    return catchingAsync(() async {
      final uri = _u('/conversations', {
        'page': page,
        'page_size': pageSize,
        'include_counts': includeCounts,
      });
      final res = await _client
          .get(uri, headers: _headers)
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 200) {
        throw AppError(
          message: 'Failed to load conversations (${res.statusCode})',
          statusCode: res.statusCode,
          type: ErrorType.network,
        );
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final items = (decoded['conversations'] as List)
          .whereType<Map<String, dynamic>>()
          .map(RemoteConversation.fromJson)
          .toList();
      final pageObj = Page<RemoteConversation>(
        items: items,
        page: decoded['page'] as int,
        pageSize: decoded['page_size'] as int,
        total: decoded['total'] as int,
        hasNext: decoded['has_next'] as bool,
      );
      _conversationPageCache[key] = pageObj;
      return pageObj;
    });
  }

  /// Fetch messages for a conversation (will append to cache).
  Future<Result<Page<RemoteMessage>>> getConversationMessages({
    required int conversationId,
    int page = 1,
    int pageSize = 100,
    bool includeEmbeddings = false,
  }) async {
    // If fully loaded and asking for first page again, return cached messages in one page.
    if (page == 1 && _messagesFullyLoaded[conversationId] == true) {
      final msgs = _messageCache[conversationId] ?? [];
      return Success(
        Page(
          items: msgs,
          page: 1,
          pageSize: msgs.length,
          total: msgs.length,
          hasNext: false,
        ),
      );
    }
    return catchingAsync(() async {
      final uri = _u('/conversations/$conversationId', {
        'page': page,
        'page_size': pageSize,
        'include_embeddings': includeEmbeddings,
      });
      final res = await _client
          .get(uri, headers: _headers)
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 200) {
        throw AppError(
          message: 'Failed to load messages (${res.statusCode})',
          statusCode: res.statusCode,
          type: res.statusCode == 404 ? ErrorType.notFound : ErrorType.network,
        );
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final list = (decoded['messages'] as List)
          .whereType<Map<String, dynamic>>()
          .map(RemoteMessage.fromJson)
          .toList();
      final cache = _messageCache.putIfAbsent(conversationId, () => []);
      // Merge (avoid duplicates)
      for (final m in list) {
        if (!cache.any((c) => c.id == m.id)) {
          cache.add(m);
        }
      }
      cache.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      final total = decoded['total'] as int;
      final hasNext = decoded['has_next'] as bool;
      if (!hasNext) {
        _messagesFullyLoaded[conversationId] = true;
      }
      return Page(
        items: list,
        page: decoded['page'] as int,
        pageSize: decoded['page_size'] as int,
        total: total,
        hasNext: hasNext,
      );
    });
  }

  /// Create / append a message. Returns (conversationId, newMessage).
  Future<Result<(int, RemoteMessage)>> addMessage({
    int? conversationId,
    required String sender,
    required String message,
    String? modelName,
    List<double>? embedding,
  }) async {
    return catchingAsync(() async {
      final uri = _u('/messages');
      final body = {
        'conversation_id': conversationId,
        'sender': sender,
        'message': message,
        if (modelName != null) 'model_name': modelName,
        if (embedding != null) 'embedding': embedding,
      }..removeWhere((k, v) => v == null);
      final res = await _client
          .post(uri, headers: _headers, body: jsonEncode(body))
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 201) {
        throw AppError(
          message: 'Failed to add message (${res.statusCode})',
          statusCode: res.statusCode,
          type: ErrorType.network,
        );
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final cid = decoded['conversation_id'] as int;
      // Hydrate the newly created message as pseudo RemoteMessage (id maybe not returned? original API returns id now)
      final msg = RemoteMessage(
        id: decoded['id'] as int? ?? -1,
        conversationId: cid,
        sender: decoded['sender'] as String? ?? sender,
        content: decoded['message'] as String? ?? message,
        createdAt: _parseDate(decoded['created_at']),
        modelName: modelName,
        embedding: embedding,
      );
      final cache = _messageCache.putIfAbsent(cid, () => []);
      cache.add(msg);
      cache.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return (cid, msg);
    });
  }

  /// Export full conversation (ignores caches) -> JSON map.
  Future<Result<Map<String, dynamic>>> exportConversation(
    int conversationId,
  ) async {
    return catchingAsync(() async {
      final uri = _u('/conversations/$conversationId/export');
      final res = await _client
          .get(uri, headers: _headers)
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 200) {
        throw AppError(
          message: 'Export failed (${res.statusCode})',
          statusCode: res.statusCode,
          type: ErrorType.network,
        );
      }
      return jsonDecode(res.body) as Map<String, dynamic>;
    });
  }

  /// Similarity search across messages (optionally restricted to a conversation).
  Future<Result<List<RemoteMessage>>> similaritySearch({
    required List<double> queryEmbedding,
    int? conversationId,
    int topK = 10,
  }) async {
    return catchingAsync(() async {
      final uri = _u('/similarity_search');
      final body = {
        'query_embedding': queryEmbedding,
        'top_k': topK,
        if (conversationId != null) 'conversation_id': conversationId,
      };
      final res = await _client
          .post(uri, headers: _headers, body: jsonEncode(body))
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 200) {
        throw AppError(
          message: 'Similarity search failed (${res.statusCode})',
          statusCode: res.statusCode,
          type: ErrorType.network,
        );
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final results = (decoded['results'] as List)
          .whereType<Map<String, dynamic>>()
          .map(RemoteMessage.fromJson)
          .toList();
      return results;
    });
  }

  /// Convert cached remote messages to UI messages.
  List<ChatMessage> toChatMessages(int conversationId) {
    final list = _messageCache[conversationId] ?? [];
    return list.map((e) => e.toChatMessage()).toList();
  }

  /// Clear in-memory caches (e.g., after endpoint switch).
  void clearCaches() {
    _messageCache.clear();
    _messagesFullyLoaded.clear();
    _conversationPageCache.clear();
  }

  /// Update a conversation title (PATCH /conversations/{id})
  Future<Result<RemoteConversation>> updateConversationTitle(
    int conversationId,
    String title,
  ) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) {
      return const Failure(
        AppError(message: 'Title cannot be empty', type: ErrorType.validation),
      );
    }
    return catchingAsync(() async {
      final uri = _u('/conversations/$conversationId');
      final res = await _client
          .patch(uri, headers: _headers, body: jsonEncode({'title': trimmed}))
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 200) {
        throw AppError(
          message:
              'Failed to update conversation (${res.statusCode}) ${_truncate(res.body, 120)}',
          statusCode: res.statusCode,
          type: res.statusCode == 404 ? ErrorType.notFound : ErrorType.network,
        );
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final updated = RemoteConversation.fromJson(decoded);

      // Refresh cached pages (shallow update)
      for (final entry in _conversationPageCache.entries) {
        final items = entry.value.items;
        for (var i = 0; i < items.length; i++) {
          final c = items[i];
          if (c.id == updated.id) {
            items[i] = RemoteConversation(
              id: updated.id,
              createdAt: updated.createdAt,
              messageCount: updated.messageCount ?? c.messageCount,
              title: updated.title,
            );
          }
        }
      }
      return updated;
    });
  }

  /// Delete a conversation (DELETE /conversations/{id})
  Future<Result<bool>> deleteConversation(int conversationId) async {
    return catchingAsync(() async {
      final uri = _u('/conversations/$conversationId');
      final res = await _client
          .delete(uri, headers: _headers)
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        return false; // Already gone
      }
      if (res.statusCode != 200) {
        throw AppError(
          message:
              'Failed to delete conversation (${res.statusCode}) ${_truncate(res.body, 120)}',
          statusCode: res.statusCode,
          type: ErrorType.network,
        );
      }

      // Purge from caches
      _messageCache.remove(conversationId);
      _messagesFullyLoaded.remove(conversationId);
      for (final entry in _conversationPageCache.entries) {
        entry.value.items.removeWhere((c) => c.id == conversationId);
      }
      return true;
    });
  }

  /// Dispose underlying client.
  void dispose() {
    _client.close();
  }
}

/// Extension bridging remote conversation into a lightweight record for UI lists.
extension RemoteConversationX on RemoteConversation {
  String get displayTitle {
    if (title != null && title!.trim().isNotEmpty) {
      final t = title!.trim();
      return t.length <= 40 ? t : '${t.substring(0, 40)}…';
    }
    return 'Conversation $id';
  }
}

/// Minimal error formatting helper.
String formatHistoryError(AppError error) {
  final code = error.statusCode != null ? ' (${error.statusCode})' : '';
  return '${error.message}$code';
}

/// Simple truncation helper used for log / error message condensation.
String _truncate(String input, int maxLen) =>
    input.length <= maxLen ? input : '${input.substring(0, maxLen)}…';

/// Robust date parser supporting ISO8601 and RFC1123 (HTTP-date) formats.
/// Falls back to current UTC time if parsing fails.
DateTime _parseDate(dynamic value) {
  if (value is DateTime) return value.toUtc();
  if (value is! String) return DateTime.now().toUtc();
  final v = value.trim();

  // Try ISO8601
  try {
    return DateTime.parse(v).toUtc();
  } catch (_) {}

  // Try RFC1123: e.g. Wed, 20 Aug 2025 01:36:08 GMT
  final rfc1123 = RegExp(
    r'^[A-Za-z]{3},\s+(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\s+'
    r'(\d{2}):(\d{2}):(\d{2})\s+GMT$',
  );
  final m = rfc1123.firstMatch(v);
  if (m != null) {
    const months = {
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12,
    };
    final day = int.parse(m.group(1)!);
    final monStr = m.group(2)!;
    final year = int.parse(m.group(3)!);
    final hour = int.parse(m.group(4)!);
    final minute = int.parse(m.group(5)!);
    final second = int.parse(m.group(6)!);
    final month = months[monStr] ?? 1;
    return DateTime.utc(year, month, day, hour, minute, second);
  }

  // Fallback
  return DateTime.now().toUtc();
}

// Bulk delete result model
class BulkDeleteResult {
  final List<int> requested;
  final List<int> deleted;
  final List<int> notFound;
  final List<String> errors;
  const BulkDeleteResult({
    required this.requested,
    required this.deleted,
    required this.notFound,
    required this.errors,
  });
  factory BulkDeleteResult.fromJson(Map<String, dynamic> json) {
    List<int> _toIntList(dynamic v) {
      if (v is List) {
        return v.where((e) => e is int).cast<int>().toList();
      }
      return const <int>[];
    }

    return BulkDeleteResult(
      requested: _toIntList(json['requested']),
      deleted: _toIntList(json['deleted']),
      notFound: _toIntList(json['not_found']),
      errors: (json['errors'] is List)
          ? (json['errors'] as List).whereType<String>().toList()
          : const <String>[],
    );
  }
}

// Add bulk delete API call
extension HistoryServiceBulkOps on HistoryService {
  Future<Result<BulkDeleteResult>> bulkDeleteConversations(
    List<int> conversationIds,
  ) {
    if (conversationIds.isEmpty) {
      return Future.value(
        const Failure(
          AppError(
            message: 'conversationIds cannot be empty',
            type: ErrorType.validation,
          ),
        ),
      );
    }
    final unique = conversationIds.toSet().toList();
    return catchingAsync(() async {
      final uri = _u('/conversations/bulk_delete');
      final res = await _client
          .post(
            uri,
            headers: _headers,
            body: jsonEncode({'conversation_ids': unique}),
          )
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode != 200) {
        throw AppError(
          message:
              'Bulk delete failed (${res.statusCode}) ${_truncate(res.body, 160)}',
          statusCode: res.statusCode,
          type: ErrorType.network,
        );
      }
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final result = BulkDeleteResult.fromJson(decoded);
      // Purge deleted from caches
      for (final id in result.deleted) {
        _messageCache.remove(id);
        _messagesFullyLoaded.remove(id);
        for (final entry in _conversationPageCache.entries) {
          entry.value.items.removeWhere((c) => c.id == id);
        }
      }
      return result;
    });
  }
}

// End of file.
