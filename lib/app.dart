/// Main Application Widget
/// ---------------------------------------------------------------------------
/// Optimized app widget with simplified theme configuration and provider setup.
/// Separated from main.dart for better organization and testability.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/core.dart';
import 'shared/shared.dart';
import 'features/chat/screens/chat_screen.dart';

/// Root application widget
class OlympusApp extends StatelessWidget {
  const OlympusApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ChatController()),
        ChangeNotifierProvider(create: (_) => SettingsController()),
      ],
      child: Consumer<SettingsController>(
        builder: (context, settings, _) => MaterialApp(
          title: AppInfo.name,
          debugShowCheckedModeBanner: false,
          themeMode: settings.themeMode,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          home: const ChatScreen(),
        ),
      ),
    );
  }

  /// Build theme with consistent styling
  ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final colorScheme = ColorScheme.fromSeed(
      seedColor: Colors.blue,
      brightness: brightness,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: isDark
          ? const Color(ThemeConstants.darkScaffoldBackground)
          : const Color(ThemeConstants.lightScaffoldBackground),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark
            ? const Color(ThemeConstants.darkAppBarBackground)
            : const Color(ThemeConstants.lightAppBarBackground),
        foregroundColor: isDark ? Colors.white : Colors.black87,
        elevation: ThemeConstants.appBarElevation,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: isDark ? Colors.white : Colors.black87,
        ),
      ),
      cardTheme: CardThemeData(
        elevation: ThemeConstants.cardElevation,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UIConstants.radiusL),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? const Color(ThemeConstants.darkInputFill)
            : Colors.white,
        border: _buildInputBorder(isDark),
        enabledBorder: _buildInputBorder(isDark),
        focusedBorder: _buildFocusedInputBorder(),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UIConstants.spacingL,
          vertical: UIConstants.spacingM,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: UIConstants.spacingXL,
            vertical: UIConstants.spacingM,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UIConstants.radiusM),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(
            horizontal: UIConstants.spacingL,
            vertical: UIConstants.spacingS,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(UIConstants.radiusS),
          ),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: colorScheme.outline.withValues(alpha: 0.2),
        thickness: 0.5,
      ),
    );
  }

  OutlineInputBorder _buildInputBorder(bool isDark) => OutlineInputBorder(
    borderRadius: BorderRadius.circular(UIConstants.radiusM),
    borderSide: BorderSide(
      color: isDark
          ? const Color(ThemeConstants.darkBorder)
          : const Color(ThemeConstants.lightBorder),
      width: 0.8,
    ),
  );

  OutlineInputBorder _buildFocusedInputBorder() => OutlineInputBorder(
    borderRadius: BorderRadius.circular(UIConstants.radiusM),
    borderSide: BorderSide(color: Colors.blue.shade400, width: 1.5),
  );
}
