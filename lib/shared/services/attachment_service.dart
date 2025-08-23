/// Attachment Service
/// ---------------------------------------------------------------------------
/// Service for handling image and audio attachments in chat messages.
/// Provides file picking, validation, compression, and encoding functionality.
library;



import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';

import '../../core/core.dart';
import '../models/chat_message.dart';

/// Configuration for attachment handling
class AttachmentConfig {
  static const int maxImageSizeBytes = 10 * 1024 * 1024; // 10MB
  static const int maxAudioSizeBytes = 25 * 1024 * 1024; // 25MB
  static const int maxImageWidth = 2048;
  static const int maxImageHeight = 2048;
  static const int maxAudioDurationSeconds = 300; // 5 minutes

  static const List<String> supportedImageTypes = [
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
  ];

  static const List<String> supportedAudioTypes = [
    'audio/mpeg', // mp3
    'audio/wav',
    'audio/x-wav',
    'audio/mp4', // m4a
    'audio/aac',
    'audio/ogg',
  ];
}

/// Service for handling media attachments
class AttachmentService {
  static final AttachmentService _instance = AttachmentService._();
  factory AttachmentService() => _instance;
  static AttachmentService get instance => _instance;
  AttachmentService._();

  static final Logger _log = Logger('AttachmentService');
  final ImagePicker _imagePicker = ImagePicker();
  final AudioRecorder _audioRecorder = AudioRecorder();

  bool _isRecording = false;
  String? _currentRecordingPath;

  /// Check if currently recording
  bool get isRecording => _isRecording;

  /// Get current recording path
  String? get currentRecordingPath => _currentRecordingPath;

  // ---------------------------------------------------------------------------
  // Image Handling
  // ---------------------------------------------------------------------------

