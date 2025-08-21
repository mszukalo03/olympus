/// Attachment Widgets
/// ---------------------------------------------------------------------------
/// UI components for displaying and managing message attachments.
/// Includes image previews, audio players, attachment buttons, and recording UI.
library attachment_widgets;

import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:logging/logging.dart';

import '../models/chat_message.dart';
import '../services/attachment_service.dart';
import '../../core/core.dart';

/// Attachment preview widget for message bubbles
class AttachmentPreview extends StatelessWidget {
  final List<MessageAttachment> attachments;
  final bool isUser;
  final VoidCallback? onAttachmentTap;

  const AttachmentPreview({
    super.key,
    required this.attachments,
    required this.isUser,
    this.onAttachmentTap,
  });

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...attachments.map((attachment) => Padding(
          padding: const EdgeInsets.only(bottom: 8.0),
          child: _buildAttachmentWidget(context, attachment),
        )),
      ],
    );
  }

  Widget _buildAttachmentWidget(BuildContext context, MessageAttachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        return ImageAttachmentWidget(
          attachment: attachment,
          onTap: onAttachmentTap,
        );
      case AttachmentType.audio:
        return AudioAttachmentWidget(
          attachment: attachment,
          isUser: isUser,
        );
    }
  }
}

/// Image attachment widget
class ImageAttachmentWidget extends StatelessWidget {
  final MessageAttachment attachment;
  final VoidCallback? onTap;

  const ImageAttachmentWidget({
    super.key,
    required this.attachment,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap ?? () => _showFullImage(context),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: 250,
          maxHeight: 200,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Theme.of(context).dividerColor.withOpacity(0.3),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: _buildImage(),
        ),
      ),
    );
  }

  Widget _buildImage() {
    if (attachment.localPath != null) {
      final file = File(attachment.localPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
        );
      }
    }

    if (attachment.base64Data != null) {
      try {
        final bytes = base64Decode(attachment.base64Data!);
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) => _buildErrorWidget(),
        );
      } catch (e) {
        return _buildErrorWidget();
      }
    }

    return _buildErrorWidget();
  }

  Widget _buildErrorWidget() {
    return Container(
      width: 150,
      height: 100,
      color: Colors.grey.shade300,
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, color: Colors.grey),
          SizedBox(height: 4),
          Text(
            'Image not available',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  void _showFullImage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => FullImageViewer(attachment: attachment),
      ),
    );
  }
}

/// Full screen image viewer
class FullImageViewer extends StatelessWidget {
  final MessageAttachment attachment;

