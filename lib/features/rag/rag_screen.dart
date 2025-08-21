import 'package:flutter/material.dart';
import 'dart:io'; // For file operations + Platform detection
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../shared/shared.dart';
import '../../core/core.dart';

/// RAG Management Screen
/// ---------------------------------------------------------------------------
/// Replaces the previous "Blank 1" placeholder with a full CRUD interface
/// for managing RAG collections (vector tables) and their documents.
///
/// Features:
/// • List / refresh collections
/// • Create & delete collections
/// • Select active collection
/// • Paginated document list (lazy load via offset)
/// • Add / edit / delete documents (embeddings handled server-side)
/// • Inline status + error feedback
///
/// Non‑Goals (explicitly excluded per requirements):
/// • Query / similarity / retrieval UI (handled externally via webhook / n8n)
///
/// Extension Ideas:
/// • Bulk document operations
/// • Document search / filter
/// • Embedding preview & dimensional stats
/// • Collection metadata (created_at, doc count)
/// • Optimistic updates & undo
class RagScreen extends StatefulWidget {
  const RagScreen({super.key});

  @override
  State<RagScreen> createState() => _RagScreenState();
}

class _RagScreenState extends State<RagScreen> {
  // Collections state
  List<String> _collections = [];
  bool _loadingCollections = false;
  String? _collectionsError;

  // Active collection
  String? _activeCollection; // normalized

  // Documents state
  final int _pageSize = 50;
  int _docOffset = 0;
  bool _loadingDocs = false;
  bool _docsExhausted = false;
  String? _docsError;
  final List<RagDocument> _documents = [];

  // UI controllers
  final TextEditingController _newCollectionCtrl = TextEditingController();
  final ScrollController _docScroll = ScrollController();

  bool _creatingCollection = false;
  bool _addingDocument = false;
  // Ingestion / progress state
  bool _ingesting = false;
  int _ingestFileIndex = 0;
  int _ingestFileTotal = 0;
  int _ingestTotalChunks = 0;
  int _ingestTotalInserted = 0;
  bool _dropHover = false;
  bool get _isDesktop =>
      !kIsWeb && (Platform.isLinux || Platform.isMacOS || Platform.isWindows);

  @override
  void initState() {
    super.initState();
    _fetchCollections();
    _docScroll.addListener(_onScrollDocs);
  }

  @override
  void dispose() {
    _newCollectionCtrl.dispose();
    _docScroll.dispose();
    super.dispose();
  }

  // --- Data Loading -----------------------------------------------------------

  Future<void> _fetchCollections({bool force = false}) async {
    setState(() {
      _loadingCollections = true;
      _collectionsError = null;
    });
    final result = await ragRepository.listCollections(forceRefresh: force);
    if (!mounted) return;
    result.when(
      success: (list) {
        setState(() {
          _collections = list;
          _loadingCollections = false;
        });
        // Ensure active collection remains valid
        if (_activeCollection != null &&
            !_collections.contains(_activeCollection)) {
          _setActiveCollection(null);
        }
      },
      failure: (err) {
        setState(() {
          _collectionsError = err.message;
          _collections = [];
          _loadingCollections = false;
        });
      },
    );
  }

  Future<void> _reloadDocuments({bool reset = false}) async {
    if (_activeCollection == null) {
      setState(() {
        _documents.clear();
        _docsExhausted = true;
        _docsError = null;
      });
      return;
    }
    if (_loadingDocs) return;

    if (reset) {
      setState(() {
        _documents.clear();
        _docOffset = 0;
        _docsExhausted = false;
        _docsError = null;
      });
    }

    if (_docsExhausted) return;

    setState(() {
      _loadingDocs = true;
      _docsError = null;
    });

    final res = await ragRepository.listDocuments(
      collection: _activeCollection!,
      limit: _pageSize,
      offset: _docOffset,
      forceRefresh: true, // always fetch fresh for accuracy
    );

    if (!mounted) return;
    res.when(
      success: (page) {
        setState(() {
          if (_docOffset == 0) {
            _documents
              ..clear()
              ..addAll(page.documents);
          } else {
            _documents.addAll(page.documents);
          }
          _docOffset += page.documents.length;
          // If we received fewer than requested or count < limit -> no more
          // (API returns count == number returned for page)
          if (page.documents.length < _pageSize) {
            _docsExhausted = true;
          }
          _loadingDocs = false;
        });
      },
      failure: (err) {
        setState(() {
          _docsError = err.message;
          _loadingDocs = false;
        });
      },
    );
  }

