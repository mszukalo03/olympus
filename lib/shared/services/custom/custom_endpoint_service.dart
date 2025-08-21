/// Custom Endpoint Service
/// ---------------------------------------------------------------------------
/// Interface and routing logic for handling custom endpoint shortcuts.
/// Supports different endpoint types (jellyseerr, searxng, etc.) with
/// unified request/response handling.
library custom_endpoint_service;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../core/core.dart';
import 'jellyseerr_service.dart';
import 'searxng_service.dart';
import 'duckduckgo_service.dart';

/// Result of a custom endpoint request
class CustomEndpointResult {
  final String content;
  final Map<String, dynamic>? metadata;
  final String endpointType;
  final String shortcut;

  const CustomEndpointResult({
    required this.content,
    required this.endpointType,
    required this.shortcut,
    this.metadata,
  });

  /// Convert to a formatted chat message content
  String toFormattedContent() {
    final buffer = StringBuffer();
    buffer.writeln('**${_getEndpointDisplayName()} Results**\n');
    buffer.writeln(content);

    if (metadata != null && metadata!.isNotEmpty) {
      buffer.writeln('\n---');
      buffer.writeln('*Metadata: ${metadata.toString()}*');
    }

    return buffer.toString();
  }

  String _getEndpointDisplayName() {
    switch (endpointType) {
      case 'jellyseerr':
        return 'Jellyseerr';
      case 'searxng':
        return 'SearXNG';
      default:
        return shortcut.toUpperCase();
    }
  }
}

/// Interface for custom endpoint handlers
abstract interface class CustomEndpointHandler {
  String get endpointType;
  Future<Result<CustomEndpointResult>> handleRequest(
    String query,
    Map<String, String> config,
    String shortcut,
  );
}

/// Service for managing and routing custom endpoint requests
class CustomEndpointService {
  static final CustomEndpointService _instance = CustomEndpointService._();
  factory CustomEndpointService() => _instance;
  static CustomEndpointService get instance => _instance;
  CustomEndpointService._();

  static final Logger _log = Logger('CustomEndpointService');
  final http.Client _client = http.Client();

  // Registry of endpoint handlers
  final Map<String, CustomEndpointHandler> _handlers = {
    'jellyseerr': JellyseerrService.instance,
    'searxng': SearxngService.instance,
    'duckduckgo': DuckDuckGoService.instance,
  };

  /// Register a new endpoint handler
  void registerHandler(String type, CustomEndpointHandler handler) {
    _handlers[type] = handler;
    _log.info('Registered custom endpoint handler: $type');
  }

  /// Check if a message starts with a custom endpoint shortcut
  bool hasCustomShortcut(String message) {
    final trimmed = message.trim();
    if (!trimmed.startsWith('/')) return false;

    final parts = trimmed.substring(1).split(' ');
    if (parts.isEmpty) return false;

    final shortcut = parts.first;
    return AppConfig.instance.hasCustomEndpoint(shortcut);
  }

  /// Extract shortcut and query from a message
  (String shortcut, String query) parseMessage(String message) {
    final trimmed = message.trim();
    if (!trimmed.startsWith('/')) {
      throw ArgumentError('Message does not start with /');
    }

    final withoutSlash = trimmed.substring(1);
    final spaceIndex = withoutSlash.indexOf(' ');

    if (spaceIndex == -1) {
      return (withoutSlash, '');
    }

    final shortcut = withoutSlash.substring(0, spaceIndex);
    final query = withoutSlash.substring(spaceIndex + 1).trim();

    return (shortcut, query);
  }

