/// Shared Library Barrel Export
/// ---------------------------------------------------------------------------
/// Centralized export for all shared components, models, controllers, and
/// services. Import this file to access commonly used shared functionality.
///
/// Example:
///   import 'package:olympus/shared/shared.dart';
///   ...
///   final chat = context.read<ChatController>();
///   final message = ChatMessage.user('Hello');
library shared;

// Controllers
export 'controllers/chat_controller.dart';
export 'controllers/settings_controller.dart';

// Models
export 'models/chat_message.dart';

// Repositories

export 'repositories/history_repository.dart';
export 'repositories/rag_repository.dart';

// Services
export 'services/ai_service.dart';
export 'services/history/history_service.dart';
export 'services/rag/rag_service.dart';
export 'services/custom/custom_endpoint_service.dart';
export 'services/custom/jellyseerr_service.dart';
export 'services/custom/searxng_service.dart';
export 'services/custom/duckduckgo_service.dart';

// Widgets
export 'widgets/section_card.dart';
