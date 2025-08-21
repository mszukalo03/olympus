import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../shared/shared.dart';
import '../widgets/message_bubble.dart';
import 'settings_screen.dart';
import '../widgets/history_drawer.dart';
import '../../../features/rag/rag_screen.dart';
import '../../../shared/widgets/attachment_widgets.dart';

/// Chat screen showing conversation and input box.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  int _currentIndex = 0;
  List<MessageAttachment> _pendingAttachments = [];

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _send(ChatController controller) {
    final text = _input.text;
    final attachments = List<MessageAttachment>.from(_pendingAttachments);

    _input.clear();
    _pendingAttachments.clear();

    controller.sendMessage(text, attachments: attachments);
    _inputFocus.requestFocus();
    setState(() {}); // Refresh to clear attachment previews
  }

  void _onAttachmentsSelected(List<MessageAttachment> attachments) {
    setState(() {
      _pendingAttachments.addAll(attachments);
    });
  }

  void _removePendingAttachment(int index) {
    setState(() {
      _pendingAttachments.removeAt(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final settings = context.watch<SettingsController>();

    return Scaffold(
      drawer: _currentIndex == 0 ? const HistoryDrawer() : null,
      appBar: AppBar(
        title: Text(switch (_currentIndex) {
          0 => 'AI Orchestrator',
          1 => 'RAG',
          2 => 'Blank 2',
          _ => 'AI Orchestrator',
        }),
        actions: [
          IconButton(
            tooltip: 'Toggle Theme',
            icon: const Icon(Icons.brightness_6),
            onPressed: settings.toggleTheme,
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
            },
          ),
          IconButton(
            tooltip: 'New Chat',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: chat.isSending ? null : chat.startNewRemoteConversation,
          ),
          IconButton(
            tooltip: 'Save Chat',
            icon: const Icon(Icons.save_outlined),
            onPressed: chat.messages.isEmpty ? null : chat.saveConversation,
          ),
        ],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: [
          _buildChatTab(chat),
          const RagScreen(),
          const _PlaceholderScreen(label: 'Blank 2'),
        ],
      ),

      /// builds bottom app bar
      ///
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) => setState(() => _currentIndex = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Chat',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.dashboard_outlined),
            label: 'RAG',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person_outline),
            label: 'Blank 2',
          ),
        ],
      ),
    );
  }

  Widget _buildChatTab(ChatController chat) {
    return Column(
      children: [
        if (!chat.isOnline)
          Container(
            width: double.infinity,
            color: Colors.orange.shade700,
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
            child: const Text(
              'Offline mode: external automation will pause.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            itemCount: chat.messages.length,
            itemBuilder: (context, index) {
              final m = chat.messages[index];
              return MessageBubble(message: m);
            },
          ),
        ),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Column(
            children: [
              // Attachment preview area
              if (_pendingAttachments.isNotEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _pendingAttachments.asMap().entries.map((entry) {
                      final index = entry.key;
                      final attachment = entry.value;
                      return Stack(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(context).dividerColor,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: attachment.type == AttachmentType.image
                                  ? _buildImagePreview(attachment)
                                  : _buildAudioPreview(attachment),
                            ),
                          ),
                          Positioned(
                            top: 2,
                            right: 2,
                            child: GestureDetector(
                              onTap: () => _removePendingAttachment(index),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(
                                  color: Colors.red,
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                  size: 14,
                                ),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),

              // Recording indicator
              if (AttachmentService.instance.isRecording)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: RecordingIndicator(
                    isRecording: AttachmentService.instance.isRecording,
                    onCancel: () async {
                      await AttachmentService.instance.cancelRecording();
                      setState(() {});
                    },
                  ),
                ),

              // Input area
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    // Attachment toolbar
                    AttachmentInputToolbar(
                      onAttachmentsSelected: _onAttachmentsSelected,
                      enabled: !chat.isSending,
                    ),

                    // Text input
                    Expanded(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: Scrollbar(
                          child: TextField(
                            controller: _input,
                            focusNode: _inputFocus,
                            textInputAction: TextInputAction.send,
                            maxLines: null,
                            onSubmitted: (_) => _send(chat),
                            decoration: InputDecoration(
                              hintText: 'Type a message... (Shift+Enter newline)',
                              suffixIcon: chat.isSending
                                  ? const Padding(
                                      padding: EdgeInsets.all(12.0),
                                      child: SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    )
                                  : null,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Send button
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: chat.isSending ? null : () => _send(chat),
                      icon: const Icon(Icons.send),
                      label: const Text('Send'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildImagePreview(MessageAttachment attachment) {
    if (attachment.localPath != null) {
      return Image.file(
        File(attachment.localPath!),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => _buildErrorPreview(),
      );
    }
    return _buildErrorPreview();
  }

  Widget _buildAudioPreview(MessageAttachment attachment) {
    return Container(
      color: Colors.grey.shade200,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.audiotrack, color: Colors.grey),
          SizedBox(height: 4),
          Text(
            'Audio',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorPreview() {
    return Container(
      color: Colors.grey.shade300,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, color: Colors.grey),
          SizedBox(height: 4),
          Text(
            'Error',
            style: TextStyle(fontSize: 10, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}

class _PlaceholderScreen extends StatelessWidget {
  final String label;
  const _PlaceholderScreen({required this.label});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        '$label Screen',
        style: Theme.of(context).textTheme.titleLarge,
      ),
    );
  }
}
