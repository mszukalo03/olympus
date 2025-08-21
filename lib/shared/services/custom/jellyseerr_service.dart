/// Jellyseerr Service
/// ---------------------------------------------------------------------------
/// Service for interacting with Jellyseerr API to search for movies and TV shows.
/// Supports media search, request status, and basic media information retrieval.
library jellyseerr_service;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../../../core/core.dart';
import 'custom_endpoint_service.dart';

/// Jellyseerr media item
class JellyseerrMediaItem {
  final int id;
  final String title;
  final String? overview;
  final String? posterPath;
  final String? releaseDate;
  final String mediaType; // 'movie' or 'tv'
  final double? voteAverage;
  final bool available;
  final String? status;

  const JellyseerrMediaItem({
    required this.id,
    required this.title,
    required this.mediaType,
    this.overview,
    this.posterPath,
    this.releaseDate,
    this.voteAverage,
    this.available = false,
    this.status,
  });

  factory JellyseerrMediaItem.fromJson(Map<String, dynamic> json) {
    return JellyseerrMediaItem(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? json['name'] as String? ?? 'Unknown',
      overview: json['overview'] as String?,
      posterPath: json['posterPath'] as String?,
      releaseDate:
          json['releaseDate'] as String? ?? json['firstAirDate'] as String?,
      mediaType: json['mediaType'] as String? ?? 'unknown',
      voteAverage: (json['voteAverage'] as num?)?.toDouble(),
      available:
          (json['mediaInfo']?['status'] == 4) ||
          (json['available'] as bool? ?? false),
      status: json['mediaInfo']?['status']?.toString(),
    );
  }

  String toDisplayString() {
    final buffer = StringBuffer();
    buffer.writeln('**$title** (${mediaType.toUpperCase()})');

    if (releaseDate != null) {
      buffer.writeln('*Released: $releaseDate*');
    }

    if (voteAverage != null) {
      buffer.writeln('*Rating: ${voteAverage!.toStringAsFixed(1)}/10*');
    }

    buffer.writeln('*Status: ${available ? "Available" : "Not Available"}*');

    if (overview != null && overview!.isNotEmpty) {
      final truncated = overview!.length > 200
          ? '${overview!.substring(0, 200)}...'
          : overview!;
      buffer.writeln('\n$truncated');
    }

    return buffer.toString();
  }
}

/// Service for Jellyseerr API interactions
class JellyseerrService implements CustomEndpointHandler {
  static final JellyseerrService _instance = JellyseerrService._();
  factory JellyseerrService() => _instance;
  static JellyseerrService get instance => _instance;
  JellyseerrService._();

  static final Logger _log = Logger('JellyseerrService');
  final http.Client _client = http.Client();

  @override
  String get endpointType => 'jellyseerr';

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
**Jellyseerr Search**

Usage: `/$shortcut <search query>`

Examples:
• `/$shortcut The Matrix`
• `/$shortcut Breaking Bad`
• `/$shortcut Marvel`

You can search for movies and TV shows. The results will show availability status and basic information.

**Note:** Jellyseerr requires an API key. Configure it in Settings → Custom Endpoints → Edit → API Key field.
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
      final apiKey = config['api_key'];

      // Build search URL with manual encoding to avoid Jellyseerr issues
      final cleanQuery = Uri.encodeQueryComponent(query.trim());
      final searchUrl = '$baseUrl/search?query=$cleanQuery&page=1&language=en';
      final uri = Uri.parse(searchUrl);

      final headers = <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': 'AI-Orchestrator/1.0',
      };

      // Add API key if provided
      if (apiKey != null && apiKey.trim().isNotEmpty) {
        headers['X-Api-Key'] = apiKey.trim();
      }

      _log.info('Searching Jellyseerr: $query (URL: $searchUrl)');

      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 401) {
        final hasApiKey = apiKey != null && apiKey.trim().isNotEmpty;
        throw AppError(
          message: hasApiKey
              ? 'Invalid Jellyseerr API key - check your credentials in Settings'
              : 'Jellyseerr requires an API key - add one in Settings under Custom Endpoints',
          statusCode: response.statusCode,
          type: ErrorType.unauthorized,
        );
      }

      if (response.statusCode == 403) {
        throw AppError(
          message: 'Access forbidden - check your Jellyseerr permissions',
          statusCode: response.statusCode,
          type: ErrorType.forbidden,
        );
      }

      if (response.statusCode == 404) {
        throw AppError(
          message: 'Jellyseerr endpoint not found - check your URL',
          statusCode: response.statusCode,
          type: ErrorType.notFound,
        );
      }

      if (response.statusCode != 200) {
        String errorMessage =
            'Jellyseerr search failed (${response.statusCode})';

        // Try to extract error details from response
        try {
          final errorData = jsonDecode(response.body);
          if (errorData is Map && errorData['message'] != null) {
            errorMessage = 'Jellyseerr error: ${errorData['message']}';
          }
        } catch (_) {
          // Ignore JSON parsing errors, use default message
        }

        throw AppError(
          message: errorMessage,
          statusCode: response.statusCode,
          type: ErrorType.network,
        );
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final results =
          (decoded['results'] as List?)
              ?.cast<Map<String, dynamic>>()
              .map(JellyseerrMediaItem.fromJson)
              .toList() ??
          [];

      final content = _formatSearchResults(query, results);
      final metadata = {
        'total_results': decoded['totalResults'] ?? 0,
        'page': decoded['page'] ?? 1,
        'query': query,
      };

      return CustomEndpointResult(
        content: content,
        endpointType: endpointType,
        shortcut: shortcut,
        metadata: metadata,
      );
    });
  }

  /// Format search results for display
  String _formatSearchResults(String query, List<JellyseerrMediaItem> results) {
    if (results.isEmpty) {
      return '''
**Jellyseerr Search Results**

No results found for "$query".

Try:
• Checking your spelling
• Using different keywords
• Searching for alternate titles
''';
    }

    final buffer = StringBuffer();
    buffer.writeln('**Jellyseerr Search Results for "$query"**\n');

    // Limit to top 5 results for chat display
    final displayResults = results.take(5).toList();

    for (int i = 0; i < displayResults.length; i++) {
      final item = displayResults[i];
      buffer.writeln('${i + 1}. ${item.toDisplayString()}');
      if (i < displayResults.length - 1) {
        buffer.writeln('---');
      }
    }

    if (results.length > 5) {
      buffer.writeln('\n*Showing top 5 of ${results.length} results*');
    }

    return buffer.toString();
  }

  /// Test connection to Jellyseerr
  Future<Result<bool>> testConnection(String baseUrl, {String? apiKey}) async {
    return catchingAsync(() async {
      final url = baseUrl.trim().replaceAll(RegExp(r'/*$'), '');
      final uri = Uri.parse('$url/status');

      final headers = <String, String>{
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': 'AI-Orchestrator/1.0',
      };

      if (apiKey != null && apiKey.trim().isNotEmpty) {
        headers['X-Api-Key'] = apiKey.trim();
      }

      final response = await _client
          .get(uri, headers: headers)
          .timeout(const Duration(seconds: 10));

      // Consider 401 as "reachable but needs auth" which is still a successful connection test
      return response.statusCode < 500 && response.statusCode != 401;
    });
  }

  /// Dispose resources
  void dispose() {
    _client.close();
  }
}