  /// Route a request to the appropriate custom endpoint
  Future<Result<CustomEndpointResult>> routeRequest(String message) async {
    if (!hasCustomShortcut(message)) {
      return const Failure(
        AppError(
          message: 'No custom endpoint found for this shortcut',
          type: ErrorType.notFound,
        ),
      );
    }

    try {
      final (shortcut, query) = parseMessage(message);
      final config = AppConfig.instance.getCustomEndpoint(shortcut);

      if (config == null) {
        return Failure(
          AppError(
            message: 'Configuration not found for shortcut: $shortcut',
            type: ErrorType.notFound,
          ),
        );
      }

      final endpointType = config['type'] ?? 'unknown';
      final handler = _handlers[endpointType];

      if (handler == null) {
        return Failure(
          AppError(
            message: 'No handler registered for endpoint type: $endpointType',
            type: ErrorType.notFound,
          ),
        );
      }

      _log.info('Routing request to $endpointType: $shortcut -> "$query"');

      final result = await handler.handleRequest(query, config, shortcut);

      return result.when(
        success: (customResult) {
          _log.info(
            'Custom endpoint request completed: ${customResult.content.length} chars',
          );
          return Success(customResult);
        },
        failure: (error) {
          _log.warning('Custom endpoint request failed: ${error.message}');
          return Failure(error);
        },
      );
    } catch (e, st) {
      _log.severe('Error routing custom endpoint request', e, st);
      return Failure(
        AppError(
          message: 'Failed to process custom endpoint request: $e',
          type: ErrorType.unknown,
        ),
      );
    }
  }

  /// Get all available shortcuts with their configurations
  Map<String, Map<String, String>> getAvailableShortcuts() {
    return AppConfig.instance.customEndpoints;
  }

  /// Validate a custom endpoint configuration
  Result<void> validateEndpointConfig(Map<String, String> config) {
    if (!config.containsKey('name') || config['name']!.trim().isEmpty) {
      return const Failure(
        AppError(
          message: 'Endpoint name is required',
          type: ErrorType.validation,
        ),
      );
    }

    if (!config.containsKey('url') || config['url']!.trim().isEmpty) {
      return const Failure(
        AppError(
          message: 'Endpoint URL is required',
          type: ErrorType.validation,
        ),
      );
    }

    final url = config['url']!.trim();
    try {
      final uri = Uri.parse(url);
      if (!uri.hasScheme || !['http', 'https'].contains(uri.scheme)) {
        return const Failure(
          AppError(
            message: 'URL must have http or https scheme',
            type: ErrorType.validation,
          ),
        );
      }
    } catch (e) {
      return Failure(
        AppError(message: 'Invalid URL format: $e', type: ErrorType.validation),
      );
    }

    final type = config['type'] ?? '';
    if (type.isNotEmpty && !_handlers.containsKey(type)) {
      return Failure(
        AppError(
          message: 'Unsupported endpoint type: $type',
          type: ErrorType.validation,
        ),
      );
    }

    // API key is optional but if provided should not be empty
    final apiKey = config['api_key'];
    if (apiKey != null && apiKey.trim().isEmpty) {
      // Allow empty API key but remove it from config to keep things clean
      config.remove('api_key');
    }

    return const Success(null);
  }

  /// Test connectivity to a custom endpoint
  Future<Result<bool>> testEndpoint(Map<String, String> config) async {
    final validation = validateEndpointConfig(config);
    if (validation.isFailure) {
      return Failure(validation.error!);
    }

    return catchingAsync(() async {
      final url = config['url']!.trim();
      final uri = Uri.parse(url);

      try {
        final response = await _client
            .get(uri)
            .timeout(const Duration(seconds: 10));

        // Consider any response (even error responses) as "reachable"
        return response.statusCode < 500;
      } catch (e) {
        _log.warning('Endpoint test failed for $url: $e');
        return false;
      }
    });
  }

  /// Get help text for available shortcuts
  String getHelpText() {
    final shortcuts = getAvailableShortcuts();
    if (shortcuts.isEmpty) {
      return 'No custom endpoints configured.';
    }

    final buffer = StringBuffer();
    buffer.writeln('**Available Custom Endpoints:**\n');

    shortcuts.forEach((shortcut, config) {
      final name = config['name'] ?? shortcut;
      final type = config['type'] ?? 'unknown';
      buffer.writeln('• `/$shortcut` - $name ($type)');
    });

    buffer.writeln('\n*Usage: /[shortcut] your query here*');

    return buffer.toString();
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}
