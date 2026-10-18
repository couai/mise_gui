import 'dart:io';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/local_tool_registry.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

Future<void> main() async {
  const process = LocalMiseProcessService();
  final shell = await process.inspectShellEnvironment();
  final layout = ToolchainLayout(
    home: Platform.environment['HOME']!,
    environment: {...Platform.environment, ...?shell.environment},
  );
  final timer = Stopwatch()..start();
  final result = await SystemLocalToolInventory(
    layout: layout,
    registry: LocalToolRegistry(
      file: File('${layout.appDir}/config/imported_tools.json'),
      process: const SystemLocalToolProcess(),
    ),
    process: const SystemLocalToolProcess(),
    loadVersions: ClassifiedToolchainService(process, layout).inventory,
  ).scan();
  for (final tool in result.tools) {
    stdout.writeln(
      '${tool.id}\t${tool.statusLabel}\t${tool.version ?? '-'}\t${tool.manager}',
    );
    for (final note in tool.notes) {
      stdout.writeln('  $note');
    }
  }
  stdout.writeln(
    '${result.tools.where((t) => t.installed).length}/${result.tools.length} installed, ${timer.elapsedMilliseconds}ms',
  );
  for (final warning in result.warnings) {
    stdout.writeln(warning);
  }
}
