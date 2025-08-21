/// rag_repository.dart
/// ---------------------------------------------------------------------------
/// Higher-level repository abstraction over the lower-level `RagService`.
///
/// Goals:
/// • Provide a Flutter-friendly facade with light in‑memory caching
/// • Expose Result<T> based error handling (same pattern as history repository)
/// • Offer convenience helpers for collection + document CRUD
/// • Track an "active" collection for UI state (optional)
///
/// Exclusions (by design):
/// • Query / similarity operations (handled by external webhook / n8n routing)
/// • Embedding management (server handles on document writes)
///
/// Caching Strategy:
/// • Collections list cached (invalidate on create/delete)
/// • Documents cached per collection+page (limit+offset key)
///   - Upon add/update/delete we surgically patch / invalidate affected cache
///
/// Extension Ideas:
/// • Full-text search within cached documents
/// • Bulk document operations
/// • Optimistic UI updates with rollback on failure
library rag_repository;

import 'dart:collection';

import '../services/rag/rag_service.dart';
import '../../core/result.dart';

/// Public abstraction describing RAG repository responsibilities.
abstract interface class RagRepository {
  /// Currently active (selected) collection name (normalized) or null.
  String? get activeCollection;

  /// Set (or clear with null) the active collection name.
  void setActiveCollection(String? name);

  /// List all collections.
  Future<Result<List<String>>> listCollections({bool forceRefresh = false});

  /// Create a new collection (returns normalized name).
  Future<Result<String>> createCollection(String name);

  /// Delete a collection (returns true if deleted, false if already absent).
  Future<Result<bool>> deleteCollection(String name);

  /// List documents (paginated) for a collection.
  Future<Result<RagDocumentPage>> listDocuments({
    required String collection,
    int limit,
    int offset,
    bool forceRefresh,
  });

  /// Add a new document (content only).
  Future<Result<RagDocument>> addDocument({
    required String collection,
    required String content,
  });

  /// Update an existing document by id.
  Future<Result<RagDocument>> updateDocument({
    required String collection,
    required int id,
    required String content,
  });

  /// Delete a document (returns true if removed, false if not found).
  Future<Result<bool>> deleteDocument({
    required String collection,
    required int id,
  });

  /// Clear all caches (e.g., after endpoint change).
  void clearCaches();
}

/// Concrete implementation leveraging `RagService`.
class RagRepositoryImpl implements RagRepository {
  RagRepositoryImpl._();
  static final RagRepositoryImpl instance = RagRepositoryImpl._();

  final RagService _service = RagService.instance;

  String? _activeCollection;

  // Cache: list of collection names
  List<String>? _collectionCache;

  // Cache: documents keyed by "collection|limit|offset"
  final Map<String, RagDocumentPage> _docPageCache = {};

  // Quick lookups for documents within a collection: id -> RagDocument
  final Map<String, Map<int, RagDocument>> _docIndexPerCollection = {};

  @override
  String? get activeCollection => _activeCollection;

  @override
  void setActiveCollection(String? name) {
    _activeCollection = name?.trim().isEmpty == true ? null : name;
  }

  // ---------------------------------------------------------------------------
  // Collections
  // ---------------------------------------------------------------------------

