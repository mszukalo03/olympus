/// DuckDuckGo Instant Answer Service
/// ---------------------------------------------------------------------------
/// Service for searching using DuckDuckGo's Instant Answer API as an alternative
/// to SearXNG. This API is public, doesn't require authentication, and is
/// more reliable for programmatic access.
library duckduckgo_service;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../core/core.dart';
import 'custom_endpoint_service.dart';

/// DuckDuckGo search result item
class DuckDuckGoResult {
  final String title;
  final String url;
  final String? snippet;
  final String? source;

  const DuckDuckGoResult({
    required this.title,
    required this.url,
    this.snippet,
    this.source,
  });

  factory DuckDuckGoResult.fromJson(Map<String, dynamic> json) {
    return DuckDuckGoResult(
      title: json['Text'] as String? ?? 'No title',
      url: json['FirstURL'] as String? ?? '',
      snippet: json['Result'] as String?,
      source: json['Source'] as String?,
    );
  }

  String toDisplayString() {
    final buffer = StringBuffer();
    buffer.writeln('**$title**');
    if (url.isNotEmpty) {
      buffer.writeln('*$url*');
    }

    if (snippet != null && snippet!.isNotEmpty) {
      final cleanSnippet = snippet!.replaceAll(
        RegExp(r'<[^>]*>'),
        '',
      ); // Remove HTML tags
      final truncated = cleanSnippet.length > 150
          ? '${cleanSnippet.substring(0, 150)}...'
          : cleanSnippet;
      buffer.writeln('\n$truncated');
    }

    if (source != null && source!.isNotEmpty) {
      buffer.writeln('\n*Source: $source*');
    }

    return buffer.toString();
  }
}

/// Service for DuckDuckGo Instant Answer API
class DuckDuckGoService implements CustomEndpointHandler {
  static final DuckDuckGoService _instance = DuckDuckGoService._();
  factory DuckDuckGoService() => _instance;
  static DuckDuckGoService get instance => _instance;
  DuckDuckGoService._();

  static final Logger _log = Logger('DuckDuckGoService');
  final http.Client _client = http.Client();

  @override
  String get endpointType => 'duckduckgo';

  @override
  Future<Result<CustomEndpointResult>> handleRequest(
    String query,
    Map<String, String> config,
    String shortcut,
  ) async {
    if (query.trim().isEmpty) {
      return _handleEmptyQuery(shortcut);
    }

    // Check if query is asking for help
    if (query.toLowerCase().trim() == 'help') {
      return _handleHelpQuery(shortcut);
    }

    return _handleSearchQuery(query, shortcut);
  }

  /// Handle empty query - show usage help
  Future<Result<CustomEndpointResult>> _handleEmptyQuery(
    String shortcut,
  ) async {
    final content =
        '''
**DuckDuckGo Search**

Usage: `/$shortcut <search query>`

Examples:
• `/$shortcut weather in New York`
• `/$shortcut Einstein birthday`
• `/$shortcut flutter documentation`

This uses DuckDuckGo's Instant Answer API for quick, reliable search results.

**Features:**
• No API key required
• Fast instant answers
• Safe search enabled
• No tracking or rate limits
''';

    return Success(
      CustomEndpointResult(
        content: content,
        endpointType: endpointType,
        shortcut: shortcut,
      ),
    );
  }

  /// Handle help query
  Future<Result<CustomEndpointResult>> _handleHelpQuery(String shortcut) async {
    return _handleEmptyQuery(shortcut);
  }

  /// Handle search query
  Future<Result<CustomEndpointResult>> _handleSearchQuery(
    String query,
    String shortcut,
  ) async {
    return catchingAsync(() async {
      final cleanQuery = query.trim();

      // DuckDuckGo Instant Answer API endpoint
      const baseUrl = 'https://api.duckduckgo.com';

      final uri = Uri.parse(baseUrl).replace(
        queryParameters: {
          'q': cleanQuery,
          'format': 'json',
          'no_html': '1',
          'skip_disambig': '1',
          'safe_search': 'moderate',
        },
      );

      final headers = <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'AI-Orchestrator/1.0',
        'Accept-Language': 'en-US,en;q=0.9',
      };

      _log.info('Searching DuckDuckGo: $cleanQuery');

      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        throw AppError(
          message: 'DuckDuckGo search failed (${response.statusCode})',
          statusCode: response.statusCode,
          type: ErrorType.network,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;

      final content = _formatSearchResults(cleanQuery, decoded);
      final metadata = {
        'query': cleanQuery,
        'api_used': 'DuckDuckGo Instant Answer',
        'safe_search': 'moderate',
      };

      return CustomEndpointResult(
        content: content,
        endpointType: endpointType,
        shortcut: shortcut,
        metadata: metadata,
      );
    });
  }