  const FullImageViewer({super.key, required this.attachment});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(attachment.fileName ?? 'Image'),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: () => _showImageInfo(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          panEnabled: true,
          boundaryMargin: const EdgeInsets.all(20),
          minScale: 0.5,
          maxScale: 4,
          child: _buildFullImage(),
        ),
      ),
    );
  }

  Widget _buildFullImage() {
    if (attachment.localPath != null) {
      final file = File(attachment.localPath!);
      if (file.existsSync()) {
        return Image.file(file);
      }
    }

    if (attachment.base64Data != null) {
      try {
        final bytes = base64Decode(attachment.base64Data!);
        return Image.memory(bytes);
      } catch (e) {
        return const Center(
          child: Text(
            'Unable to display image',
            style: TextStyle(color: Colors.white),
          ),
        );
      }
    }

    return const Center(
      child: Text(
        'Image not available',
        style: TextStyle(color: Colors.white),
      ),
    );
  }

  void _showImageInfo(BuildContext context) {
    final width = attachment.metadata?['width'];
    final height = attachment.metadata?['height'];
    final sizeText = attachment.fileSizeBytes != null
        ? AttachmentService.formatFileSize(attachment.fileSizeBytes!)
        : 'Unknown';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Image Information'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (attachment.fileName != null)
              Text('Name: ${attachment.fileName}'),
            Text('Type: ${attachment.mimeType ?? 'Unknown'}'),
            Text('Size: $sizeText'),
            if (width != null && height != null)
              Text('Dimensions: ${width}x$height'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// Audio attachment widget with playback controls
class AudioAttachmentWidget extends StatefulWidget {
  final MessageAttachment attachment;
  final bool isUser;

  const AudioAttachmentWidget({
    super.key,
    required this.attachment,
    required this.isUser,
  });

  @override
  State<AudioAttachmentWidget> createState() => _AudioAttachmentWidgetState();
}

class _AudioAttachmentWidgetState extends State<AudioAttachmentWidget> {
  static final Logger _log = Logger('AudioAttachmentWidget');
  late AudioPlayer _audioPlayer;

  bool _isPlaying = false;
  bool _isLoading = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _audioPlayer = AudioPlayer();
    _setupAudioPlayer();
  }

  void _setupAudioPlayer() {
    _audioPlayer.onDurationChanged.listen((duration) {
      if (mounted) {
        setState(() {
          _duration = duration;
        });
      }
    });

    _audioPlayer.onPositionChanged.listen((position) {
      if (mounted) {
        setState(() {
          _position = position;
        });
      }
    });

    _audioPlayer.onPlayerStateChanged.listen((state) {
      if (mounted) {
        setState(() {
          _isPlaying = state == PlayerState.playing;
          _isLoading = state == PlayerState.preparing;
        });
      }
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final durationText = widget.attachment.metadata?['duration'] != null
        ? AttachmentService.formatDuration(widget.attachment.metadata!['duration'])
        : _formatDuration(_duration);

    return Container(
      width: 250,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.isUser
            ? theme.colorScheme.primaryContainer.withOpacity(0.3)
            : theme.colorScheme.surfaceVariant.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: theme.dividerColor.withOpacity(0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.audiotrack,
                size: 16,
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.attachment.fileName ?? 'Audio',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                durationText,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                onPressed: _isLoading ? null : _togglePlayback,
                icon: _isLoading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(
                            theme.colorScheme.primary,
                          ),
                        ),
                      )
                    : Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        color: theme.colorScheme.primary,
                      ),
                iconSize: 24,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
              ),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                    ),
                    trackHeight: 3,
                  ),
                  child: Slider(
                    value: _duration.inMilliseconds > 0
                        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: _onSliderChanged,
                    activeColor: theme.colorScheme.primary,
                    inactiveColor: theme.colorScheme.outline.withOpacity(0.3),
                  ),
                ),
              ),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _formatDuration(_position),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
              Text(
                _formatDuration(_duration),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _togglePlayback() async {
    try {
      if (_isPlaying) {
        await _audioPlayer.pause();
      } else {
        await _playAudio();
      }
    } catch (e) {
      _log.warning('Audio playback error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to play audio: $e')),
        );
      }
    }
  }

  Future<void> _playAudio() async {
    // Try to play from local file first
    if (widget.attachment.localPath != null) {
      final file = File(widget.attachment.localPath!);
      if (await file.exists()) {
        await _audioPlayer.play(DeviceFileSource(file.path));
        return;
      }
    }

    // Fallback to base64 data (more complex, requires temporary file)
    if (widget.attachment.base64Data != null) {
      await _playFromBase64();
    }
  }

  Future<void> _playFromBase64() async {
    try {
      final bytes = base64Decode(widget.attachment.base64Data!);

      // Create temporary file
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/temp_audio_${DateTime.now().millisecondsSinceEpoch}.m4a');
      await tempFile.writeAsBytes(bytes);

      await _audioPlayer.play(DeviceFileSource(tempFile.path));

      // Clean up temp file after a delay
      Future.delayed(const Duration(seconds: 30), () async {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      });
    } catch (e) {
      _log.warning('Failed to play audio from base64: $e');
      rethrow;
    }
  }

  void _onSliderChanged(double value) {
    if (_duration.inMilliseconds > 0) {
      final position = Duration(
        milliseconds: (value * _duration.inMilliseconds).round(),
      );
      _audioPlayer.seek(position);
    }
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }
}

/// Attachment input toolbar
class AttachmentInputToolbar extends StatefulWidget {
  final Function(List<MessageAttachment>) onAttachmentsSelected;
  final bool enabled;

  const AttachmentInputToolbar({
    super.key,
    required this.onAttachmentsSelected,
    this.enabled = true,
  });

  @override
  State<AttachmentInputToolbar> createState() => _AttachmentInputToolbarState();
}

