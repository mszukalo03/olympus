import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;
import 'package:provider/provider.dart';

import '../../../shared/shared.dart';
import '../../../core/core.dart';

/// HistoryDrawer (Remote Backend Version)
/// ---------------------------------------------------------------------------
/// Uses the remote Postgres/Flask history backend (`historyRepository`) to
/// manage conversation metadata and transcripts. Features:
///   • List paginated remote conversations (with message counts & titles)
///   • Load a conversation (optionally fetch full history) into the chat
///   • Rename a conversation (title distinct from numeric id)
///   • Delete a conversation (remote DELETE + cache purge)
///   • Bulk multi‑select & delete
///   • Export a conversation to JSON
///   • Export a conversation to PDF (full transcript)
///   • Simple next/previous pagination controls
///
/// Future extension ideas: similarity search UI, tag filtering,
/// optimistic inline editing, multi‑select export.
///
/// Assumptions:
///   • Backend endpoints already configured in Settings (history_api)
///   • ChatController now persists each message remotely as user/ai
class HistoryDrawer extends StatefulWidget {
  const HistoryDrawer({super.key});

  @override
  State<HistoryDrawer> createState() => _HistoryDrawerState();
}

class _HistoryDrawerState extends State<HistoryDrawer> {
  bool _loading = true;
  String? _error;

  // Remote conversation summaries (first page)
  List<RemoteConversation> _conversations = [];
  int _page = 1;
  bool _hasNext = false;
  final int _pageSize = 20;

  // Multi‑select / bulk delete state
  bool _selectionMode = false;
  final Set<int> _selected = {};

  int get _selectedCount => _selected.length;

  @override
  void initState() {
    super.initState();
    _fetchConversations();
  }

  Future<void> _fetchConversations({int page = 1, bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
      // Clear selections when reloading a different page
      if (page != _page) {
        _selectionMode = false;
        _selected.clear();
      }
    });

    final result = await historyRepository.list(
      page: page,
      pageSize: _pageSize,
      includeCounts: true,
      forceRefresh: force,
    );

    if (!mounted) return;

