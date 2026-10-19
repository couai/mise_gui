import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/projects/application/projects_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/project_environment_tasks.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/shared/ui/action_preview_dialog.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';
import 'package:mise_gui/shared/ui/async_state_view.dart';
import 'package:mise_gui/shared/ui/tool_logo.dart';
import 'package:mise_gui/shared/ui/status_badge.dart';

class ProjectEnvironmentPage extends ConsumerStatefulWidget {
  const ProjectEnvironmentPage({super.key, required this.projectPath});
  final String projectPath;
  @override
  ConsumerState<ProjectEnvironmentPage> createState() =>
      _ProjectEnvironmentPageState();
}

class _ProjectEnvironmentPageState
    extends ConsumerState<ProjectEnvironmentPage> {
  bool checking = false, pinning = false;
  String? message;
  ProjectEnvironment? checked;
  final selections = <String, String>{};

  Future<void> run(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => message = '操作未完成；请检查项目路径、工具安装状态或任务中心。');
    }
  }

  Future<void> check() async {
    if (checking) return;
    setState(() {
      checking = true;
      message = null;
    });
    // Capture services before awaiting; the task keeps running if this page closes.
    final center = ref.read(taskCenterProvider.notifier);
    final service = ref.read(projectEnvironmentServiceProvider);
    ref.invalidate(localToolsProvider);
    final local = ref.read(localToolsProvider.future);
    try {
      final value = await checkProjectEnvironment(
        service,
        center,
        widget.projectPath,
        local,
      );
      if (mounted) setState(() => checked = value);
    } catch (_) {
      if (mounted) setState(() => message = '项目检查失败；详细结果已记录到任务中心。');
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  Future<void> pin(String tool, String version) async {
    if (pinning || ref.read(taskCenterProvider).busy) return;
    setState(() {
      pinning = true;
      message = null;
    });
    final service = ref.read(projectVersionServiceProvider);
    try {
      final plan = await service.preview(widget.projectPath, tool, version);
      if (!mounted) return;
      final confirm = await showActionPreviewDialog(
        context,
        data: ActionPreviewDialogData(
          title: '固定项目 $tool 版本',
          summary: '将当前项目的 $tool 固定为已安装的 $version。',
          command: plan.command,
          level: HealthLevel.warning,
          affectedFiles: [plan.configPath],
          impactScope: [
            '项目：${plan.projectPath}',
            '由 mise 编辑 [tools]，保留其他配置段；全局默认版本保持原值。',
          ],
          riskNotes: [
            '项目内其他版本文件可能有不同声明；执行后检查项目实际生效版本。',
            '配置未受信任时 mise 可能拒绝操作；本程序不自动 trust。',
          ],
          confirmLabel: '确认固定项目版本',
        ),
      );
      if (!confirm) return;
      final result = await service.apply(plan);
      if (!mounted) return;
      ref.invalidate(projectEnvironmentProvider(widget.projectPath));
      ref.invalidate(projectCoverageProvider);
      ref.invalidate(projectsProvider);
      ref.invalidate(classifiedVersionsProvider);
      setState(() {
        checked = null;
        message = result.isSuccess
            ? '项目版本已写入并验证，记录见任务中心。'
            : '项目版本验证未通过，请查看任务中心。';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => message = error is StateError || error is FormatException
              ? '$error'
              : '无法固定项目版本，请检查配置和本地 SDK 后重新预览。',
        );
      }
    } finally {
      if (mounted) setState(() => pinning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(projectEnvironmentProvider(widget.projectPath));
    final local = ref.watch(localToolsProvider).valueOrNull;
    final busy = ref.watch(taskCenterProvider).busy;
    final versions = ref.watch(classifiedVersionsProvider).valueOrNull ?? [];
    return AsyncStateView(
      value: value,
      builder: (original) {
        final environment = checked ?? original, profile = environment.profile;
        return AppPageScaffold(
          title: profile.name,
          description: profile.path,
          actions: [
            TextButton.icon(
              onPressed: () => context.go('/projects'),
              icon: const Icon(Icons.arrow_back),
              label: const Text('全部项目'),
            ),
            FilledButton.icon(
              onPressed: checking || busy ? null : check,
              icon: const Icon(Icons.fact_check_outlined),
              label: Text(checking ? '检查中…' : '检查环境'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (message != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: SelectableText(message!),
                ),
              AppPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '项目档案',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        Chip(label: Text('${environment.issueCount} 项待处理')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final stack in profile.stacks)
                          Chip(label: Text(stack)),
                        if (profile.stacks.isEmpty)
                          const Chip(label: Text('mise 工作区')),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text('核对范围：工具与版本声明。依赖安装、签名、项目构建和测试需在项目中执行。'),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => run(
                            () => ref
                                .read(projectLauncherProvider)
                                .open(profile.path),
                          ),
                          icon: const Icon(Icons.folder_open_outlined),
                          label: const Text('Finder'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => run(
                            () => ref
                                .read(projectLauncherProvider)
                                .open(
                                  profile.path,
                                  applicationPath:
                                      '/System/Applications/Utilities/Terminal.app',
                                ),
                          ),
                          icon: const Icon(Icons.terminal),
                          label: const Text('终端'),
                        ),
                        for (final tool
                            in (local?.tools ?? const <LocalTool>[]).where(
                              (t) =>
                                  [
                                    'vscode',
                                    'cursor',
                                    'idea',
                                    'android-studio',
                                    'xcode',
                                    'hbuilderx',
                                  ].contains(t.id) &&
                                  t.installed,
                            ))
                          if (tool.locations.any(
                            (l) => l.application && l.exists,
                          ))
                            OutlinedButton.icon(
                              onPressed: () => run(
                                () => ref
                                    .read(projectLauncherProvider)
                                    .open(
                                      profile.path,
                                      applicationPath: tool.locations
                                          .firstWhere(
                                            (l) => l.application && l.exists,
                                          )
                                          .path,
                                    ),
                              ),
                              icon: ToolLogo(tool: tool.id, size: 18),
                              label: Text(tool.name),
                            ),
                        if (profile.brunoPath != null)
                          OutlinedButton.icon(
                            onPressed: () => run(
                              () => ref
                                  .read(projectLauncherProvider)
                                  .open(profile.brunoPath!),
                            ),
                            icon: const ToolLogo(tool: 'bruno', size: 18),
                            label: const Text('接口集合目录'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AppPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '版本要求与实际环境',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '检查时间：${environment.checkedAt.toLocal().toString().split('.').first} · 运行时按项目目录查询 mise；包管理器显示本机探测结果。',
                    ),
                    if (environment.queryIssue != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(environment.queryIssue!),
                      ),
                    if (environment.checks.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('未识别出工具声明，请检查项目元数据或配置 mise.toml。'),
                      ),
                    for (final check in environment.checks)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: _ToolCheckCard(
                          check: check,
                          selection: selections[check.tool],
                          allowPin:
                              ToolchainLayout.categories.containsKey(
                                check.tool,
                              ) &&
                              versions.any((v) => v.tool == check.tool),
                          pinVersions: versions
                              .where((v) => v.tool == check.tool)
                              .map((v) => v.version)
                              .toList(),
                          disabled: pinning || busy,
                          onSelect: (v) =>
                              setState(() => selections[check.tool] = v),
                          onPin: (v) => pin(check.tool, v),
                          onOpenTool: () => context.go(
                            Uri(
                              path: '/local-tools',
                              queryParameters: {'tool': check.tool},
                            ).toString(),
                          ),
                          onVersions: () => context.go(
                            Uri(
                              path: '/tools',
                              queryParameters: {'tool': check.tool},
                            ).toString(),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              AppPanel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '声明文件与项目命令',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final file in profile.evidence)
                          ActionChip(
                            label: Text(file),
                            avatar: const Icon(
                              Icons.description_outlined,
                              size: 16,
                            ),
                            onPressed: () => run(
                              () => ref
                                  .read(localToolOpenerProvider)
                                  .open('${profile.path}/$file'),
                            ),
                          ),
                      ],
                    ),
                    if (profile.scripts.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text('package.json 脚本 · 复制后自行检查和运行'),
                      for (final script in profile.scripts)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(script.name),
                          subtitle: Text(script.command),
                          trailing: IconButton(
                            tooltip: '复制项目命令',
                            icon: const Icon(Icons.content_copy),
                            onPressed: () async {
                              await Clipboard.setData(
                                ClipboardData(text: script.command),
                              );
                              if (mounted) {
                                setState(
                                  () =>
                                      message = '已复制 ${script.name} 命令；未执行脚本。',
                                );
                              }
                            },
                          ),
                        ),
                    ],
                    for (final warning in profile.warnings)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text('• $warning'),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ToolCheckCard extends StatelessWidget {
  const _ToolCheckCard({
    required this.check,
    required this.selection,
    required this.allowPin,
    required this.pinVersions,
    required this.disabled,
    required this.onSelect,
    required this.onPin,
    required this.onOpenTool,
    required this.onVersions,
  });
  final ProjectToolCheck check;
  final String? selection;
  final bool allowPin, disabled;
  final List<String> pinVersions;
  final ValueChanged<String> onSelect, onPin;
  final VoidCallback onOpenTool, onVersions;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ToolLogo(tool: check.tool),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  check.tool,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              StatusBadge(
                label: check.state.label,
                level: switch (check.state) {
                  ProjectToolState.satisfied ||
                  ProjectToolState.available => HealthLevel.healthy,
                  ProjectToolState.mismatch ||
                  ProjectToolState.missing => HealthLevel.critical,
                  ProjectToolState.review => HealthLevel.warning,
                  ProjectToolState.projectProvided => HealthLevel.info,
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final req in check.requirements)
            Text('要求 ${req.value} · ${req.source}'),
          if (check.requirements.isEmpty) const Text('版本要求：未声明'),
          const SizedBox(height: 6),
          Text(
            '${check.source == '本机工具探测' ? '本机探测' : '实际生效'}：${check.effective ?? '未确认'}',
          ),
          if (check.source != null)
            Text(
              '来源：${check.source}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          Text(
            '本地已安装：${check.installed.isEmpty ? '未检测到' : check.installed.join('、')}',
          ),
          if (check.detail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(check.detail),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(onPressed: onOpenTool, child: const Text('工具档案')),
              if (ToolchainLayout.categories.containsKey(check.tool))
                TextButton(
                  onPressed: onVersions,
                  child: const Text('mise 版本管理'),
                ),
              if (allowPin) ...[
                SizedBox(
                  width: 230,
                  child: DropdownButtonFormField<String>(
                    initialValue: pinVersions.contains(selection)
                        ? selection
                        : null,
                    isExpanded: true,
                    hint: const Text('选择已安装版本'),
                    items: [
                      for (final v in pinVersions)
                        DropdownMenuItem(value: v, child: Text(v)),
                    ],
                    onChanged: disabled
                        ? null
                        : (v) {
                            if (v != null) onSelect(v);
                          },
                  ),
                ),
                FilledButton.tonal(
                  onPressed: disabled || !pinVersions.contains(selection)
                      ? null
                      : () => onPin(selection!),
                  child: const Text('固定到本项目'),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );
}
