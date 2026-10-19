import 'dart:io';
import 'package:mise_gui/services/local_tool_process.dart';

class ProjectLauncher {
  const ProjectLauncher(this.process);
  final LocalToolProcess process;
  Future<void> open(String projectPath, {String? applicationPath}) async {
    if (!File(projectPath).isAbsolute ||
        !await Directory(projectPath).exists()) {
      throw StateError('项目目录不存在，请重新扫描。');
    }
    if (applicationPath != null &&
        (!File(applicationPath).isAbsolute ||
            !applicationPath.endsWith('.app') ||
            !await Directory(applicationPath).exists())) {
      throw StateError('应用已移动，请重新扫描开发工具。');
    }
    final result = await process.run('/usr/bin/open', [
      if (applicationPath != null) ...['-a', applicationPath],
      projectPath,
    ]);
    if (result.exitCode != 0) throw StateError('macOS 无法打开项目。');
  }
}