class _AttachmentInputToolbarState extends State<AttachmentInputToolbar> {
  final AttachmentService _attachmentService = AttachmentService.instance;
  bool _isRecording = false;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          onPressed: widget.enabled ? _showAttachmentOptions : null,
          icon: const Icon(Icons.attach_file),
          tooltip: 'Attach files',
        ),
        IconButton(
          onPressed: widget.enabled ? _toggleRecording : null,
          icon: Icon(
            _isRecording ? Icons.stop : Icons.mic,
            color: _isRecording ? Colors.red : null,
          ),
          tooltip: _isRecording ? 'Stop recording' : 'Record audio',
        ),
      ],
    );
  }

  void _showAttachmentOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => AttachmentOptionsSheet(
        onOptionSelected: _handleAttachmentOption,
      ),
    );
  }

  Future<void> _handleAttachmentOption(AttachmentOption option) async {
    Navigator.pop(context); // Close bottom sheet

    switch (option) {
      case AttachmentOption.camera:
        await _pickImageFromCamera();
        break;
      case AttachmentOption.gallery:
        await _pickImageFromGallery();
        break;
      case AttachmentOption.multipleImages:
        await _pickMultipleImages();
        break;
      case AttachmentOption.audioFile:
        await _pickAudioFile();
        break;
    }
  }

  Future<void> _pickImageFromCamera() async {
    final result = await _attachmentService.pickImageFromCamera();
    result.when(
      success: (attachment) {
        if (attachment != null) {
          widget.onAttachmentsSelected([attachment]);
        }
      },
      failure: (error) => _showError(error.message),
    );
  }

  Future<void> _pickImageFromGallery() async {
    final result = await _attachmentService.pickImageFromGallery();
    result.when(
      success: (attachment) {
        if (attachment != null) {
          widget.onAttachmentsSelected([attachment]);
        }
      },
      failure: (error) => _showError(error.message),
    );
  }

  Future<void> _pickMultipleImages() async {
    final result = await _attachmentService.pickMultipleImages();
    result.when(
      success: (attachments) {
        if (attachments.isNotEmpty) {
          widget.onAttachmentsSelected(attachments);
        }
      },
      failure: (error) => _showError(error.message),
    );
  }

  Future<void> _pickAudioFile() async {
    final result = await _attachmentService.pickAudioFile();
    result.when(
      success: (attachment) {
        if (attachment != null) {
          widget.onAttachmentsSelected([attachment]);
        }
      },
      failure: (error) => _showError(error.message),
    );
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      await _stopRecording();
    } else {
      await _startRecording();
    }
  }

  Future<void> _startRecording() async {
    final result = await _attachmentService.startRecording();
    result.when(
      success: (_) {
        setState(() {
          _isRecording = true;
        });
      },
      failure: (error) => _showError(error.message),
    );
  }

  Future<void> _stopRecording() async {
    final result = await _attachmentService.stopRecording();
    result.when(
      success: (attachment) {
        setState(() {
          _isRecording = false;
        });
        if (attachment != null) {
          widget.onAttachmentsSelected([attachment]);
        }
      },
      failure: (error) {
        setState(() {
          _isRecording = false;
        });
        _showError(error.message);
      },
    );
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}

enum AttachmentOption {
  camera,
  gallery,
  multipleImages,
  audioFile,
}

/// Bottom sheet for attachment options
class AttachmentOptionsSheet extends StatelessWidget {
  final Function(AttachmentOption) onOptionSelected;

  const AttachmentOptionsSheet({
    super.key,
    required this.onOptionSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Wrap(
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: const Text('Take Photo'),
            onTap: () => onOptionSelected(AttachmentOption.camera),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: const Text('Choose from Gallery'),
            onTap: () => onOptionSelected(AttachmentOption.gallery),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Multiple Images'),
            onTap: () => onOptionSelected(AttachmentOption.multipleImages),
          ),
          ListTile(
            leading: const Icon(Icons.audio_file),
            title: const Text('Audio File'),
            onTap: () => onOptionSelected(AttachmentOption.audioFile),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.cancel),
            title: const Text('Cancel'),
            onTap: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }
}

/// Recording indicator widget
class RecordingIndicator extends StatefulWidget {
  final bool isRecording;
  final VoidCallback? onCancel;

  const RecordingIndicator({
    super.key,
    required this.isRecording,
    this.onCancel,
  });

  @override
  State<RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<RecordingIndicator>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(seconds: 1),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(
      begin: 0.8,
      end: 1.2,
    ).animate(CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    ));

    if (widget.isRecording) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(RecordingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isRecording && !oldWidget.isRecording) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isRecording && oldWidget.isRecording) {
      _pulseController.stop();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isRecording) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.red.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, child) {
              return Transform.scale(
                scale: _pulseAnimation.value,
                child: const Icon(
                  Icons.fiber_manual_record,
                  color: Colors.red,
                  size: 12,
                ),
              );
            },
          ),
          const SizedBox(width: 8),
          const Text(
            'Recording...',
            style: TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (widget.onCancel != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: widget.onCancel,
              child: const Icon(
                Icons.cancel,
                color: Colors.red,
                size: 18,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