  /// Format DuckDuckGo API response for display
  String _formatSearchResults(String query, Map<String, dynamic> data) {
    final buffer = StringBuffer();
    buffer.writeln('**DuckDuckGo Search Results for "$query"**\n');

    // Check for instant answer
    final abstractText = data['AbstractText'] as String?;
    final abstractUrl = data['AbstractURL'] as String?;
    final abstractSource = data['AbstractSource'] as String?;

    if (abstractText != null && abstractText.isNotEmpty) {
      buffer.writeln('**Quick Answer:**');
      buffer.writeln(abstractText);

      if (abstractUrl != null && abstractUrl.isNotEmpty) {
        buffer.writeln('*Source: $abstractUrl*');
      }

      if (abstractSource != null && abstractSource.isNotEmpty) {
        buffer.writeln('*From: $abstractSource*');
      }

      buffer.writeln('');
    }

    // Check for definition
    final definition = data['Definition'] as String?;
    final definitionUrl = data['DefinitionURL'] as String?;
    final definitionSource = data['DefinitionSource'] as String?;

    if (definition != null && definition.isNotEmpty) {
      buffer.writeln('**Definition:**');
      buffer.writeln(definition);

      if (definitionUrl != null && definitionUrl.isNotEmpty) {
        buffer.writeln('*More info: $definitionUrl*');
      }

      if (definitionSource != null && definitionSource.isNotEmpty) {
        buffer.writeln('*From: $definitionSource*');
      }

      buffer.writeln('');
    }

    // Check for related topics
    final relatedTopics = data['RelatedTopics'] as List?;
    if (relatedTopics != null && relatedTopics.isNotEmpty) {
      buffer.writeln('**Related Topics:**');

      final topicsToShow = relatedTopics.take(3);
      for (final topic in topicsToShow) {
        if (topic is Map<String, dynamic>) {
          final text = topic['Text'] as String?;
          final firstUrl = topic['FirstURL'] as String?;

          if (text != null && text.isNotEmpty) {
            buffer.writeln('• $text');
            if (firstUrl != null && firstUrl.isNotEmpty) {
              buffer.writeln('  *$firstUrl*');
            }
          }
        }
      }
      buffer.writeln('');
    }

    // Check for answer (like calculations, conversions)
    final answer = data['Answer'] as String?;
    final answerType = data['AnswerType'] as String?;

    if (answer != null && answer.isNotEmpty) {
      buffer.writeln('**Answer:**');
      buffer.writeln(answer);
      if (answerType != null && answerType.isNotEmpty) {
        buffer.writeln('*Type: $answerType*');
      }
      buffer.writeln('');
    }

    // If no specific results, show search suggestion
    if (buffer.length <= 50) {
      // Only the header was added
      buffer.writeln('No instant answers found for "$query".');
      buffer.writeln('\nTry:');
      buffer.writeln('• More specific search terms');
      buffer.writeln('• Different phrasing');
      buffer.writeln('• Checking spelling');
      buffer.writeln(
        '\nDuckDuckGo works best with factual queries, definitions, and calculations.',
      );
    }

    return buffer.toString();
  }

  /// Test connection to DuckDuckGo API
  Future<Result<bool>> testConnection() async {
    return catchingAsync(() async {
      const testUrl =
          'https://api.duckduckgo.com/?q=test&format=json&no_html=1';
      final uri = Uri.parse(testUrl);

      final headers = <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'AI-Orchestrator/1.0',
      };

      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));

      return response.statusCode == 200;
    });
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}
