/// rag_service.dart
/// ---------------------------------------------------------------------------
/// Lightweight REST client for the FastAPI RAG backend.
///
/// Responsibilities:
/// • Manage vector collections (create / list / delete)
/// • Manage documents within collections (CRUD)
/// • Provide simple domain models + Result-based error handling
/// • Centralize base URL resolution (Settings -> AppConfig.ragApiEndpoint)
///
/// NOT included (by design):
/// • Query / similarity operations (handled by webhook / n8n pipeline)
/// • Embedding generation (handled server-side on document writes)
///
/// Usage Example:
/// final rag = RagService.instance;
/// final collections = await rag.listCollections();
/// collections.when(
///   success: (names) => debugPrint('Collections: $names'),
///   failure: (err) => debugPrint('Error: ${err.message}'),
/// );
///
/// Design Notes:
/// • Follows the style used by history_service (http + Result<AppError>)
/// • Keeps models minimal — extend with metadata when backend supports it
/// • Safe URL construction, trimming trailing slashes
library rag_service;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../core/core.dart';

/// Represents a collection name (table) in the RAG backend.
class RagCollection {
  final String name;

  const RagCollection(this.name);

  @override
  String toString() => 'RagCollection($name)';
}

/// Represents a stored document (with ID + content).
class RagDocument {
  final int id;
  final String content;

  const RagDocument({required this.id, required this.content});

  factory RagDocument.fromJson(Map<String, dynamic> json) => RagDocument(
    id: json['id'] as int,
    content: (json['content'] as String?) ?? '',
  );

  RagDocument copyWith({int? id, String? content}) =>
      RagDocument(id: id ?? this.id, content: content ?? this.content);

  Map<String, dynamic> toJson() => {'id': id, 'content': content};

  @override
  String toString() => 'RagDocument(id=$id len=${content.length})';
}

/// Paginated documents response
class RagDocumentPage {
  final List<RagDocument> documents;
  final int count;
  final int limit;
  final int offset;

  const RagDocumentPage({
    required this.documents,
    required this.count,
    required this.limit,
    required this.offset,
  });

  bool get hasNext => count == limit; // heuristic (API doesn't return total)

  @override
  String toString() =>
      'RagDocumentPage(count=${documents.length} limit=$limit offset=$offset)';
}

/// Service for interacting with RAG backend.
class RagService {
  RagService._();
  static final RagService instance = RagService._();

  static final Logger _log = Logger('RagService');
  http.Client _client = http.Client();

  /// Replace underlying client (testing / dependency injection).
  void setClient(http.Client client) {
    _client.close();
    _client = client;
  }

  String get _baseUrl {
    final raw = AppConfig.instance.ragApiEndpoint.trim();
    if (raw.isEmpty) {
      return 'http://localhost:8890'; // fallback
    }
    return raw.replaceAll(RegExp(r'/*$'), '');
  }

  Uri _u(String path, [Map<String, Object?> query = const {}]) {
    final clean = path.startsWith('/') ? path : '/$path';
    final qp = <String, String>{};
    query.forEach((k, v) {
      if (v == null) return;
      qp[k] = v.toString();
    });
    return Uri.parse(
      '$_baseUrl$clean',
    ).replace(queryParameters: qp.isEmpty ? null : qp);
  }

  Map<String, String> get _jsonHeaders => const {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  // ---------------------------------------------------------------------------
  // Collection Operations
  // ---------------------------------------------------------------------------

  /// List all collection names.
  Future<Result<List<String>>> listCollections() => catchingAsync(() async {
    final res = await _client
        .get(_u('/collections'), headers: _jsonHeaders)
        .timeout(NetworkConfig.defaultTimeout);
    _assertOk(res, expected: 200, op: 'list collections');
    final decoded = jsonDecode(res.body) as Map<String, dynamic>;
    final cols =
        (decoded['collections'] as List?)?.whereType<String>().toList() ??
        const <String>[];
    return cols;
  });

  /// Create a collection. Returns the normalized name.
  Future<Result<String>> createCollection(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return Future.value(
        const Failure(
          AppError(
            message: 'Collection name cannot be empty',
            type: ErrorType.validation,
          ),
        ),
      );
    }
    return catchingAsync(() async {
      final body = jsonEncode({'name': trimmed});
      final res = await _client
          .post(_u('/collections'), headers: _jsonHeaders, body: body)
          .timeout(NetworkConfig.defaultTimeout);

      if (res.statusCode != 201) {
        // Try to extract structured FastAPI error: {"detail": "..."}
        String? detail;
        try {
          final decoded = jsonDecode(res.body);
          if (decoded is Map && decoded['detail'] is String) {
            detail = decoded['detail'] as String;
          }
        } catch (_) {}

        final lowerBody = res.body.toLowerCase();
        if (res.statusCode == 400 && lowerBody.contains('already exists')) {
          throw AppError(
            message: 'Collection already exists',
            statusCode: res.statusCode,
            type: ErrorType.conflict,
          );
        }

        final message =
            detail ??
            (res.body.isNotEmpty
                ? _truncate(res.body, 160)
                : 'Unexpected server response');

        throw AppError(
          message: 'Create collection failed: $message',
          statusCode: res.statusCode,
          type: res.statusCode == 400
              ? ErrorType.validation
              : res.statusCode >= 500
              ? ErrorType.network
              : ErrorType.unknown,
        );
      }

      // Success — backend responded 201
      return trimmed.toLowerCase().replaceAll(' ', '_');
    });
  }

