import 'dart:io';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_scan_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Read-only acceptance: existing tools and projects, without task/settings writes.
Future<void> main(List<String> args) async {
  const process = LocalMiseProcessService(
    environmentOverrides: {'MISE_OFFLINE': '1', 'MISE_AUTO_INSTALL': '0'},
  );
  final shell = await process.inspectShellEnvironment();
  final layout = ToolchainLayout(
    home: Platform.environment['HOME']!,
    environment: {...Platform.environment, ...?shell.environment},
  );
  ToolchainLayout.current = layout;
  const query = CliMiseQueryService(process);
  if (args.length == 2 && args.first == '--scan') {
    final projects = await const LiveProjectScanService(
      queryService: query,
    ).fetchProjects([ScanDirectoryRecord(path: args[1])]);
    for (final project in projects) {
      stdout.writeln('${project.name}\t${project.environment}');
    }
    stdout.writeln('${projects.length} projects; read-only scan');
    return;
  }
  final local = await SystemLocalToolInventory(
    layout: layout,
    process: const SystemLocalToolProcess(),
    loadVersions: ClassifiedToolchainService(process, layout).inventory,
  ).scan();
  const service = ProjectEnvironmentService(ProjectProfileService(), query);
  for (final path in args.isEmpty ? [Directory.current.path] : args) {
    final result = await service.inspect(path, local);
    stdout.writeln(
      '${result.profile.name}: ${result.profile.stacks.join(' / ')}',
    );
    for (final check in result.checks) {
      stdout.writeln(
        '${check.tool}\t${check.state.label}\t${check.effective ?? 'unverified'}',
      );
    }
    stdout.writeln(
      '${result.issueCount} tool issues; ${result.profile.warnings.length} metadata warnings',
    );
    if (result.queryIssue != null) stdout.writeln(result.queryIssue);
  }
}
