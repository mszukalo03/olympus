/// Chat message model and roles for conversation state.
/// ---------------------------------------------------------------------------
/// Optimized immutable message model with enhanced utilities and validation.
/// Supports text, image, and audio attachments.
library chat_message;

import 'package:uuid/uuid.dart';

/// Message roles in conversation
enum MessageRole {
  user('user'),
  assistant('assistant'),
  system('system'),
  error('error');

  const MessageRole(this.value);
  final String value;

  static MessageRole fromString(String value) =>
      values.firstWhere((e) => e.value == value, orElse: () => assistant);
}

/// Message attachment types
enum AttachmentType {
  image('image'),
  audio('audio');

  const AttachmentType(this.value);
  final String value;

  static AttachmentType fromString(String value) =>
      values.firstWhere((e) => e.value == value, orElse: () => image);
}

/// Message attachment metadata
class MessageAttachment {
  final String id;
  final AttachmentType type;
  final String? fileName;
  final String? mimeType;
  final int? fileSizeBytes;
  final String? localPath;
  final String? base64Data;
  final Map<String, dynamic>? metadata;

  const MessageAttachment({
    required this.id,
    required this.type,
    this.fileName,
    this.mimeType,
    this.fileSizeBytes,
    this.localPath,
    this.base64Data,
    this.metadata,
  });

  factory MessageAttachment.image({
    String? id,
    required String fileName,
    required String mimeType,
    int? fileSizeBytes,
    String? localPath,
    String? base64Data,
    int? width,
    int? height,
  }) {
    return MessageAttachment(
      id: id ?? const Uuid().v4(),
      type: AttachmentType.image,
      fileName: fileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      localPath: localPath,
      base64Data: base64Data,
      metadata: width != null && height != null
          ? {'width': width, 'height': height}
          : null,
    );
  }

  factory MessageAttachment.audio({
    String? id,
    required String fileName,
    required String mimeType,
    int? fileSizeBytes,
    String? localPath,
    String? base64Data,
    double? durationSeconds,
  }) {
    return MessageAttachment(
      id: id ?? const Uuid().v4(),
      type: AttachmentType.audio,
      fileName: fileName,
      mimeType: mimeType,
      fileSizeBytes: fileSizeBytes,
      localPath: localPath,
      base64Data: base64Data,
      metadata: durationSeconds != null
          ? {'duration': durationSeconds}
          : null,
    );
  }

  /// JSON serialization
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type.value,
    'fileName': fileName,
    'mimeType': mimeType,
    'fileSizeBytes': fileSizeBytes,
    'localPath': localPath,
    'base64Data': base64Data,
    'metadata': metadata,
  };

  /// Safe JSON deserialization
  static MessageAttachment fromJson(Map<String, dynamic> json) {
    return MessageAttachment(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      type: AttachmentType.fromString((json['type'] as String?) ?? 'image'),
      fileName: json['fileName'] as String?,
      mimeType: json['mimeType'] as String?,
      fileSizeBytes: json['fileSizeBytes'] as int?,
      localPath: json['localPath'] as String?,
      base64Data: json['base64Data'] as String?,
      metadata: json['metadata'] as Map<String, dynamic>?,
    );
  }

  MessageAttachment copyWith({
    String? id,
    AttachmentType? type,
    String? fileName,
    String? mimeType,
    int? fileSizeBytes,
    String? localPath,
    String? base64Data,
    Map<String, dynamic>? metadata,
  }) => MessageAttachment(
    id: id ?? this.id,
    type: type ?? this.type,
    fileName: fileName ?? this.fileName,
    mimeType: mimeType ?? this.mimeType,
    fileSizeBytes: fileSizeBytes ?? this.fileSizeBytes,
    localPath: localPath ?? this.localPath,
    base64Data: base64Data ?? this.base64Data,
    metadata: metadata ?? this.metadata,
  );

  @override
  String toString() => 'MessageAttachment(id=${id.substring(0, 8)}, type=${type.value}, fileName=$fileName)';
}

