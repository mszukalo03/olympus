/// Optimized AI Service
/// ---------------------------------------------------------------------------
/// Simplified and efficient external AI service with better error handling,
/// retry logic, and cleaner API design.
library ai_service;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../core/config/app_config.dart';
import '../../core/config/constants/app_constants.dart';
import '../../core/result.dart';
import '../models/chat_message.dart';
import 'custom/custom_endpoint_service.dart';

/// AI Service for external completions
class AIService {
  static final AIService _instance = AIService._();
  factory AIService() => _instance;
  static AIService get instance => _instance;
  AIService._();

  static final Logger _log = Logger(LogConfig.apiLogger);
  final http.Client _client = http.Client();

  /// Send completion request with context and attachments
  Future<Result<String>> sendCompletion(
    String prompt, {
    List<Map<String, dynamic>> context = const [],
    List<MessageAttachment> attachments = const [],
    String? model,
    Map<String, dynamic>? options,
    int? conversationId,
  }) async {
    if (prompt.trim().isEmpty) {
      return const Failure(
        AppError(
          message: ErrorMessages.emptyMessage,
          type: ErrorType.validation,
        ),
      );
    }

    // Check if this is a custom endpoint request
    final customService = CustomEndpointService.instance;
    if (customService.hasCustomShortcut(prompt)) {
      _log.info('Routing to custom endpoint: ${prompt.split(' ').first}');
      final result = await customService.routeRequest(prompt);
      return result.when(
        success: (customResult) => Success(customResult.toFormattedContent()),
        failure: (error) => Failure(error),
      );
    }

    final uri = _buildUri();
    final mergedOptions = {..._defaultOptions, if (options != null) ...options};
    // Extract session id (if supplied by caller inside options) and move to top-level
    final dynamic rawSession = mergedOptions.remove('session_id');
    final String? sessionId =
        rawSession is String && rawSession.trim().isNotEmpty
        ? rawSession
        : null;

    final body = _buildRequestBody(
      prompt: prompt.trim(),
      context: context,
      attachments: attachments,
      model: model ?? 'default',
      options: mergedOptions,
      sessionId: sessionId,
      conversationId: conversationId,
    );

    return _executeRequest(uri, body);
  }

  /// Build request URI
  Uri _buildUri() {
    // Use automation (n8n webhook) endpoint directly. Expected to be full URL.
    final endpoint = AppConfig.instance.automationEndpoint;
    return Uri.parse(endpoint);
  }

  /// Build request body
  Map<String, dynamic> _buildRequestBody({
    required String prompt,
    required List<Map<String, dynamic>> context,
    required List<MessageAttachment> attachments,
    required String model,
    required Map<String, dynamic> options,
    String? sessionId,
    int? conversationId,
  }) {
    final body = <String, dynamic>{
      // Raw user prompt (n8n can decide how to use it)
      'prompt': prompt,
      // Full conversation context (prior messages)
      'context': context,
      // Explicit conversation array including new user message for routing models
      'conversation': [
        ...context,
        {
          'role': 'user',
          'content': prompt,
          if (attachments.isNotEmpty) 'attachments': attachments.map((a) => a.toJson()).toList(),
        },
      ],
      // Metadata helpers (non-breaking for existing workflows that ignore extras)
      'meta': {
        'model': model,
        'client': AppInfo.name,
        'timestamp': DateTime.now().toIso8601String(),
        'has_attachments': attachments.isNotEmpty,
        'attachment_types': attachments.map((a) => a.type.value).toSet().toList(),
      },
      // Top-level session identifier for routing logic
      if (sessionId != null) 'session_id': sessionId,
      // Conversation ID for context retrieval
      if (conversationId != null) 'conversation_id': conversationId,
      // Retain options for downstream model selection
      'options': options,
    };

    // Add attachments at top level for easy access by webhook
    if (attachments.isNotEmpty) {
      body['attachments'] = attachments.map((a) => {
        'id': a.id,
        'type': a.type.value,
        'fileName': a.fileName,
        'mimeType': a.mimeType,
        'fileSizeBytes': a.fileSizeBytes,
        'base64Data': a.base64Data,
        'metadata': a.metadata,
      }).toList();
    }

    return body;
  }

