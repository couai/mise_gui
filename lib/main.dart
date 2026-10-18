import 'dart:io';
import 'package:flutter/widgets.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final shell = await const LocalMiseProcessService().inspectShellEnvironment();
  final environment = {...Platform.environment, ...?shell.environment};
  ToolchainLayout.current = ToolchainLayout(
    home: environment['HOME'] ?? Directory.current.path,
    environment: environment,
  );

  runApp(const ProviderScope(child: MiseGuiApp()));
}
