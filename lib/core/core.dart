/// Core Library Barrel Export
/// ---------------------------------------------------------------------------
/// Centralized export for all core functionality including configuration,
/// constants, utilities, and common types. Import this file to access
/// foundational app components.
///
/// Example:
///   import 'package:olympus/core/core.dart';
///   ...
///   final result = await catchingAsync(() => apiCall());
///   result.when(success: ..., failure: ...);
library core;

// Configuration
export 'config/app_bootstrap.dart';
export 'config/app_config.dart';

// Constants
export 'config/constants/app_constants.dart';

// Result type and utilities
export 'result.dart';
