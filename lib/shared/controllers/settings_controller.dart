import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:logging/logging.dart';

import '../../core/config/constants/app_constants.dart';
import '../../core/result.dart';

/// SettingsController
/// ---------------------------------------------------------------------------
/// Separates application *UI / preference* state from other domain controllers
/// (e.g., chat).  Currently handles:
///   • Theme mode (light / dark / system) with persistence
///
/// Design goals:
///   • Lazy, resilient initialization (never blocks app startup UI)
///   • Explicit readiness signal (via `ready` future & `isLoaded`)
///   • Minimal synchronous getters for seamless widget rebuilds
///   • Clear extension points for future settings
///
/// Extension ideas:
///   • Locale / language selection
///   • Font scaling & accessibility toggles
///   • Experimental feature flags
///   • Privacy / telemetry consent
///   • Data purge options
///
/// Usage:
///   final settings = context.watch<SettingsController>();
///   ThemeMode mode = settings.themeMode;
///
///   // Ensure loaded before using persisted-dependent logic:
///   await settings.ready; // (Optional if you only read `themeMode`)
class SettingsController extends ChangeNotifier {
  static final Logger _log = Logger(LogConfig.settingsLogger);

  // Internal State
  ThemeMode _themeMode = ThemeMode.dark;
  bool _loaded = false;
  String? _lastError;
  late final Future<void> _initFuture;

  SettingsController() {
    _initFuture = _load();
  }

  /// External awaitable future signifying initial load completion.
  Future<void> get ready => _initFuture;

  /// Whether initial preference load completed (success or graceful fallback).
  bool get isLoaded => _loaded;

  /// Current effective theme mode (defaults to dark until load completes).
  ThemeMode get themeMode => _themeMode;

  /// Last error that occurred during settings operations
  String? get lastError => _lastError;

  /// Whether there was an error during the last operation
  bool get hasError => _lastError != null;

  /// Load settings from persistent storage
  Future<void> _load() async {
    final result = await _loadSettings();
    result.when(
      success: (themeMode) {
        _themeMode = themeMode;
        _lastError = null;
        _log.info('Settings loaded successfully: theme=${themeMode.name}');
      },
      failure: (error) {
        _lastError = error.message;
        _log.warning('Failed to load settings: ${error.message}');
      },
    );
    _loaded = true;
    notifyListeners();
  }

  /// Load theme settings with proper error handling
  Future<Result<ThemeMode>> _loadSettings() => catchingAsync(() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(StorageKeys.themeMode);
    return switch (stored) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark, // Default fallback
    };
  });

  /// Cycle between dark and light (ignores system mode for simplicity).
  /// Prefer `setTheme` if you need explicit control including system.
  Future<void> toggleTheme() async {
    final next = switch (_themeMode) {
      ThemeMode.dark => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.system => ThemeMode.dark,
    };
    await setTheme(next);
  }

  /// Set a specific theme mode and persist with error handling
  Future<void> setTheme(ThemeMode mode) async {
    if (_themeMode == mode) return;

    final oldMode = _themeMode;
    _themeMode = mode;
    _lastError = null;
    notifyListeners();

    final result = await _persistTheme(mode);
    result.when(
      success: (_) {
        _log.info('Theme changed: $oldMode -> $mode');
      },
      failure: (error) {
        _lastError = error.message;
        _log.warning('Failed to persist theme: ${error.message}');
        // Theme is still changed in UI, just persistence failed
      },
    );
  }

  /// Persist theme setting with error handling
  Future<Result<void>> _persistTheme(ThemeMode mode) => catchingAsync(() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(StorageKeys.themeMode, mode.name);
  });

  /// Clear any error state
  void clearError() {
    if (_lastError != null) {
      _lastError = null;
      notifyListeners();
    }
  }

  /// Reload preferences from storage (useful if external process mutated them).
  Future<void> reload() async {
    _loaded = false;
    _lastError = null;
    notifyListeners(); // Allow UI to show a transient loading indicator if desired.
    await _load();
  }

  /// Reset all settings to defaults
  Future<void> resetToDefaults() async {
    await setTheme(ThemeMode.dark);
    _log.info('Settings reset to defaults');
  }

  /// Provide a snapshot of current settings for diagnostics/export.
  Map<String, dynamic> toDebugJson() => {
    'loaded': _loaded,
    'themeMode': _themeMode.name,
    'hasError': hasError,
    'lastError': _lastError,
    'timestamp': DateTime.now().toIso8601String(),
  };
}