  // --- Event Handlers ---------------------------------------------------------

  void _onScrollDocs() {
    if (_docScroll.position.pixels >
            _docScroll.position.maxScrollExtent - 200 &&
        !_loadingDocs &&
        !_docsExhausted) {
      _reloadDocuments();
    }
  }

  void _setActiveCollection(String? name) {
    setState(() {
      _activeCollection = name;
    });
    ragRepository.setActiveCollection(name);
    _reloadDocuments(reset: true);
  }

  Future<void> _createCollection() async {
    final name = _newCollectionCtrl.text.trim();
    if (name.isEmpty || _creatingCollection) return;
    setState(() => _creatingCollection = true);
    final res = await ragRepository.createCollection(name);
    if (!mounted) return;
    res.when(
      success: (normalized) {
        _newCollectionCtrl.clear();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Collection created: $normalized')),
        );
        _fetchCollections(force: true);
        _setActiveCollection(normalized);
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Create failed: ${err.message}')),
        );
      },
    );
    if (mounted) {
      setState(() => _creatingCollection = false);
    }
  }

  Future<void> _deleteCollection(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Collection'),
        content: Text(
          'Delete "$name" and all its documents? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final res = await ragRepository.deleteCollection(name);
    if (!mounted) return;
    res.when(
      success: (deleted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleted
                  ? 'Collection deleted: $name'
                  : 'Collection not found (already deleted)',
            ),
          ),
        );
        _fetchCollections(force: true);
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${err.message}')),
        );
      },
    );
  }

  Future<void> _addDocument() async {
    if (_activeCollection == null) return;
    setState(() => _addingDocument = true);
    final content = await _showDocumentEditor();
    if (content == null || content.trim().isEmpty) {
      setState(() => _addingDocument = false);
      return;
    }
    final res = await ragRepository.addDocument(
      collection: _activeCollection!,
      content: content,
    );
    if (!mounted) return;
    res.when(
      success: (doc) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Document added (id=${doc.id})')),
        );
        _reloadDocuments(reset: true);
      },
      failure: (err) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Add failed: ${err.message}')));
      },
    );
    if (mounted) setState(() => _addingDocument = false);
  }

  Future<void> _editDocument(RagDocument doc) async {
    if (_activeCollection == null) return;
    final updated = await _showDocumentEditor(existing: doc.content);
    if (updated == null || updated.trim() == doc.content.trim()) return;

    final res = await ragRepository.updateDocument(
      collection: _activeCollection!,
      id: doc.id,
      content: updated,
    );
    if (!mounted) return;
    res.when(
      success: (_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Document updated (#${doc.id})')),
        );
        _reloadDocuments(reset: true);
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: ${err.message}')),
        );
      },
    );
  }

  Future<void> _deleteDocument(RagDocument doc) async {
    if (_activeCollection == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Document'),
        content: Text('Delete document #${doc.id}? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final res = await ragRepository.deleteDocument(
      collection: _activeCollection!,
      id: doc.id,
    );
    if (!mounted) return;
    res.when(
      success: (deleted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deleted ? 'Document deleted (#${doc.id})' : 'Document not found',
            ),
          ),
        );
        _reloadDocuments(reset: true);
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${err.message}')),
        );
      },
    );
  }

  // --- Dialogs ----------------------------------------------------------------

  Future<String?> _showDocumentEditor({String? existing}) async {
    final controller = TextEditingController(text: existing ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New Document' : 'Edit Document'),
        content: SizedBox(
          width: 480,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 300),
            child: Scrollbar(
              child: TextField(
                controller: controller,
                maxLines: null,
                decoration: const InputDecoration(
                  hintText: 'Enter document content...',
                ),
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(existing == null ? 'Add' : 'Save'),
          ),
        ],
      ),
    );
  }

  // --- UI ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Use Provider settings to allow theme switch actions if needed
    // Removed unused SettingsController reference (theme toggle handled globally)
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: Stack(
        children: [
          Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 6),
                child: Row(
                  children: [
                    const Text(
                      'RAG Management',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 16),
                    if (_activeCollection != null)
                      Tooltip(
                        message: 'Pick Files (pdf / txt)',
                        child: IconButton(
                          icon: const Icon(Icons.upload_file_outlined),
                          onPressed: _ingesting ? null : _pickAndIngestFile,
                        ),
                      ),
                    Tooltip(
                      message: 'Add Manual Document',
                      child: IconButton(
                        icon: const Icon(Icons.note_add_outlined),
                        onPressed:
                            _activeCollection == null ||
                                _addingDocument ||
                                _ingesting
                            ? null
                            : _addDocument,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Refresh All',
                      onPressed: (_loadingCollections || _ingesting)
                          ? null
                          : () {
                              _fetchCollections(force: true);
                              if (_activeCollection != null) {
                                _reloadDocuments(reset: true);
                              }
                            },
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: Row(
                  children: [
                    // Collections
                    SizedBox(
                      width: 280,
                      child: Column(
                        children: [
                          _buildCollectionHeader(theme),
                          const Divider(height: 1),
                          Expanded(child: _buildCollectionsList(theme)),
                          _buildCreateCollectionCard(theme),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    // Documents
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildDocumentsHeader(theme),
                          const Divider(height: 1),
                          if (_isDesktop && _activeCollection != null)
                            _buildDropZone(theme),
                          Expanded(child: _buildDocumentsList(theme)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_ingesting) _buildIngestOverlay(theme),
        ],
      ),
      floatingActionButton: _activeCollection == null
          ? null
          : FloatingActionButton.extended(
              onPressed: _addingDocument || _ingesting ? null : _addDocument,
              icon: _addingDocument
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.note_add_outlined),
              label: Text(_addingDocument ? 'Adding...' : 'Add Document'),
            ),
    );
  }

  // --- Collection UI ----------------------------------------------------------

  Widget _buildCollectionHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Collections',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          if (_loadingCollections)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _buildCollectionsList(ThemeData theme) {
    if (_collectionsError != null) {
      return _ErrorPane(
        message: _collectionsError!,
        onRetry: () => _fetchCollections(force: true),
      );
    }
    if (_loadingCollections && _collections.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_collections.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No collections yet.\nCreate one below.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _collections.length,
      itemBuilder: (ctx, i) {
        final name = _collections[i];
        final active = name == _activeCollection;
        return ListTile(
          dense: true,
          selected: active,
          title: Text(
            name,
            style: TextStyle(
              fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          onTap: () => _setActiveCollection(name),
          trailing: IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            color: theme.colorScheme.error.withOpacity(0.85),
            onPressed: () => _deleteCollection(name),
          ),
        );
      },
    );
  }

  Widget _buildCreateCollectionCard(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Create Collection',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _newCollectionCtrl,
                decoration: const InputDecoration(
                  hintText: 'e.g. product_docs',
                  isDense: true,
                ),
                onSubmitted: (_) => _createCollection(),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _creatingCollection ? null : _createCollection,
                  child: _creatingCollection
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Create'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- Documents UI -----------------------------------------------------------

  Widget _buildDocumentsHeader(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _activeCollection == null
                      ? 'Documents'
                      : 'Documents • ${_activeCollection!}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 4,
                  children: [
                    Chip(
                      label: Text('Loaded: ${_documents.length}'),
                      padding: EdgeInsets.zero,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    if (!_docsExhausted)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Load more'),
                        onPressed: _loadingDocs
                            ? null
                            : () => _reloadDocuments(),
                      ),
                    if (_ingesting)
                      Text(
                        'Ingesting ${_ingestFileIndex}/${_ingestFileTotal} '
                        'files • Chunks ${_ingestTotalInserted}/${_ingestTotalChunks}',
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _activeCollection == null || _ingesting
                ? null
                : () => _reloadDocuments(reset: true),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentsList(ThemeData theme) {
    if (_activeCollection == null) {
      return const _HintPane(
        message: 'Select or create a collection to view documents.',
      );
    }
    if (_docsError != null && _documents.isEmpty) {
      return _ErrorPane(
        message: _docsError!,
        onRetry: () => _reloadDocuments(reset: true),
      );
    }
    if (_loadingDocs && _documents.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_documents.isEmpty) {
      return const _HintPane(
        message:
            'No documents in this collection yet.\nUse the "Add Document" button to insert content.',
      );
    }

    return RefreshIndicator(
      onRefresh: () => _reloadDocuments(reset: true),
      child: ListView.builder(
        controller: _docScroll,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 100),
        itemCount: _documents.length + 1,
        itemBuilder: (ctx, i) {
          if (i == _documents.length) {
            if (_docsExhausted) {
              return const SizedBox(height: 40);
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: _loadingDocs
                    ? const CircularProgressIndicator()
                    : const SizedBox.shrink(),
              ),
            );
          }

          final doc = _documents[i];
          return _DocumentTile(
            document: doc,
            onEdit: () => _editDocument(doc),
            onDelete: () => _deleteDocument(doc),
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // File Ingestion (pdf / txt) - inside state class
  // Simple path-based ingestion (desktop / dev). Prompts for a local path,
  // sends multipart request to backend ingest endpoint.
  Future<void> _pickAndIngestFile() async {
    if (_activeCollection == null || _ingesting) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a collection first')),
      );
      return;
    }
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ['pdf', 'txt'],
      withData: false,
    );
    if (result == null || result.files.isEmpty) return;
    final files = result.files
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .where((f) {
          final l = f.path.toLowerCase();
          return l.endsWith('.pdf') || l.endsWith('.txt');
        })
        .toList();
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No supported files selected')),
      );
      return;
    }
    await _ingestFiles(files);
  }

  Future<void> _ingestFiles(List<File> files) async {
    setState(() {
      _ingesting = true;
      _ingestFileIndex = 0;
      _ingestFileTotal = files.length;
      _ingestTotalChunks = 0;
      _ingestTotalInserted = 0;
    });

    for (var i = 0; i < files.length; i++) {
      setState(() => _ingestFileIndex = i + 1);
      try {
        await _ingestSingleFile(files[i]);
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ingest failed for ${files[i].path}: $e')),
        );
      }
    }

    setState(() {
      _ingesting = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Ingest complete: files $_ingestFileTotal • chunks $_ingestTotalInserted/$_ingestTotalChunks',
        ),
      ),
    );
    _reloadDocuments(reset: true);
  }

  Future<void> _ingestSingleFile(
    File file, {
    int chunkSize = 800,
    int overlap = 100,
  }) async {
    final base = AppConfig.instance.ragApiEndpoint.trim().replaceAll(
      RegExp(r'/+$'),
      '',
    );
    final uri = Uri.parse(
      '$base/collections/${_activeCollection!}/ingest_file',
    );

    final req = http.MultipartRequest('POST', uri)
      ..fields['chunk_size'] = '$chunkSize'
      ..fields['overlap'] = '$overlap'
      ..files.add(await http.MultipartFile.fromPath('file', file.path));

    final resp = await http.Response.fromStream(await req.send());
    if (resp.statusCode != 200) {
      throw Exception(
        'Status ${resp.statusCode} ${resp.body.isNotEmpty ? resp.body : ''}',
      );
    }
    try {
      final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
      _ingestTotalChunks += (decoded['chunks'] as int? ?? 0);
      _ingestTotalInserted += (decoded['inserted'] as int? ?? 0);
      setState(() {}); // refresh progress text
    } catch (_) {
      // ignore parse errors, progress still valid
    }
  }

  Widget _buildDropZone(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: DropTarget(
        onDragEntered: (_) => setState(() => _dropHover = true),
        onDragExited: (_) => setState(() => _dropHover = false),
        onDragDone: (details) async {
          if (_activeCollection == null || _ingesting) return;
          final files = details.files
              .where(
                (f) =>
                    f.path.toLowerCase().endsWith('.pdf') ||
                    f.path.toLowerCase().endsWith('.txt'),
              )
              .map((f) => File(f.path))
              .toList();
          if (files.isEmpty) return;
          await _ingestFiles(files);
          setState(() => _dropHover = false);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 90,
          decoration: BoxDecoration(
            border: Border.all(
              color: _dropHover
                  ? theme.colorScheme.primary
                  : theme.dividerColor.withOpacity(0.5),
              width: 2,
            ),
            borderRadius: BorderRadius.circular(14),
            color: _dropHover
                ? theme.colorScheme.primary.withOpacity(0.08)
                : theme.colorScheme.surfaceVariant.withOpacity(0.15),
          ),
          alignment: Alignment.center,
          child: Text(
            _dropHover
                ? 'Release to ingest files'
                : 'Drag & drop PDF / TXT files here',
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildIngestOverlay(ThemeData theme) {
    final progress = _ingestFileTotal == 0
        ? null
        : _ingestFileIndex / _ingestFileTotal.clamp(1, 1 << 30);
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: AnimatedOpacity(
          opacity: _ingesting ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            color: theme.colorScheme.scrim.withOpacity(0.55),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Card(
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.cloud_upload_outlined, size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Ingesting files '
                                '($_ingestFileIndex/$_ingestFileTotal)',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        LinearProgressIndicator(value: progress, minHeight: 6),
                        const SizedBox(height: 16),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Chunks inserted: $_ingestTotalInserted / $_ingestTotalChunks',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'Collection: ${_activeCollection ?? "-"}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Please keep this window open until ingestion completes.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
// --- Sub-Widgets --------------------------------------------------------------

class _DocumentTile extends StatelessWidget {
  final RagDocument document;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _DocumentTile({
    required this.document,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = document.content.trim().replaceAll('\n', ' ');
    final truncated = preview.length <= 160
        ? preview
        : '${preview.substring(0, 160)}…';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      color: theme.colorScheme.surfaceVariant.withOpacity(0.3),
      child: ListTile(
        title: Text(
          '#${document.id}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(
          truncated.isEmpty ? '(empty content)' : truncated,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12.5, height: 1.2),
        ),
        trailing: PopupMenuButton<String>(
          tooltip: 'Document Actions',
          onSelected: (value) {
            switch (value) {
              case 'edit':
                onEdit();
                break;
              case 'delete':
                onDelete();
                break;
            }
          },
          itemBuilder: (ctx) => const [
            PopupMenuItem(value: 'edit', child: Text('Edit')),
            PopupMenuItem(
              value: 'delete',
              child: Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
  }
}

class _HintPane extends StatelessWidget {
  final String message;
  const _HintPane({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurface.withOpacity(0.70),
          ),
        ),
      ),
    );
  }
}

class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const _ErrorPane({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 42, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: onRetry,
                child: const Text('Retry'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// End of file.