  /// Pick image from gallery
  Future<Result<MessageAttachment?>> pickImageFromGallery() async {
    return catchingAsync(() async {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: AttachmentConfig.maxImageWidth.toDouble(),
        maxHeight: AttachmentConfig.maxImageHeight.toDouble(),
        imageQuality: 85,
      );

      if (image == null) return null;

      return await _processImageFile(image);
    });
  }

  /// Pick image from camera
  Future<Result<MessageAttachment?>> pickImageFromCamera() async {
    return catchingAsync(() async {
      // Check camera permission
      final cameraStatus = await Permission.camera.request();
      if (!cameraStatus.isGranted) {
        throw AppError(
          message: 'Camera permission is required to take photos',
          type: ErrorType.forbidden,
        );
      }

      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.camera,
        maxWidth: AttachmentConfig.maxImageWidth.toDouble(),
        maxHeight: AttachmentConfig.maxImageHeight.toDouble(),
        imageQuality: 85,
      );

      if (image == null) return null;

      return await _processImageFile(image);
    });
  }

  /// Pick multiple images from gallery
  Future<Result<List<MessageAttachment>>> pickMultipleImages() async {
    return catchingAsync(() async {
      final List<XFile> images = await _imagePicker.pickMultiImage(
        maxWidth: AttachmentConfig.maxImageWidth.toDouble(),
        maxHeight: AttachmentConfig.maxImageHeight.toDouble(),
        imageQuality: 85,
      );

      if (images.isEmpty) return <MessageAttachment>[];

      final List<MessageAttachment> attachments = [];
      for (final image in images) {
        final attachment = await _processImageFile(image);
        attachments.add(attachment);
      }

      return attachments;
    });
  }

  /// Process image file into attachment
  Future<MessageAttachment> _processImageFile(XFile imageFile) async {
    final File file = File(imageFile.path);
    final Uint8List bytes = await file.readAsBytes();

    // Validate file size
    if (bytes.length > AttachmentConfig.maxImageSizeBytes) {
      throw AppError(
        message: 'Image size exceeds ${AttachmentConfig.maxImageSizeBytes ~/ (1024 * 1024)}MB limit',
        type: ErrorType.validation,
      );
    }

    // Get image dimensions
    final img.Image? decodedImage = img.decodeImage(bytes);
    final int? width = decodedImage?.width;
    final int? height = decodedImage?.height;

    // Convert to base64
    final String base64Data = base64Encode(bytes);

    // Determine MIME type
    String mimeType = imageFile.mimeType ?? 'image/jpeg';
    if (!AttachmentConfig.supportedImageTypes.contains(mimeType)) {
      mimeType = 'image/jpeg'; // Default fallback
    }

    return MessageAttachment.image(
      fileName: imageFile.name,
      mimeType: mimeType,
      fileSizeBytes: bytes.length,
      localPath: imageFile.path,
      base64Data: base64Data,
      width: width,
      height: height,
    );
  }

  // ---------------------------------------------------------------------------
  // Audio Handling
  // ---------------------------------------------------------------------------

  /// Start audio recording
  Future<Result<void>> startRecording() async {
    return catchingAsync(() async {
      if (_isRecording) {
        throw AppError(
          message: 'Already recording',
          type: ErrorType.validation,
        );
      }

      // Check microphone permission (skip on Linux/desktop where it's not needed)
      if (Platform.isAndroid || Platform.isIOS) {
        final micStatus = await Permission.microphone.request();
        if (!micStatus.isGranted) {
          throw AppError(
            message: 'Microphone permission is required to record audio',
            type: ErrorType.forbidden,
          );
        }
      }

      // Check if device has recording capability
      final hasPermission = await _audioRecorder.hasPermission();
      if (!hasPermission) {
        throw AppError(
          message: 'Recording permission denied',
          type: ErrorType.forbidden,
        );
      }

      // Generate temporary file path
      final tempDir = await getTemporaryDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final String ext = Platform.isLinux ? 'wav' : 'm4a';
      final recordingPath = '${tempDir.path}/recording_$timestamp.$ext';

      // Start recording with platform-appropriate encoder
      final recordConfig = RecordConfig(
        encoder: Platform.isLinux ? AudioEncoder.wav : AudioEncoder.aacLc,
        bitRate: 128000,
        sampleRate: Platform.isLinux ? 16000 : 44100,
        numChannels: 1,
      );
      await _audioRecorder.start(
        recordConfig,
        path: recordingPath,
      );

      _isRecording = true;
      _currentRecordingPath = recordingPath;

      _log.info('Started audio recording: $recordingPath');
    });
  }

  /// Stop audio recording and return attachment
  Future<Result<MessageAttachment?>> stopRecording() async {
    return catchingAsync(() async {
      if (!_isRecording) {
        throw AppError(
          message: 'Not currently recording',
          type: ErrorType.validation,
        );
      }

      final recordingPath = await _audioRecorder.stop();
      _isRecording = false;

      if (recordingPath == null || _currentRecordingPath == null) {
        _currentRecordingPath = null;
        return null;
      }

      final file = File(recordingPath);
      if (!await file.exists()) {
        _currentRecordingPath = null;
        throw AppError(
          message: 'Recording file not found',
          type: ErrorType.notFound,
        );
      }

      final attachment = await _processAudioFile(file);
      _currentRecordingPath = null;

      _log.info('Stopped audio recording: ${attachment.fileName}');
      return attachment;
    });
  }

  /// Cancel current recording
  Future<Result<void>> cancelRecording() async {
    return catchingAsync(() async {
      if (!_isRecording) return;

      await _audioRecorder.stop();
      _isRecording = false;

      // Clean up temporary file
      if (_currentRecordingPath != null) {
        final file = File(_currentRecordingPath!);
        if (await file.exists()) {
          await file.delete();
        }
        _currentRecordingPath = null;
      }

      _log.info('Cancelled audio recording');
    });
  }

  /// Pick audio file from device
  Future<Result<MessageAttachment?>> pickAudioFile() async {
    return catchingAsync(() async {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return null;

      final platformFile = result.files.first;
      if (platformFile.path == null) {
        throw AppError(
          message: 'Unable to access selected audio file',
          type: ErrorType.notFound,
        );
      }

      final file = File(platformFile.path!);
      return await _processAudioFile(file);
    });
  }

  /// Process audio file into attachment
  Future<MessageAttachment> _processAudioFile(File audioFile) async {
    final Uint8List bytes = await audioFile.readAsBytes();

    // Validate file size
    if (bytes.length > AttachmentConfig.maxAudioSizeBytes) {
      throw AppError(
        message: 'Audio size exceeds ${AttachmentConfig.maxAudioSizeBytes ~/ (1024 * 1024)}MB limit',
        type: ErrorType.validation,
      );
    }

    // Determine MIME type from file extension
    final String fileName = audioFile.path.split('/').last;
    String mimeType = _getMimeTypeFromFileName(fileName);

    // Convert to base64
    final String base64Data = base64Encode(bytes);

    // Try to get duration (this would require additional audio processing library)
    // For now, we'll set it to null and let the backend handle it
    double? durationSeconds;

    return MessageAttachment.audio(
      fileName: fileName,
      mimeType: mimeType,
      fileSizeBytes: bytes.length,
      localPath: audioFile.path,
      base64Data: base64Data,
      durationSeconds: durationSeconds,
    );
  }

  /// Get MIME type from file extension
  String _getMimeTypeFromFileName(String fileName) {
    final extension = fileName.toLowerCase().split('.').last;
    switch (extension) {
      case 'mp3':
        return 'audio/mpeg';
      case 'wav':
        return 'audio/wav';
      case 'm4a':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
        return 'audio/ogg';
      default:
        return 'audio/mpeg'; // Default fallback
    }
  }

  // ---------------------------------------------------------------------------
  // Validation
  // ---------------------------------------------------------------------------

  /// Validate attachment before sending
  Result<void> validateAttachment(MessageAttachment attachment) {
    switch (attachment.type) {
      case AttachmentType.image:
        return _validateImageAttachment(attachment);
      case AttachmentType.audio:
        return _validateAudioAttachment(attachment);
    }
  }

  Result<void> _validateImageAttachment(MessageAttachment attachment) {
    if (attachment.mimeType != null &&
        !AttachmentConfig.supportedImageTypes.contains(attachment.mimeType)) {
      return Failure(
        AppError(
          message: 'Unsupported image type: ${attachment.mimeType}',
          type: ErrorType.validation,
        ),
      );
    }

    if (attachment.fileSizeBytes != null &&
        attachment.fileSizeBytes! > AttachmentConfig.maxImageSizeBytes) {
      return Failure(
        AppError(
          message: 'Image size exceeds maximum allowed size',
          type: ErrorType.validation,
        ),
      );
    }

    return const Success(null);
  }

  Result<void> _validateAudioAttachment(MessageAttachment attachment) {
    if (attachment.mimeType != null &&
        !AttachmentConfig.supportedAudioTypes.contains(attachment.mimeType)) {
      return Failure(
        AppError(
          message: 'Unsupported audio type: ${attachment.mimeType}',
          type: ErrorType.validation,
        ),
      );
    }

    if (attachment.fileSizeBytes != null &&
        attachment.fileSizeBytes! > AttachmentConfig.maxAudioSizeBytes) {
      return Failure(
        AppError(
          message: 'Audio size exceeds maximum allowed size',
          type: ErrorType.validation,
        ),
      );
    }

    final duration = attachment.metadata?['duration'] as double?;
    if (duration != null && duration > AttachmentConfig.maxAudioDurationSeconds) {
      return Failure(
        AppError(
          message: 'Audio duration exceeds maximum allowed duration',
          type: ErrorType.validation,
        ),
      );
    }

    return const Success(null);
  }

  // ---------------------------------------------------------------------------
  // Utilities
  // ---------------------------------------------------------------------------

  /// Format file size for display
  static String formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Format duration for display
  static String formatDuration(double seconds) {
    final duration = Duration(milliseconds: (seconds * 1000).round());
    final minutes = duration.inMinutes;
    final remainingSeconds = duration.inSeconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  /// Prepare payload for n8n ElevenLabs Speech-to-Text node.
  /// Returns a map with fileName, mimeType, base64, dataUri, sizeBytes, and durationSeconds.
  static Map<String, dynamic> formatAudioForElevenLabsTranscription(MessageAttachment attachment) {
    if (attachment.type != AttachmentType.audio) {
      throw AppError(
        message: 'Attachment is not an audio file',
        type: ErrorType.validation,
      );
    }

    final String mimeType = attachment.mimeType ?? 'audio/wav';
    final String? base64Data = attachment.base64Data;
    if (base64Data == null || base64Data.isEmpty) {
      throw AppError(
        message: 'Audio attachment has no data',
        type: ErrorType.validation,
      );
    }

    final String fileName = attachment.fileName ?? 'audio${_fileExtensionFromMime(mimeType)}';
    final String dataUri = 'data:$mimeType;base64,$base64Data';

    return {
      'fileName': fileName,
      'mimeType': mimeType,
      'base64': base64Data,
      'dataUri': dataUri,
      'sizeBytes': attachment.fileSizeBytes,
      'durationSeconds': (attachment.metadata?['duration'] as num?)?.toDouble(),
    };
  }

  static String _fileExtensionFromMime(String mime) {
    switch (mime.toLowerCase()) {
      case 'audio/mpeg':
        return '.mp3';
      case 'audio/wav':
      case 'audio/x-wav':
        return '.wav';
      case 'audio/mp4':
        return '.m4a';
      case 'audio/aac':
        return '.aac';
      case 'audio/ogg':
        return '.ogg';
      default:
        return '.wav';
    }
  }

  /// Clean up temporary files
  Future<void> cleanupTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final files = tempDir.listSync();

      for (final file in files) {
        if (file is File && file.path.contains('recording_')) {
          final stat = await file.stat();
          final age = DateTime.now().difference(stat.modified);

          // Delete recordings older than 1 hour
          if (age.inHours > 1) {
            await file.delete();
            _log.info('Cleaned up old temp file: ${file.path}');
          }
        }
      }
    } catch (e) {
      _log.warning('Failed to clean up temp files: $e');
    }
  }

  /// Dispose resources
  void dispose() {
    _audioRecorder.dispose();
  }
}