  /// Default completion options
  Map<String, dynamic> get _defaultOptions => {
    'temperature': 0.7,
    'max_tokens': 2048,
    'top_p': 0.9,
  };

  /// Execute HTTP request with retry logic
  Future<Result<String>> _executeRequest(Uri uri, Map<String, dynamic> body) =>
      catchingAsync(() async {
        final stopwatch = Stopwatch()..start();

        try {
          final response = await _makeRequest(uri, body);
          stopwatch.stop();

          _log.info(
            'AI request completed in ${stopwatch.elapsedMilliseconds}ms',
          );

          return _parseResponse(response, uri);
        } catch (e) {
          stopwatch.stop();
          _log.severe(
            'AI request failed after ${stopwatch.elapsedMilliseconds}ms: $e',
          );
          rethrow;
        }
      });

  /// Make HTTP request with timeout and validation
  Future<http.Response> _makeRequest(Uri uri, Map<String, dynamic> body) async {
    if (!['http', 'https'].contains(uri.scheme)) {
      throw AppError(
        message: 'Unsupported URI scheme: ${uri.scheme}',
        type: ErrorType.validation,
      );
    }

    // Removed fixed timeout to support long-running local AI tasks
    // (If you need a safety limit later, wrap this with .timeout or add a configurable Duration)
    final response = await _client.post(
      uri,
      headers: _buildHeaders(),
      body: jsonEncode(body),
    );

    // Validate response size
    if (response.contentLength != null &&
        response.contentLength! > NetworkConfig.maxResponseSize) {
      throw AppError(
        message: 'Response too large: ${response.contentLength} bytes',
        type: ErrorType.network,
      );
    }

    return response;
  }

  /// Build request headers
  Map<String, String> _buildHeaders() => {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
    'User-Agent': NetworkConfig.userAgent,
  };

  /// Parse and validate response
  String _parseResponse(http.Response response, Uri uri) {
    if (response.statusCode == 200) {
      try {
        final decoded = jsonDecode(response.body);
        final content = _extractContent(decoded);

        if (content.trim().isEmpty) {
          return '(No content returned by AI service)';
        }

        return content;
      } catch (e) {
        _log.warning('Failed to parse AI response: $e');
        return '(Invalid response format from AI service)';
      }
    } else {
      throw AppError(
        message:
            'AI service error: ${response.statusCode} ${_truncate(response.body, 200)}',
        type: _mapStatusToErrorType(response.statusCode),
        statusCode: response.statusCode,
      );
    }
  }

  /// Extract content from response JSON
  String _extractContent(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      // Collect candidate string fields in priority order
      final candidates = <dynamic>[
        decoded['result'],
        decoded['response'],
        decoded['content'],
        decoded['text'],
        if (decoded['data'] is Map)
          (decoded['data']['text'] ??
              decoded['data']['response'] ??
              decoded['data']['result']),
        decoded['output'],
        decoded['reply'],
      ];
      for (final c in candidates) {
        if (c is String && c.trim().isNotEmpty) return c;
      }
      // Fallback: search any nested map values for first non-empty string
      for (final value in decoded.values) {
        if (value is String && value.trim().isNotEmpty) return value;
        if (value is Map) {
          for (final v in value.values) {
            if (v is String && v.trim().isNotEmpty) return v;
          }
        }
      }
      return '';
    }
    return '';
  }

  /// Map HTTP status codes to error types
  ErrorType _mapStatusToErrorType(int statusCode) => switch (statusCode) {
    401 => ErrorType.unauthorized,
    403 => ErrorType.forbidden,
    404 => ErrorType.notFound,
    409 => ErrorType.conflict,
    429 => ErrorType.rateLimited,
    >= 500 => ErrorType.network,
    _ => ErrorType.unknown,
  };

  /// Truncate long strings for logging
  String _truncate(String input, int maxLength) =>
      input.length <= maxLength ? input : '${input.substring(0, maxLength)}...';

  /// Health check
  Future<Result<bool>> healthCheck() => catchingAsync(() async {
    final uri = _buildUri();
    try {
      final response = await _client
          .get(uri)
          .timeout(const Duration(seconds: 5));
      return response.statusCode < 500;
    } catch (e) {
      _log.warning('Health check failed: $e');
      return false;
    }
  });

  /// Cleanup resources
  void dispose() {
    _client.close();
  }
}
