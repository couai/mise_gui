import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:mise_gui/shared/ui/tool_logo.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/dashboard/application/dashboard_provider.dart';
import 'package:mise_gui/features/projects/application/projects_provider.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/features/tools/application/tools_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/shared/ui/action_preview_dialog.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/async_state_view.dart';

const toolchainNames = {
  'java': 'Java',
  'node': 'Node.js',
  'python': 'Python',
  'go': 'Go',
  'rust': 'Rust',
  'flutter': 'Flutter / Dart',
};

class ToolchainsPage extends ConsumerStatefulWidget {
  const ToolchainsPage({super.key, this.initialTool});
  final String? initialTool;
  @override
  ConsumerState<ToolchainsPage> createState() => _ToolchainsPageState();
}

class _ToolchainsPageState extends ConsumerState<ToolchainsPage> {
  String selectedTool = 'java';
  String? selectedVersion;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    if (toolchainNames.containsKey(widget.initialTool)) {
      selectedTool = widget.initialTool!;
    }
  }

  @override
  void didUpdateWidget(covariant ToolchainsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialTool != oldWidget.initialTool &&
        toolchainNames.containsKey(widget.initialTool)) {
      selectedTool = widget.initialTool!;
      selectedVersion = null;
    }
  }

  void refresh() {
    ref.invalidate(classifiedVersionsProvider);
    ref.invalidate(localToolsProvider);
    ref.invalidate(toolsProvider);
    ref.invalidate(dashboardProvider);
    ref.invalidate(projectsProvider);
    ref.invalidate(projectCoverageProvider);
  }

  Future<void> perform(
    Future<String> Function() createPlan,
    String title,
  ) async {
    if (busy) return;
    setState(() => busy = true);
    final log = ValueNotifier('准备操作…');
    var runningDialog = false;
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      final script = await createPlan();
      if (!mounted) return;
      final confirmed = await showActionPreviewDialog(
        context,
        data: ActionPreviewDialogData(
          title: title,
          summary: 'SDK 保留在分类目录。安装与切换分别执行，所选作用域会在命令中明确显示。',
          command: script,
          level: HealthLevel.info,
          affectedFiles: [ToolchainLayout.current.root],
          impactScope: const ['安装不会自动改变全局默认版本。', '切换只使用已安装版本。'],
          confirmLabel: '执行操作',
        ),
      );
      if (!confirmed || !mounted) return;
      runningDialog = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: Text(title),
              content: SizedBox(
                width: 760,
                height: 360,
                child: Column(
                  children: [
                    const LinearProgressIndicator(),
                    const SizedBox(height: 20),
                    Expanded(
                      child: SingleChildScrollView(
                        child: ValueListenableBuilder<String>(
                          valueListenable: log,
                          builder: (_, value, _) => SelectableText(
                            value,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final result = await ref
          .read(miseActionServiceProvider)
          .runScript(
            script,
            onProgress: (event) {
              final next = '${log.value}\n${event.output ?? event.command}';
              log.value = next.length > 24000
                  ? next.substring(next.length - 24000)
                  : next;
            },
          );
      navigator.pop();
      runningDialog = false;
      if (!mounted) return;
      await ref
          .read(historyServiceProvider)
          .appendEntry(
            HistoryEntry(
              command: script,
              timestamp: DateTime.now().toIso8601String(),
              detail: result.isSuccess ? title : result.stderr,
              level: result.isSuccess
                  ? HealthLevel.healthy
                  : HealthLevel.warning,
              status: result.isSuccess
                  ? HistoryStatus.success
                  : HistoryStatus.failure,
            ),
          );
      refresh();
      if (!result.isSuccess) throw StateError(result.stderr);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$title 已完成')));
      }
    } catch (error) {
      if (runningDialog) navigator.pop();
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('操作未完成'),
            content: SingleChildScrollView(child: SelectableText('$error')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      }
    } finally {
      // The closing route may still be animating and using the notifier.
      Future<void>.delayed(const Duration(seconds: 1), log.dispose);
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install() async {
    final request = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _InstallDialog(initialTool: selectedTool),
    );
    if (request == null) return;
    await perform(
      () => ref
          .read(classifiedToolchainServiceProvider)
          .installPlan(request.$1, request.$2),
      '安装 ${toolchainNames[request.$1]} ${request.$2}',
    );
  }

  Future<void> switchProject(ClassifiedVersion version) async {
    final path = await getDirectoryPath(confirmButtonText: '选择项目');
    if (path == null || !mounted) return;
    await perform(
      () => ref
          .read(classifiedToolchainServiceProvider)
          .switchPlan(version.tool, version.version, projectPath: path),
      '固定项目版本',
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = ToolchainLayout.current;
    return AsyncStateView(
      value: ref.watch(classifiedVersionsProvider),
      builder: (versions) {
        final entries = versions.where((v) => v.tool == selectedTool).toList();
        final selected =
            entries.where((v) => v.version == selectedVersion).firstOrNull ??
            entries.where((v) => v.active).firstOrNull ??
            entries.firstOrNull;
        return AppPageScaffold(
          title: '分类工具链',
          description: '版本、目录与生效范围，一处看清。',
          actions: [
            OutlinedButton.icon(
              onPressed: busy ? null : refresh,
              icon: const Icon(Icons.refresh),
              label: const Text('刷新'),
            ),
            FilledButton.icon(
              onPressed: busy ? null : install,
              icon: const Icon(Icons.add),
              label: const Text('安装版本'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Surface(
                child: Row(
                  children: [
                    const Icon(Icons.folder_copy_outlined, size: 28),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '开发工具根目录',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            layout.root,
                            style: const TextStyle(fontFamily: 'monospace'),
                          ),
                        ],
                      ),
                    ),
                    _Badge(
                      '${versions.map((v) => v.tool).toSet().length} 类运行时 · ${versions.length} 个版本',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final list = Column(
                    children: [
                      for (final tool in toolchainNames.keys)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ToolTile(
                            tool: tool,
                            versions: versions
                                .where((v) => v.tool == tool)
                                .toList(),
                            selected: selectedTool == tool,
                            onTap: () => setState(() {
                              selectedTool = tool;
                              selectedVersion = null;
                            }),
                          ),
                        ),
                    ],
                  );
                  final detail = _Surface(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                toolchainNames[selectedTool]!,
                                style: Theme.of(
                                  context,
                                ).textTheme.headlineSmall,
                              ),
                            ),
                            _Badge(
                              selectedTool == 'rust' ? 'rustup 管理' : 'mise 管理',
                            ),
                          ],
                        ),
                        const SizedBox(height: 22),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final v in entries)
                              ChoiceChip(
                                label: Text(
                                  '${v.version}${v.active ? ' · 全局默认' : ''}',
                                ),
                                selected: selected == v,
                                onSelected: (_) =>
                                    setState(() => selectedVersion = v.version),
                              ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        if (selected != null) ...[
                          _PathField(
                            label: selectedTool == 'rust'
                                ? '共享代理位置'
                                : 'SDK 实际位置',
                            value: selected.actualPath,
                          ),
                          if (selected.rustSdkPath != null) ...[
                            const SizedBox(height: 16),
                            _PathField(
                              label: 'rustup 工具链位置',
                              value: selected.rustSdkPath!,
                            ),
                          ],
                          if (selected.dartVersion != null) ...[
                            const SizedBox(height: 16),
                            _Badge(
                              '配套 Dart ${selected.dartVersion}',
                              tool: 'dart',
                            ),
                          ],
                          const SizedBox(height: 16),
                          _PathField(
                            label: 'mise 注册路径',
                            value: selected.registeredPath,
                          ),
                          const SizedBox(height: 16),
                          _PathField(
                            label: '当前版本配置来源',
                            value: selected.sourcePath ?? '该版本当前未激活',
                          ),
                          const SizedBox(height: 20),
                          _Badge(
                            selected.classified ? '已符合分类目录规范' : '目录需要检查',
                            warning: !selected.classified,
                          ),
                          const SizedBox(height: 24),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              FilledButton(
                                onPressed: busy || selected.active
                                    ? null
                                    : () => perform(
                                        () => ref
                                            .read(
                                              classifiedToolchainServiceProvider,
                                            )
                                            .switchPlan(
                                              selected.tool,
                                              selected.version,
                                            ),
                                        '设为全局默认',
                                      ),
                                child: const Text('设为全局默认'),
                              ),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => switchProject(selected),
                                child: const Text('用于指定项目'),
                              ),
                              TextButton.icon(
                                onPressed: () => Process.run('/usr/bin/open', [
                                  selected.actualPath,
                                ]),
                                icon: const Icon(Icons.folder_open, size: 18),
                                label: const Text('打开目录'),
                              ),
                            ],
                          ),
                        ] else
                          const Text('尚无已安装版本，点击“安装版本”开始。'),
                        const Divider(height: 42),
                        Text(
                          selectedTool == 'flutter'
                              ? 'Dart 随所选 Flutter SDK 配套切换。项目仍使用 mise.toml 固定 Flutter 版本。'
                              : selectedTool == 'rust'
                              ? '多个 Rust 版本共享 cargo/bin 代理。真实工具链由 RUSTUP_HOME 管理，切换不会删除共享目录。'
                              : '全局默认用于未固定版本的项目；已有项目配置继续优先。切换不会安装缺失版本。',
                          style: TextStyle(
                            color: AppTheme.colorsOf(context).textMuted,
                            height: 1.7,
                          ),
                        ),
                      ],
                    ),
                  );
                  if (constraints.maxWidth < 840) {
                    return Column(
                      children: [list, const SizedBox(height: 12), detail],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(width: 270, child: list),
                      const SizedBox(width: 20),
                      Expanded(child: detail),
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              Text(
                '配置：${layout.globalConfigPath}',
                style: TextStyle(
                  color: AppTheme.colorsOf(context).textMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.tool,
    required this.versions,
    required this.selected,
    required this.onTap,
  });
  final String tool;
  final List<ClassifiedVersion> versions;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    final active = versions.where((v) => v.active).firstOrNull;
    return Material(
      color: selected ? colors.info.withValues(alpha: .12) : colors.panelRaised,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: selected ? colors.info : colors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: colors.backgroundDeep,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: ToolLogo(tool: tool, size: 28),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      toolchainNames[tool]!,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      active?.version ?? '未设置默认',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
              Text(
                '${versions.length}',
                style: TextStyle(color: colors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Surface extends StatelessWidget {
  const _Surface({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: colors.panelRaised,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, {this.warning = false, this.tool});
  final String? tool;
  final String text;
  final bool warning;
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context),
        color = warning ? colors.warning : colors.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (tool != null) ...[
            ToolLogo(tool: tool!, size: 17),
            const SizedBox(width: 6),
          ],
          Text(text, style: TextStyle(color: color, fontSize: 12)),
        ],
      ),
    );
  }
}

class _PathField extends StatelessWidget {
  const _PathField({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: TextStyle(
          color: AppTheme.colorsOf(context).textMuted,
          fontSize: 12,
        ),
      ),
      const SizedBox(height: 6),
      SelectableText(
        value,
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.6,
        ),
      ),
    ],
  );
}

class _InstallDialog extends StatefulWidget {
  const _InstallDialog({required this.initialTool});
  final String initialTool;
  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  late String tool = widget.initialTool;
  final version = TextEditingController();
  @override
  void dispose() {
    version.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('安装到分类目录'),
    content: SizedBox(
      width: 460,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            initialValue: tool,
            items: [
              for (final t in toolchainNames.keys)
                DropdownMenuItem(value: t, child: Text(toolchainNames[t]!)),
            ],
            onChanged: (value) => setState(() => tool = value!),
            decoration: const InputDecoration(labelText: '工具'),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: version,
            decoration: const InputDecoration(
              labelText: '精确版本',
              hintText: '例如 3.47.7 / temurin-21.0.12.1+1',
            ),
          ),
          const SizedBox(height: 16),
          const Text('下一步会展示实际目录与命令。安装后由你选择是否切换默认版本。'),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, (tool, version.text.trim())),
        child: const Text('预览计划'),
      ),
    ],
  );
}
