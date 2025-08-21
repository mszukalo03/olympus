/// Application Constants
/// ---------------------------------------------------------------------------
/// Centralized constants for the entire application to avoid magic strings
/// and numbers scattered throughout the codebase.
library app_constants;

/// Application metadata
class AppInfo {
  static const String name = 'AI Orchestrator';
  static const String version = '0.1.0';
  static const String description = 'AI Chat with External Backend Integration';
}

/// Storage keys for SharedPreferences
class StorageKeys {
  static const String themeMode = 'theme_mode';
  static const String runtimeConfig = 'config_runtime.json';
}

/// API and network configuration
class NetworkConfig {
  static const Duration defaultTimeout = Duration(seconds: 30);
  static const Duration connectTimeout = Duration(seconds: 10);
  static const int maxResponseSize = 5 * 1024 * 1024; // 5MB
  static const String userAgent = 'AIChatClient/0.1';

  /// Default endpoints (fallbacks)
  static const String defaultApiEndpoint = 'http://localhost:11434';
  static const String defaultAutomationEndpoint =
      'https://n8n.olympusone.xyz/webhook-test/61eadcf6-7d5c-48ed-b7a2-a07eb5b86031';
  static const String defaultHistoryEndpoint =
      'http://localhost:5000'; // Flask history backend
  static const String defaultRagEndpoint =
      'http://localhost:8890'; // FastAPI RAG backend
  static const String defaultJellyseerrEndpoint =
      'http://localhost:5055/api/v1'; // Jellyseerr API
  static const String defaultSearxngEndpoint =
      'http://localhost:8080'; // SearXNG instance
  static const String defaultEnvironment = 'dev';
}

/// UI constants
class UIConstants {
  /// Spacing
  static const double spacingXS = 4.0;
  static const double spacingS = 8.0;
  static const double spacingM = 12.0;
  static const double spacingL = 16.0;
  static const double spacingXL = 24.0;
  static const double spacingXXL = 32.0;

  /// Border radius
  static const double radiusS = 8.0;
  static const double radiusM = 12.0;
  static const double radiusL = 16.0;
  static const double radiusXL = 20.0;

  /// Animation durations
  static const Duration animationFast = Duration(milliseconds: 150);
  static const Duration animationNormal = Duration(milliseconds: 300);
  static const Duration animationSlow = Duration(milliseconds: 500);

  /// Input constraints
  static const double messageInputMaxHeight = 180.0;
  static const double messageBubbleMaxWidth = 650.0;
  static const int maxContextMessages = 10;
  static const int maxPromptChars = 4000;
}

/// Feature flags and configuration
class FeatureFlags {
  static const bool enableWebSocket = false;
  static const bool enableStreamingResponses = false;
  static const bool enableMarkdownRendering = true;
  static const bool enableConversationPersistence = true;
  static const bool enableOfflineMode = true;
  static const bool enableDebugMode = false;
  static const bool enableConversationContext = true;
}

/// Message and conversation limits
class Limits {
  static const int maxMessagesPerConversation = 1000;
  static const int maxConversationsStored = 100;
  static const int contextWindowSize = 8;
  static const int maxRetryAttempts = 3;
  static const Duration retryDelay = Duration(seconds: 2);
  static const int conversationContextLimit = 20;
  static const int maxContextMessages = 10;
}

/// Error messages
class ErrorMessages {
  static const String networkError = 'Network connection failed';
  static const String timeoutError = 'Request timed out';
  static const String unknownError = 'An unexpected error occurred';
  static const String invalidResponse = 'Invalid response from server';
  static const String unauthorized = 'Authentication required';
  static const String forbidden = 'Access denied';
  static const String notFound = 'Resource not found';
  static const String rateLimited = 'Too many requests, please try again later';
  static const String offline = 'No internet connection';
  static const String emptyMessage = 'Message cannot be empty';
  static const String saveFailed = 'Failed to save conversation';
  static const String loadFailed = 'Failed to load conversation';
}

/// Log levels and debugging
class LogConfig {
  static const String bootstrapLogger = 'Bootstrap';
  static const String chatLogger = 'ChatController';
  static const String settingsLogger = 'SettingsController';
  static const String apiLogger = 'ExternalAIService';
  static const String repositoryLogger = 'ConversationRepository';
}

/// File extensions and MIME types
class FileTypes {
  static const String jsonExtension = '.json';
  static const String pdfExtension = '.pdf';
  static const String jsonMimeType = 'application/json';
  static const String pdfMimeType = 'application/pdf';
}

/// Theme and styling
class ThemeConstants {
  /// Dark theme colors
  static const int darkScaffoldBackground = 0xFF101418;
  static const int darkAppBarBackground = 0xFF161B21;
  static const int darkInputFill = 0xFF1E252C;
  static const int darkBorder = 0xFF2C343C;

  /// Light theme colors
  static const int lightScaffoldBackground = 0xFFF4F6F8;
  static const int lightAppBarBackground = 0xFFFFFFFF;
  static const int lightBorder = 0xFFE0E0E0;

  /// Common
  static const double appBarElevation = 0.0;
  static const double cardElevation = 0.0;
}
