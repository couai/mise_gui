import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_registry.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'dart:io';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/directory_storage_service.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

Future<void> main() async {
  final shell = await const LocalMiseProcessService().inspectShellEnvironment();
  final environment = {...Platform.environment, ...?shell.environment};
  ToolchainLayout.current = ToolchainLayout(
    home: environment['HOME']!,
    environment: environment,
  );

  final token = DirectoryScanCancellation();
  final watch = Stopwatch()..start();
  try {
    const process = LocalMiseProcessService();
    final layout = ToolchainLayout.current;
    final inventory = await SystemLocalToolInventory(
      layout: layout,
      process: const SystemLocalToolProcess(),
      loadVersions: ClassifiedToolchainService(process, layout).inventory,
      registry: LocalToolRegistry(
        file: File('${layout.appDir}/config/imported_tools.json'),
        process: const SystemLocalToolProcess(),
      ),
    ).scan();
    final result = await DirectoryStorageService(
      layout: ToolchainLayout.current,
      reader: const PosixDirectoryUsageReader(),
    ).scan(inventory, token).last;
    stdout.writeln(
      '${result.entries.length} paths, ${result.completed}/${result.total} measured, ${watch.elapsedMilliseconds}ms',
    );
    stdout.writeln(
      'allocated=${formatStorageBytes(result.measuredBytes)}, cache=${formatStorageBytes(result.cacheBytes)}, aggregateComplete=${result.complete}',
    );
    stdout.writeln(
      'links=${result.entries.where((e) => e.links.isNotEmpty).length}, review=${result.entries.where((e) => e.needsReview).length}',
    );
    for (final e in result.entries.where((e) => e.needsReview).take(20)) {
      stdout.writeln(
        '${e.compliance.label}\t${e.linkState.label}\t${e.path}\t${e.usage.label}',
      );
    }
  } finally {
    token.cancel();
  }
}