    result.when(
      success: (paged) {
        setState(() {
          _conversations = paged.items;
          _page = paged.page;
          _hasNext = paged.hasNext;
          _loading = false;
        });
      },
      failure: (err) {
        setState(() {
          _error = err.message;
          _conversations = [];
          _loading = false;
        });
      },
    );
  }

  void _toggleSelectionMode([bool? enable]) {
    setState(() {
      _selectionMode = enable ?? !_selectionMode;
      if (!_selectionMode) _selected.clear();
    });
  }

  void _toggleSelect(int id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else {
        _selected.add(id);
      }
      if (_selected.isEmpty) {
        _selectionMode = false;
      }
    });
  }

  Future<void> _bulkDelete() async {
    if (_selected.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Bulk Delete'),
        content: Text(
          'Delete ${_selected.length} selected conversation(s)? This cannot be undone.',
        ),
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

    final ids = _selected.toList();
    final res = await historyRepository.bulkDelete(ids);
    if (!mounted) return;
    res.when(
      success: (result) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Deleted ${result.deleted.length}/${result.requested.length}'
              '${result.notFound.isNotEmpty ? ' (${result.notFound.length} not found)' : ''}',
            ),
          ),
        );
        _toggleSelectionMode(false);
        _fetchConversations(page: _page, force: true);
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Bulk delete failed: ${err.message}')),
        );
      },
    );
  }

  Future<void> _loadRemote(RemoteConversation convo) async {
    final chat = context.read<ChatController>();
    await chat.loadRemoteConversation(convo.id, fetchAll: true);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Loaded conversation ${convo.id}')));
  }

  Future<void> _exportJson(RemoteConversation convo) async {
    final res = await historyRepository.exportConversation(convo.id);
    res.when(
      success: (data) async {
        try {
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/remote_conversation_${convo.id}.json');
          await file.writeAsString(
            const JsonEncoder.withIndent('  ').convert(data),
          );
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('JSON saved: ${file.path}')));
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
        }
      },
      failure: (err) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export error: ${err.message}')));
      },
    );
  }

  Future<void> _exportPdf(RemoteConversation convo) async {
    final detail = await historyRepository.loadConversation(
      convo.id,
      fetchAll: true,
    );
    detail.when(
      success: (loaded) async {
        try {
          final doc = pw.Document();
          doc.addPage(
            pw.MultiPage(
              pageTheme: pw.PageTheme(
                margin: const pw.EdgeInsets.all(28),
                textDirection: pw.TextDirection.ltr,
              ),
              build: (ctx) => [
                pw.Header(
                  level: 0,
                  child: pw.Text(
                    'Conversation ${convo.id}',
                    style: pw.TextStyle(
                      fontSize: 20,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
                pw.Paragraph(
                  text:
                      'Created: ${convo.createdAt.toIso8601String()}\nMessages: ${loaded.messageCount}',
                ),
                pw.SizedBox(height: 12),
                ...loaded.messages.map(
                  (m) => pw.Container(
                    margin: const pw.EdgeInsets.only(bottom: 6),
                    padding: const pw.EdgeInsets.all(8),
                    decoration: pw.BoxDecoration(
                      color: _pdfBgForRole(m.role),
                      borderRadius: pw.BorderRadius.circular(4),
                    ),
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          '${m.role.name.toUpperCase()} • ${m.timestamp.toIso8601String()}',
                          style: pw.TextStyle(
                            fontSize: 10,
                            color: pdf.PdfColors.grey700,
                            fontWeight: pw.FontWeight.bold,
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(m.content),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
          final bytes = await doc.save();
          final dir = await getApplicationDocumentsDirectory();
          final file = File('${dir.path}/remote_conversation_${convo.id}.pdf');
          await file.writeAsBytes(bytes, flush: true);
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('PDF saved: ${file.path}')));
        } catch (e) {
          if (!mounted) return;
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('PDF export failed: $e')));
        }
      },
      failure: (err) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Load failed: ${err.message}')));
      },
    );
  }

  Future<void> _renameConversation(RemoteConversation convo) async {
    final controller = TextEditingController(text: convo.title ?? '');
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Conversation'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Title',
            hintText: 'Enter a descriptive name',
          ),
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => Navigator.pop(ctx, controller.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;
    final res = await historyRepository.updateTitle(convo.id, newTitle);
    if (!mounted) return;
    res.when(
      success: (_) {
        _fetchConversations(page: _page, force: true);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Conversation renamed')));
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rename failed: ${err.message}')),
        );
      },
    );
  }

  Future<void> _deleteConversation(RemoteConversation convo) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Conversation'),
        content: Text(
          'Delete "${convo.displayTitle}" and all its messages? This cannot be undone.',
        ),
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
    final res = await historyRepository.deleteConversation(convo.id);
    if (!mounted) return;
    res.when(
      success: (deleted) {
        if (deleted) {
          _fetchConversations(page: _page, force: true);
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Conversation deleted')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Conversation already removed')),
          );
        }
      },
      failure: (err) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: ${err.message}')),
        );
      },
    );
  }

  pdf.PdfColor _pdfBgForRole(MessageRole role) {
    switch (role) {
      case MessageRole.user:
        return pdf.PdfColors.blue50;
      case MessageRole.assistant:
        return pdf.PdfColors.green50;
      case MessageRole.system:
        return pdf.PdfColors.grey200;
      case MessageRole.error:
        return pdf.PdfColors.red50;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UIConstants.spacingL,
                UIConstants.spacingS,
                UIConstants.spacingS,
                UIConstants.spacingXS,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: UIConstants.animationFast,
                      child: !_selectionMode
                          ? const Text(
                              'History (Remote)',
                              key: ValueKey('title-normal'),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            )
                          : Text(
                              '$_selectedCount selected',
                              key: const ValueKey('title-select'),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                    ),
                  ),
                  if (_selectionMode) ...[
                    IconButton(
                      tooltip: 'Delete Selected',
                      onPressed: _selected.isEmpty ? null : () => _bulkDelete(),
                      icon: const Icon(Icons.delete_forever_outlined),
                      color: theme.colorScheme.error,
                    ),
                    IconButton(
                      tooltip: 'Cancel Selection',
                      onPressed: () => _toggleSelectionMode(false),
                      icon: const Icon(Icons.close),
                    ),
                  ] else ...[
                    IconButton(
                      tooltip: 'Select Multiple',
                      onPressed: _conversations.isEmpty
                          ? null
                          : () => _toggleSelectionMode(true),
                      icon: const Icon(Icons.checklist_outlined),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: () => _fetchConversations(force: true),
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
            if (!_loading) _buildPagingBar(),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(UIConstants.spacingL),
          child: Text(
            _error!,
            style: const TextStyle(color: Colors.red),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    if (_conversations.isEmpty) {
      return const Center(
        child: Text(
          'No remote conversations yet.\nStart chatting to create one.',
          textAlign: TextAlign.center,
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: UIConstants.spacingS),
      itemCount: _conversations.length,
      separatorBuilder: (_, __) =>
          const SizedBox(height: UIConstants.spacingXS),
      itemBuilder: (context, index) {
        final convo = _conversations[index];
        final selected = _selected.contains(convo.id);
        return _RemoteConversationTile(
          conversation: convo,
          selectionMode: _selectionMode,
          selected: selected,
          onToggleSelect: () => _toggleSelect(convo.id),
          onLoad: () {
            if (_selectionMode) {
              _toggleSelect(convo.id);
            } else {
              _loadRemote(convo);
            }
          },
          onExportJson: () => _exportJson(convo),
          onExportPdf: () => _exportPdf(convo),
          onRename: () => _renameConversation(convo),
          onDelete: () => _deleteConversation(convo),
        );
      },
    );
  }

  Widget _buildPagingBar() {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UIConstants.spacingS,
          0,
          UIConstants.spacingS,
          UIConstants.spacingS,
        ),
        child: Row(
          children: [
            Text('Page $_page', style: Theme.of(context).textTheme.labelMedium),
            const Spacer(),
            IconButton(
              tooltip: 'Previous Page',
              onPressed: _page > 1
                  ? () => _fetchConversations(page: _page - 1)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              tooltip: 'Next Page',
              onPressed: _hasNext
                  ? () => _fetchConversations(page: _page + 1)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tile for a remote conversation summary.
class _RemoteConversationTile extends StatelessWidget {
  final RemoteConversation conversation;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onToggleSelect;
  final VoidCallback onLoad;
  final VoidCallback onExportJson;
  final VoidCallback onExportPdf;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _RemoteConversationTile({
    required this.conversation,
    required this.selectionMode,
    required this.selected,
    required this.onToggleSelect,
    required this.onLoad,
    required this.onExportJson,
    required this.onExportPdf,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle =
        'Created: ${conversation.createdAt.toIso8601String()}'
        '${conversation.messageCount != null ? ' • Messages: ${conversation.messageCount}' : ''}';

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: UIConstants.spacingS),
      child: ListTile(
        leading: selectionMode
            ? Checkbox(value: selected, onChanged: (_) => onToggleSelect())
            : null,
        title: Text(
          conversation.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 11)),
        onTap: onLoad,
        onLongPress: selectionMode ? onToggleSelect : onToggleSelect,
        trailing: selectionMode
            ? null
            : PopupMenuButton<String>(
                tooltip: 'Actions',
                onSelected: (value) {
                  switch (value) {
                    case 'load':
                      onLoad();
                      break;
                    case 'json':
                      onExportJson();
                      break;
                    case 'pdf':
                      onExportPdf();
                      break;
                    case 'rename':
                      onRename();
                      break;
                    case 'delete':
                      onDelete();
                      break;
                  }
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem(value: 'load', child: Text('Load')),
                  PopupMenuItem(value: 'json', child: Text('Export JSON')),
                  PopupMenuItem(value: 'pdf', child: Text('Export PDF')),
                  PopupMenuItem(value: 'rename', child: Text('Rename')),
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

// End of file.
