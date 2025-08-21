import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'constants/app_constants.dart';

/// AppConfig
/// ----------------------------------------------------------------------------
/// Centralized runtime configuration loader.
///
/// Goals:
/// • Provide a single source of truth for environment + endpoint values
/// • Allow a lightweight JSON override file in the app documents directory
///   (config_runtime.json) without requiring a rebuild
/// • Offer safe fallbacks when the file is absent or malformed
///
/// JSON Structure Example (config_runtime.json):
/// {
///   "default_api": "http://localhost:11434",
///   "automation_api": "http://localhost:5678",
///   "history_api": "http://localhost:5000",
///   "rag_api": "http://localhost:8890",
///   "ws_endpoint": "ws://localhost:9000/ws",
///   "env": "dev",
///   "custom_endpoints": {
///     "j": {
///       "name": "Jellyseerr",
///       "url": "http://localhost:5055/api/v1",
///       "type": "jellyseerr"
///     },
///     "search": {
///       "name": "SearXNG",
///       "url": "http://localhost:8080",
///       "type": "searxng"
///     }
///   }
/// }
///
/// Access via: `AppConfig.instance.defaultApiEndpoint` etc.
///
/// NOTE: This is intentionally minimal—augment with validation, versioning,
/// encryption, or remote refresh logic as the application evolves.
class AppConfig {
  AppConfig._internal();
  static final AppConfig instance = AppConfig._internal();

  /// Raw decoded JSON map (after load). Mutate only during `load()`.
  late Map<String, dynamic> raw;

  /// Logical environment string (e.g., dev / staging / prod).
  String environment = 'dev';

  /// Fallback defaults (kept private to avoid external mutation).
  static const Map<String, String> _defaultValues = {
    'default_api': NetworkConfig.defaultApiEndpoint,
    'automation_api': NetworkConfig.defaultAutomationEndpoint,
    'history_api': NetworkConfig.defaultHistoryEndpoint,
    'rag_api': 'http://localhost:8890',
    'ws_endpoint': '',
    'env': NetworkConfig.defaultEnvironment,
  };

  /// Default custom endpoints
  static const Map<String, Map<String, String>> _defaultCustomEndpoints = {
    'j': {
      'name': 'Jellyseerr',
      'url': NetworkConfig.defaultJellyseerrEndpoint,
      'type': 'jellyseerr',
      'api_key': '',
    },
    'search': {
      'name': 'SearXNG',
      'url': NetworkConfig.defaultSearxngEndpoint,
      'type': 'searxng',
      'api_key': '',
    },
    'ddg': {
      'name': 'DuckDuckGo',
      'url': 'https://api.duckduckgo.com',
      'type': 'duckduckgo',
      'api_key': '',
    },
  };

  /// Convenience getters with graceful fallback.
  String get defaultApiEndpoint =>
      (raw['default_api'] as String?) ?? _defaultValues['default_api']!;
  String get automationEndpoint =>
      (raw['automation_api'] as String?) ?? _defaultValues['automation_api']!;
  String get historyEndpoint =>
      (raw['history_api'] as String?) ?? _defaultValues['history_api']!;
  String get ragApiEndpoint =>
      (raw['rag_api'] as String?) ?? _defaultValues['rag_api']!;
  String get websocketEndpoint =>
      (raw['ws_endpoint'] as String?) ?? _defaultValues['ws_endpoint']!;
  bool get hasWebsocket => websocketEndpoint.trim().isNotEmpty;

  /// Get custom endpoints configuration
  Map<String, Map<String, String>> get customEndpoints {
    final customData = raw['custom_endpoints'];
    if (customData is Map<String, dynamic>) {
      final result = <String, Map<String, String>>{};
      customData.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          final endpoint = <String, String>{};
          value.forEach((k, v) {
            if (v is String) endpoint[k] = v;
          });
          if (endpoint.isNotEmpty) result[key] = endpoint;
        }
      });
      return result;
    }
    return Map<String, Map<String, String>>.from(_defaultCustomEndpoints);
  }

  /// Get a specific custom endpoint by shortcut
  Map<String, String>? getCustomEndpoint(String shortcut) {
    return customEndpoints[shortcut];
  }

  /// Check if a shortcut exists
  bool hasCustomEndpoint(String shortcut) {
    return customEndpoints.containsKey(shortcut);
  }

  /// Load config from the writable app documents directory.
  ///
  /// If the file is missing or cannot be parsed, `_defaultValues` are used.
  /// This method is idempotent; it can be safely re-run to refresh values.
  Future<void> load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/${StorageKeys.runtimeConfig}');

      if (await file.exists()) {
        final text = await file.readAsString();
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          raw = {..._defaultValues, ...decoded};
        } else {
          // Malformed root type—fallback
          raw = {..._defaultValues};
        }
      } else {
        raw = {..._defaultValues};
      }

      // Ensure custom_endpoints exists
      if (raw['custom_endpoints'] == null) {
        raw['custom_endpoints'] = Map<String, dynamic>.from(
          _defaultCustomEndpoints,
        );
      }

      environment = (raw['env'] as String?)?.trim().isNotEmpty == true
          ? raw['env'] as String
          : _defaultValues['env']!;
    } catch (_) {
      // Swallow errors—config should never crash startup.
      raw = {..._defaultValues};
      environment = _defaultValues['env']!;
    }
  }

  /// Provide a mutable copy of the current effective map (never the internal
  /// reference) for diagnostics or serialization.
  Map<String, dynamic> snapshot() => Map<String, dynamic>.from(raw);

  /// Persist a new runtime configuration map (merging with current defaults),
  /// then reload it into memory.
  ///
  /// Supported keys (all optional; missing ones retain prior or default values):
  ///   • default_api      -> Primary model / inference endpoint
  ///   • automation_api   -> Automation / webhook pipeline endpoint
  ///   • history_api      -> History (Flask/Postgres) backend base URL
  ///   • rag_api          -> RAG management / embeddings backend base URL
  ///   • ws_endpoint      -> WebSocket endpoint (if any)
  ///   • env              -> Logical environment label
  ///   • custom_endpoints -> Map of custom endpoint configurations
  ///
  /// This helper is used by the Settings UI to update endpoints at runtime.
  Future<void> saveAndReload(Map<String, dynamic> updates) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/${StorageKeys.runtimeConfig}');
    final merged = {..._defaultValues, ...raw, ...updates};
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(merged),
    );
    await load();
  }
}
