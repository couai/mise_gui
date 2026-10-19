import 'dart:io';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/project_profile_service.dart';

class ProjectVersionPlan {
  ProjectVersionPlan._(
    this.projectPath,
    this.tool,
    this.version,
    this.command,
    this._snapshot,
  );
  final String projectPath, tool, version, command;
  final Map<String, String?> _snapshot;
  String get configPath => '$projectPath/mise.toml';
}

/// All project writes reuse the classified mise policy and tracked action owner.
class ProjectVersionService {
  const ProjectVersionService(this.policy, this.actions);
  final ClassifiedToolchainService policy;
  final MiseActionService actions;

  Future<Map<String, String?>> _capture(String path) async {
    final root = await Directory(path).resolveSymbolicLinks();
    if (root != path || path == policy.layout.home || path == '/') {
      throw StateError('请选择明确的项目目录；目录已移动或指向用户主目录。');
    }
    return {
      for (final name in ProjectProfileService.versionNames)
        name: await ProjectProfileService.readMetadata(path, name),
    };
  }

  Future<ProjectVersionPlan> preview(
    String path,
    String tool,
    String version,
  ) async {
    final canonical = await Directory(path).resolveSymbolicLinks();
    final snapshot = await _capture(canonical);
    final command = await policy.switchPlan(
      tool,
      version,
      projectPath: canonical,
    );
    return ProjectVersionPlan._(
      canonical,
      tool,
      version,
      command,
      Map.unmodifiable(snapshot),
    );
  }

  Future<MiseActionResult> apply(ProjectVersionPlan plan) async {
    final fresh = await _capture(plan.projectPath);
    if (fresh.entries.any((e) => e.value != plan._snapshot[e.key])) {
      throw StateError('项目版本文件在预览后已变化，请刷新并重新预览。');
    }
    if (await policy.switchPlan(
          plan.tool,
          plan.version,
          projectPath: plan.projectPath,
        ) !=
        plan.command) {
      throw StateError('工具安装状态已变化，请重新预览。');
    }
    return actions.runScript(plan.command, workingDirectory: plan.projectPath);
  }
}
