import 'package:flutter/material.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';

class ProjectRuntimeDetails extends StatelessWidget {
  const ProjectRuntimeDetails({
    super.key,
    required this.environment,
    required this.onOpen,
  });
  final ProjectEnvironment environment;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final venvs = environment.pythonEnvironments, modules = environment.modules;
    final python = environment.profile.toolIds.contains('python');
    if (venvs.isEmpty && modules.isEmpty && !python) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: AppPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (venvs.isNotEmpty || python) ...[
              Text(
                'Python 项目虚拟环境',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text('候选目录与已选择环境分别显示；仅有 .venv 不代表当前终端已经激活。'),
              if (venvs.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text('未发现项目虚拟环境；当前对照 mise 基础 Python，尚未创建环境或安装项目依赖。'),
                ),
              for (final venv in venvs)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          venv.path,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          venv.selected
                              ? '项目已选择 · ${venv.selection}'
                              : venv.selection,
                        ),
                        Text(
                          'Python：${venv.version ?? '未确认'} · pip：${venv.pipVersion ?? '未检测到安装记录（uv 环境可不含 pip）'}',
                        ),
                        if (venv.interpreter != null)
                          Text('基础解释器：${venv.interpreter}'),
                        if (venv.issue != null) Text('待核对：${venv.issue}'),
                        TextButton.icon(
                          onPressed: () => onOpen(venv.path),
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('打开虚拟环境目录'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
            if (venvs.isNotEmpty && modules.isNotEmpty)
              const SizedBox(height: 20),
            if (modules.isNotEmpty) ...[
              Text(
                'Java / Gradle 模块 · ${modules.length}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                '区分编译级别、Gradle 工具链和启动 JVM。Wrapper 版本来自静态配置，未运行 Wrapper 或下载构建依赖。',
              ),
              for (final check in modules)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 6,
                          children: [
                            Text(
                              '${check.module.name} · ${check.module.manager}',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            Text(check.state.label),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text('构建文件：${check.module.buildFile}'),
                        for (final req in check.module.requirements)
                          Text(
                            '${req.source.contains('toolchain') ? '编译工具链' : '编译级别'}：${req.value} · ${req.source}',
                          ),
                        Text('mise 选择的 JDK：${check.javaVersion ?? '未确认'}'),
                        if (check.javaSource != null)
                          Text('JVM 来源：${check.javaSource}'),
                        if (check.module.wrapperVersion != null)
                          Text(
                            'Gradle Wrapper 声明：${check.module.wrapperVersion}',
                          ),
                        Text(check.detail),
                        for (final warning in check.module.warnings)
                          Text('待核对：$warning'),
                        TextButton.icon(
                          onPressed: () => onOpen(check.module.path),
                          icon: const Icon(Icons.folder_open, size: 18),
                          label: const Text('打开模块目录'),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