  @override
  Future<Result<List<String>>> listCollections({
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh && _collectionCache != null) {
      return Success(List.unmodifiable(_collectionCache!));
    }
    final res = await _service.listCollections();
    return res.when(
      success: (list) {
        _collectionCache = List<String>.from(list)..sort();
        return Success(List.unmodifiable(_collectionCache!));
      },
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<String>> createCollection(String name) async {
    final res = await _service.createCollection(name);
    return res.when(
      success: (normalized) {
        // Invalidate cache (simplest)
        _collectionCache = null;
        return Success(normalized);
      },
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<bool>> deleteCollection(String name) async {
    final res = await _service.deleteCollection(name);
    return res.when(
      success: (deleted) {
        // Remove from cache(s)
        _collectionCache?.removeWhere(
          (c) => c == name || c == _normalize(name),
        );
        // Remove doc caches
        final norm = _normalize(name);
        _docPageCache.removeWhere((k, _) => k.startsWith('$norm|'));
        _docIndexPerCollection.remove(norm);
        if (_activeCollection == norm) {
          _activeCollection = null;
        }
        return Success(deleted);
      },
      failure: (err) => Failure(err),
    );
  }

  // ---------------------------------------------------------------------------
  // Documents
  // ---------------------------------------------------------------------------

  @override
  Future<Result<RagDocumentPage>> listDocuments({
    required String collection,
    int limit = 50,
    int offset = 0,
    bool forceRefresh = false,
  }) async {
    final norm = _normalize(collection);
    limit = limit.clamp(1, 200);
    offset = offset < 0 ? 0 : offset;
    final key = _pageKey(norm, limit, offset);

    if (!forceRefresh && _docPageCache.containsKey(key)) {
      return Success(_docPageCache[key]!);
    }

    final res = await _service.listDocuments(
      collection: norm,
      limit: limit,
      offset: offset,
    );
    return res.when(
      success: (page) {
        _docPageCache[key] = page;
        // Index documents
        final index = _docIndexPerCollection.putIfAbsent(norm, () => {});
        for (final doc in page.documents) {
          index[doc.id] = doc;
        }
        return Success(page);
      },
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<RagDocument>> addDocument({
    required String collection,
    required String content,
  }) async {
    final norm = _normalize(collection);
    final res = await _service.addDocument(collection: norm, content: content);
    return res.when(
      success: (doc) {
        // Insert into index
        final index = _docIndexPerCollection.putIfAbsent(norm, () => {});
        index[doc.id] = doc;
        // Invalidate first page caches (simplest)
        _invalidatePagesForCollection(norm);
        return Success(doc);
      },
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<RagDocument>> updateDocument({
    required String collection,
    required int id,
    required String content,
  }) async {
    final norm = _normalize(collection);
    final res = await _service.updateDocument(
      collection: norm,
      id: id,
      content: content,
    );
    return res.when(
      success: (updated) {
        // Update index & any cached pages containing this doc
        final index = _docIndexPerCollection.putIfAbsent(norm, () => {});
        index[id] = updated;
        _patchCachedDocument(norm, updated);
        return Success(updated);
      },
      failure: (err) => Failure(err),
    );
  }

  @override
  Future<Result<bool>> deleteDocument({
    required String collection,
    required int id,
  }) async {
    final norm = _normalize(collection);
    final res = await _service.deleteDocument(collection: norm, id: id);
    return res.when(
      success: (deleted) {
        if (deleted) {
          // Remove from index
          final index = _docIndexPerCollection[norm];
          index?.remove(id);
          // Remove from any cached pages
          for (final entry in _docPageCache.entries) {
            if (entry.key.startsWith('$norm|')) {
              final docs = entry.value.documents
                  .where((d) => d.id != id)
                  .toList();
              final newPage = RagDocumentPage(
                documents: docs,
                count: docs.length,
                limit: entry.value.limit,
                offset: entry.value.offset,
              );
              _docPageCache[entry.key] = newPage;
            }
          }
        }
        return Success(deleted);
      },
      failure: (err) => Failure(err),
    );
  }

  // ---------------------------------------------------------------------------
  // Utilities & Cache Management
  // ---------------------------------------------------------------------------

  void _patchCachedDocument(String collection, RagDocument doc) {
    for (final entry in _docPageCache.entries) {
      if (entry.key.startsWith('$collection|')) {
        final docs = entry.value.documents;
        final idx = docs.indexWhere((d) => d.id == doc.id);
        if (idx >= 0) {
          final updatedList = [...docs];
          updatedList[idx] = doc;
          _docPageCache[entry.key] = RagDocumentPage(
            documents: updatedList,
            count: updatedList.length,
            limit: entry.value.limit,
            offset: entry.value.offset,
          );
        }
      }
    }
  }

  void _invalidatePagesForCollection(String collection) {
    _docPageCache.removeWhere((k, _) => k.startsWith('$collection|'));
  }

  String _normalize(String name) =>
      name.trim().toLowerCase().replaceAll(' ', '_');

  String _pageKey(String collection, int limit, int offset) =>
      '$collection|$limit|$offset';

  @override
  void clearCaches() {
    _collectionCache = null;
    _docPageCache.clear();
    _docIndexPerCollection.clear();
  }

  /// Provide a snapshot (diagnostics) of cache sizes and active state.
  Map<String, dynamic> debugSnapshot() => {
    'activeCollection': _activeCollection,
    'collectionCacheCount': _collectionCache?.length ?? 0,
    'documentPageCacheKeys': _docPageCache.keys.toList(),
    'docIndexCollections': _docIndexPerCollection.keys.toList(),
    'timestamp': DateTime.now().toIso8601String(),
  };
}

/// Public singleton (mirroring other repositories).
final RagRepository ragRepository = RagRepositoryImpl.instance;

/// Read-only view of documents cached for a collection (merged across pages).
extension RagRepositoryDocView on RagRepositoryImpl {
  UnmodifiableListView<RagDocument> cachedDocuments(String collection) {
    final norm = _normalize(collection);
    final index = _docIndexPerCollection[norm];
    if (index == null) return UnmodifiableListView(const []);
    final list = index.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return UnmodifiableListView(list);
  }
}
