import 'package:flutter/material.dart';

import 'core/core.dart';
import 'app.dart';

/// Application entrypoint
/// ---------------------------------------------------------------------------
/// Simplified main function that initializes the app and runs the widget tree.
/// All configuration, dependency injection, and theming is handled in app.dart.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppBootstrap.init();
  runApp(const OlympusApp());
}
