/// SearXNG Service
/// ---------------------------------------------------------------------------
/// Service for interacting with SearXNG search API to perform web searches.
/// Supports various search categories and result formatting for chat display.
library searxng_service;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../core/core.dart';
import 'custom_endpoint_service.dart';

/// SearXNG search result item
class SearxngSearchResult {
  final String title;
  final String url;
  final String? content;
  final String? engine;
  final String? category;
  final double? score;

  const SearxngSearchResult({
    required this.title,
    required this.url,
    this.content,
    this.engine,
    this.category,
    this.score,
  });

  factory SearxngSearchResult.fromJson(Map<String, dynamic> json) {
    return SearxngSearchResult(
      title: json['title'] as String? ?? 'Untitled',
      url: json['url'] as String? ?? '',
      content: json['content'] as String?,
      engine: json['engine'] as String?,
      category: json['category'] as String?,
      score: (json['score'] as num?)?.toDouble(),
    );
  }

  String toDisplayString() {
    final buffer = StringBuffer();
    buffer.writeln('**$title**');
    buffer.writeln('*$url*');

    if (content != null && content!.isNotEmpty) {
      final truncated = content!.length > 150
          ? '${content!.substring(0, 150)}...'
          : content!;
      buffer.writeln('\n$truncated');
    }

    if (engine != null) {
      buffer.writeln('\n*Source: $engine*');
    }

    return buffer.toString();
  }
}

/// Service for SearXNG API interactions
class SearxngService implements CustomEndpointHandler {
  static final SearxngService _instance = SearxngService._();
  factory SearxngService() => _instance;
  static SearxngService get instance => _instance;
  SearxngService._();

  static final Logger _log = Logger('SearxngService');
  final http.Client _client = http.Client();

  @override
  String get endpointType => 'searxng';

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

