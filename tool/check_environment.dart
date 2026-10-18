import 'dart:io';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Read-only local integration check. Does not print the shell environment.
Future<void> main() async {
  const process = LocalMiseProcessService();
  final shell = await process.inspectShellEnvironment();
  final environment = {...Platform.environment, ...?shell.environment};
  final layout = ToolchainLayout(
    home: environment['HOME']!,
    environment: environment,
  );
  ToolchainLayout.current = layout;
  final inventory = await ClassifiedToolchainService(
    process,
    layout,
  ).inventory();
  stdout.writeln('Shell: ${shell.source.name}');
  stdout.writeln('Configuration: ${layout.globalConfigPath}');
  for (final row in inventory) {
    stdout.writeln(
      '${row.tool}@${row.version}: ${row.classified ? 'classified' : 'CHECK'} ${row.active ? '(global)' : ''}',
    );
  }
  if (!shell.isFromShell ||
      inventory.isEmpty ||
      inventory.any((v) => !v.classified)) {
    exitCode = 1;
  }
}
