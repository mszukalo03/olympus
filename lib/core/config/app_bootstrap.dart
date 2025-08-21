import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import 'app_config.dart';
import 'constants/app_constants.dart';

/// ---------------------------------------------------------------------------
/// Application bootstrap / one‑time initialization logic.
///
/// Responsibilities:
/// • Configure global logging
/// • Perform (future) lightweight migrations
/// • Load runtime configuration (endpoints / environment flags)
/// ---------------------------------------------------------------------------
class AppBootstrap {
  static final Logger _log = Logger(LogConfig.bootstrapLogger);

  /// Call early in `main()` before running the widget tree.
  static Future<void> init() async {
    _configureLogging();
    await _migrateIfNeeded();
    await AppConfig.instance.load();
    _log.info(
      '${AppInfo.name} v${AppInfo.version} initialized (env: ${AppConfig.instance.environment})',
    );
  }

  /// Centralized logging setup with sanitization and formatting
  static void _configureLogging() {
    Logger.root.level = kDebugMode || FeatureFlags.enableDebugMode
        ? Level.ALL
        : Level.INFO;

    Logger.root.onRecord.listen((rec) {
      final sanitized = rec.message.replaceAll(
        RegExp(r'(sk-|hf_|Bearer\s+)[A-Za-z0-9_\-]+'),
        '[REDACTED]',
      );

      debugPrint(
        '[${rec.time.toIso8601String()}] '
        '[${rec.level.name.padRight(7)}] '
        '[${rec.loggerName.padRight(12)}] $sanitized',
      );
    });
  }

  /// Placeholder for forward‑compatible schema / data migrations.
  ///
  /// Keep this idempotent—safe to run multiple times without altering state
  /// after a successful first run.
  static Future<void> _migrateIfNeeded() async {
    // TODO: Implement versioned migrations when persistent data structures
    // are introduced (e.g., local databases, cached conversations, etc).
  }
}