  /// Delete a collection (idempotent on 404 returns false).
  Future<Result<bool>> deleteCollection(String name) {
    final normalized = name.trim().toLowerCase().replaceAll(' ', '_');
    if (normalized.isEmpty) {
      return Future.value(
        const Failure(
          AppError(
            message: 'Collection name required',
            type: ErrorType.validation,
          ),
        ),
      );
    }
    return catchingAsync(() async {
      final res = await _client
          .delete(_u('/collections/$normalized'), headers: _jsonHeaders)
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        return false;
      }
      _assertOk(res, expected: 200, op: 'delete collection');
      return true;
    });
  }

  // ---------------------------------------------------------------------------
  // Document Operations
  // ---------------------------------------------------------------------------

  /// List documents (paginated) in a collection.
  Future<Result<RagDocumentPage>> listDocuments({
    required String collection,
    int limit = 50,
    int offset = 0,
  }) {
    final normalized = _normalizeCollection(collection);
    limit = limit.clamp(1, 200);
    offset = offset < 0 ? 0 : offset;
    return catchingAsync(() async {
      final res = await _client
          .get(
            _u('/collections/$normalized/documents', {
              'limit': limit,
              'offset': offset,
            }),
            headers: _jsonHeaders,
          )
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        throw AppError(
          message: 'Collection not found',
          statusCode: 404,
          type: ErrorType.notFound,
        );
      }
      _assertOk(res, expected: 200, op: 'list documents');
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      final docs =
          (decoded['documents'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(RagDocument.fromJson)
              .toList() ??
          const <RagDocument>[];
      return RagDocumentPage(
        documents: docs,
        count: (decoded['count'] as int?) ?? docs.length,
        limit: (decoded['limit'] as int?) ?? limit,
        offset: (decoded['offset'] as int?) ?? offset,
      );
    });
  }

  /// Fetch a single document by id.
  Future<Result<RagDocument>> getDocument({
    required String collection,
    required int id,
  }) {
    final normalized = _normalizeCollection(collection);
    return catchingAsync(() async {
      final res = await _client
          .get(
            _u('/collections/$normalized/documents/$id'),
            headers: _jsonHeaders,
          )
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        throw AppError(
          message: 'Document not found',
          statusCode: 404,
          type: ErrorType.notFound,
        );
      }
      _assertOk(res, expected: 200, op: 'get document');
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      return RagDocument.fromJson(decoded);
    });
  }

  /// Add a document (content only; embedding handled server-side).
  Future<Result<RagDocument>> addDocument({
    required String collection,
    required String content,
  }) {
    final normalized = _normalizeCollection(collection);
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return Future.value(
        const Failure(
          AppError(
            message: 'Content cannot be empty',
            type: ErrorType.validation,
          ),
        ),
      );
    }
    return catchingAsync(() async {
      final body = jsonEncode({
        'collection_name': normalized,
        'content': trimmed,
      });
      final res = await _client
          .post(_u('/documents'), headers: _jsonHeaders, body: body)
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        throw AppError(
          message: 'Collection not found',
          statusCode: 404,
          type: ErrorType.notFound,
        );
      }
      _assertOk(res, expected: 201, op: 'add document');
      final decoded = jsonDecode(res.body) as Map<String, dynamic>;
      return RagDocument(id: decoded['id'] as int? ?? -1, content: trimmed);
    });
  }

  /// Update a document's content (regenerates embedding server-side).
  Future<Result<RagDocument>> updateDocument({
    required String collection,
    required int id,
    required String content,
  }) {
    final normalized = _normalizeCollection(collection);
    final trimmed = content.trim();
    if (trimmed.isEmpty) {
      return Future.value(
        const Failure(
          AppError(
            message: 'Content cannot be empty',
            type: ErrorType.validation,
          ),
        ),
      );
    }
    return catchingAsync(() async {
      final body = jsonEncode({'content': trimmed});
      final res = await _client
          .put(
            _u('/collections/$normalized/documents/$id'),
            headers: _jsonHeaders,
            body: body,
          )
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        throw AppError(
          message: 'Document or collection not found',
          statusCode: 404,
          type: ErrorType.notFound,
        );
      }
      _assertOk(res, expected: 200, op: 'update document');
      return RagDocument(id: id, content: trimmed);
    });
  }

  /// Delete a document by id (returns true if deleted, false if already gone).
  Future<Result<bool>> deleteDocument({
    required String collection,
    required int id,
  }) {
    final normalized = _normalizeCollection(collection);
    return catchingAsync(() async {
      final res = await _client
          .delete(
            _u('/collections/$normalized/documents/$id'),
            headers: _jsonHeaders,
          )
          .timeout(NetworkConfig.defaultTimeout);
      if (res.statusCode == 404) {
        return false;
      }
      _assertOk(res, expected: 200, op: 'delete document');
      return true;
    });
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  String _normalizeCollection(String name) =>
      name.trim().toLowerCase().replaceAll(' ', '_');

  void _assertOk(
    http.Response res, {
    required int expected,
    required String op,
  }) {
    if (res.statusCode != expected) {
      throw AppError(
        message:
            'RAG $op failed (${res.statusCode}) ${_truncate(res.body, 160)}',
        statusCode: res.statusCode,
        type: res.statusCode == 404
            ? ErrorType.notFound
            : res.statusCode == 409
            ? ErrorType.conflict
            : res.statusCode >= 500
            ? ErrorType.network
            : ErrorType.unknown,
      );
    }
  }

  String _truncate(String input, int maxLen) =>
      input.length <= maxLen ? input : '${input.substring(0, maxLen)}…';

  /// Dispose underlying client.
  void dispose() {
    _client.close();
  }
}