/// Immutable chat message with enhanced utilities
class ChatMessage {
  final String id;
  final MessageRole role;
  final String content;
  final DateTime timestamp;
  final List<MessageAttachment> attachments;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.attachments = const [],
  });

  /// Factory constructor with auto-generated ID
  factory ChatMessage.create({
    required MessageRole role,
    required String content,
    DateTime? timestamp,
    List<MessageAttachment>? attachments,
  }) => ChatMessage(
    id: const Uuid().v4(),
    role: role,
    content: content,
    timestamp: timestamp ?? DateTime.now(),
    attachments: attachments ?? const [],
  );

  /// Quick factories for common message types
  factory ChatMessage.user(String content, {DateTime? timestamp, List<MessageAttachment>? attachments}) =>
      ChatMessage.create(
        role: MessageRole.user,
        content: content,
        timestamp: timestamp,
        attachments: attachments,
      );

  factory ChatMessage.assistant(String content, {DateTime? timestamp, List<MessageAttachment>? attachments}) =>
      ChatMessage.create(
        role: MessageRole.assistant,
        content: content,
        timestamp: timestamp,
        attachments: attachments,
      );

  factory ChatMessage.system(String content, [DateTime? timestamp]) =>
      ChatMessage.create(
        role: MessageRole.system,
        content: content,
        timestamp: timestamp,
      );

  factory ChatMessage.error(String content, [DateTime? timestamp]) =>
      ChatMessage.create(
        role: MessageRole.error,
        content: content,
        timestamp: timestamp,
      );

  /// Getters for common checks
  bool get isUser => role == MessageRole.user;
  bool get isAssistant => role == MessageRole.assistant;
  bool get isSystem => role == MessageRole.system;
  bool get isError => role == MessageRole.error;
  bool get isEmpty => content.trim().isEmpty && attachments.isEmpty;
  int get length => content.length;
  bool get hasAttachments => attachments.isNotEmpty;
  bool get hasImages => attachments.any((a) => a.type == AttachmentType.image);
  bool get hasAudio => attachments.any((a) => a.type == AttachmentType.audio);

  /// JSON serialization
  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role.value,
    'content': content,
    'timestamp': timestamp.toIso8601String(),
    'attachments': attachments.map((a) => a.toJson()).toList(),
  };

  /// Safe JSON deserialization with fallbacks
  static ChatMessage fromJson(Map<String, dynamic> json) {
    final attachmentsList = (json['attachments'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final attachments = attachmentsList.map((a) => MessageAttachment.fromJson(a)).toList();

    return ChatMessage(
      id: (json['id'] as String?) ?? const Uuid().v4(),
      role: MessageRole.fromString((json['role'] as String?) ?? 'assistant'),
      content: (json['content'] as String?) ?? '',
      timestamp: _parseTimestamp(json['timestamp']),
      attachments: attachments,
    );
  }

  static DateTime _parseTimestamp(dynamic value) {
    if (value is String) {
      try {
        return DateTime.parse(value);
      } catch (_) {}
    }
    return DateTime.now();
  }

  /// Copy with modifications
  ChatMessage copyWith({
    String? id,
    MessageRole? role,
    String? content,
    DateTime? timestamp,
    List<MessageAttachment>? attachments,
  }) => ChatMessage(
    id: id ?? this.id,
    role: role ?? this.role,
    content: content ?? this.content,
    timestamp: timestamp ?? this.timestamp,
    attachments: attachments ?? this.attachments,
  );

  /// Equality and hashing
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatMessage &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          role == other.role &&
          content == other.content &&
          timestamp == other.timestamp &&
          _attachmentsEqual(attachments, other.attachments);

  @override
  int get hashCode => Object.hash(id, role, content, timestamp, attachments.length);

  static bool _attachmentsEqual(List<MessageAttachment> a, List<MessageAttachment> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'ChatMessage(id=${id.substring(0, 8)}, role=${role.value}, length=$length, attachments=${attachments.length})';

  /// Convert to context format for API calls
  Map<String, dynamic> toContext() {
    final context = <String, dynamic>{
      'role': role == MessageRole.user ? 'user' : 'assistant',
      'content': content,
    };

    if (hasAttachments) {
      context['attachments'] = attachments.map((a) => a.toJson()).toList();
    }

    return context;
  }
}

/// Extension methods for message lists
extension ChatMessageListX on List<ChatMessage> {
  /// Filter by role
  List<ChatMessage> byRole(MessageRole role) =>
      where((m) => m.role == role).toList();

  /// Get conversation messages (user + assistant only)
  List<ChatMessage> get conversationOnly =>
      where((m) => m.isUser || m.isAssistant).toList();

  /// Convert to API context format
  List<Map<String, dynamic>> toContext({int? limit}) {
    final messages = conversationOnly;
    final limited = limit != null && messages.length > limit
        ? messages.skip(messages.length - limit).toList()
        : messages;
    return limited.map((m) => m.toContext()).toList();
  }

  /// Get last message of specific role
  ChatMessage? lastByRole(MessageRole role) =>
      byRole(role).isNotEmpty ? byRole(role).last : null;

  /// Check if conversation has any real content
  bool get hasContent => conversationOnly.isNotEmpty;

  /// Total character count
  int get totalLength => fold(0, (sum, message) => sum + message.length);
}