    return _handleSearchQuery(query, config, shortcut);
  }

  /// Handle empty query - show usage help
  Future<Result<CustomEndpointResult>> _handleEmptyQuery(
    String shortcut,
  ) async {
    final content =
        '''
**SearXNG Search**

Usage: `/$shortcut <search query>`

Examples:
• `/$shortcut flutter development`
• `/$shortcut weather forecast`
• `/$shortcut linux tutorials`

You can search the web for any topic. Results will include titles, URLs, and brief descriptions.

**Advanced Options:**
• Add `category:news` to search only news
• Add `category:images` to search for images
• Add `category:videos` to search for videos

**Configuration:** Make sure your SearXNG instance supports JSON API access.

**Common Issues:**
• Instance blocks API access - check SearXNG settings
• JSON format not enabled - ensure your instance supports format=json
• Rate limiting - reduce search frequency
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
    Map<String, String> config,
    String shortcut,
  ) async {
    return catchingAsync(() async {
      final baseUrl = config['url']!.trim().replaceAll(RegExp(r'/*$'), '');

      // Parse query for category specifications
      final (cleanQuery, category) = _parseQuery(query);

      // Build search URL with proper parameters
      final queryParams = <String, String>{
        'q': cleanQuery.trim(),
        'format': 'json',
        'safesearch': '1',
      };

      // Only add category if specified
      if (category != null) {
        queryParams['categories'] = category;
      }

      final uri = Uri.parse(
        '$baseUrl/search',
      ).replace(queryParameters: queryParams);

      // Try different approaches to headers to avoid blocking
      final headers = <String, String>{
        'Accept': 'application/json',
        'Accept-Language': 'en-US,en;q=0.9',
        'User-Agent': 'curl/7.68.0', // Simple curl user agent
      };

      _log.info(
        'Searching SearXNG: $cleanQuery (category: ${category ?? "general"})',
      );

      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 20));

      if (response.statusCode == 404) {
        throw AppError(
          message: 'SearXNG endpoint not found - check your URL configuration',
          statusCode: response.statusCode,
          type: ErrorType.notFound,
        );
      }

      if (response.statusCode == 403) {
        throw AppError(
          message:
              'SearXNG access forbidden - your instance may not allow API access. Check instance configuration or try enabling JSON format support.',
          statusCode: response.statusCode,
          type: ErrorType.forbidden,
        );
      }

      if (response.statusCode == 429) {
        throw AppError(
          message: 'Too many requests to SearXNG - please wait and try again',
          statusCode: response.statusCode,
          type: ErrorType.rateLimited,
        );
      }

      if (response.statusCode != 200) {
        throw AppError(
          message:
              'SearXNG search failed (${response.statusCode}) - check if the instance is running and allows API access',
          statusCode: response.statusCode,
          type: ErrorType.network,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final results =
          (decoded['results'] as List?)
              ?.cast<Map<String, dynamic>>()
              .map(SearxngSearchResult.fromJson)
              .toList() ??
          [];

      final content = _formatSearchResults(cleanQuery, results, category);
      final metadata = {
        'query': cleanQuery,
        'category': category ?? 'general',
        'number_of_results': results.length,
        'search_url': uri.toString(),
      };

      return CustomEndpointResult(
        content: content,
        endpointType: endpointType,
        shortcut: shortcut,
        metadata: metadata,
      );
    });
  }

  /// Parse query to extract category specifications
  (String query, String? category) _parseQuery(String rawQuery) {
    final query = rawQuery.trim();

    // Look for category: pattern
    final categoryPattern = RegExp(r'category:(\w+)', caseSensitive: false);
    final match = categoryPattern.firstMatch(query);

    if (match != null) {
      final category = match.group(1)?.toLowerCase();
      final cleanQuery = query.replaceAll(categoryPattern, '').trim();
      return (cleanQuery, category);
    }

    return (query, null);
  }

  /// Format search results for display
  String _formatSearchResults(
    String query,
    List<SearxngSearchResult> results,
    String? category,
  ) {
    if (results.isEmpty) {
      return '''
**SearXNG Search Results**

No results found for "$query"${category != null ? ' in category $category' : ''}.

Try:
• Different keywords
• Removing category restrictions
• Checking your spelling
• Using more general terms
• Verifying your SearXNG instance is running and accessible
''';
    }

    final buffer = StringBuffer();
    final categoryText = category != null ? ' ($category)' : '';
    buffer.writeln('**SearXNG Search Results for "$query"$categoryText**\n');

    // Limit to top 5 results for chat display
    final displayResults = results.take(5).toList();

    for (int i = 0; i < displayResults.length; i++) {
      final result = displayResults[i];
      buffer.writeln('${i + 1}. ${result.toDisplayString()}');
      if (i < displayResults.length - 1) {
        buffer.writeln('---');
      }
    }

    if (results.length > 5) {
      buffer.writeln('\n*Showing top 5 of ${results.length} results*');
    }

    return buffer.toString();
  }

  /// Test connection to SearXNG
  Future<Result<bool>> testConnection(String baseUrl) async {
    return catchingAsync(() async {
      final url = baseUrl.trim().replaceAll(RegExp(r'/*$'), '');
      final uri = Uri.parse('$url/stats');

      final headers = <String, String>{
        'Accept': 'application/json',
        'User-Agent': 'curl/7.68.0',
      };

      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));

      // SearXNG stats endpoint should be accessible
      return response.statusCode < 500;
    });
  }

  /// Get configuration help for SearXNG instances
  String getConfigurationHelp() {
    return '''
**SearXNG Configuration Help**

To enable JSON API access in your SearXNG instance:

1. Edit your SearXNG settings.yml file:
```yaml
search:
  formats:
    - html
    - json  # Enable JSON API
```

2. Restart your SearXNG instance

3. Test the API manually:
   curl "http://your-instance/search?q=test&format=json"

4. If you get 403 errors, check your instance's limiter settings
''';
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}
