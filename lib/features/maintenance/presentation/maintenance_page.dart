import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/maintenance/application/maintenance_provider.dart';
import 'package:mise_gui/features/storage/application/storage_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/shared/ui/action_preview_dialog.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';

class MaintenancePage extends ConsumerStatefulWidget {
  const MaintenancePage({super.key, this.initialTool});
  final String? initialTool;
  @override
  ConsumerState<MaintenancePage> createState() => _MaintenancePageState();
}

class _MaintenancePageState extends ConsumerState<MaintenancePage> {
  final target = TextEditingController(), search = TextEditingController();
  MaintenanceManager manager = MaintenanceManager.formula;
  String query = '';
  bool planning = false;
  bool flowOpen = false;
  String? message;
  @override
  void initState() {
    super.initState();
    _applyTool();
  }

  @override
  void didUpdateWidget(covariant MaintenancePage old) {
    super.didUpdateWidget(old);
    if (old.initialTool != widget.initialTool) _applyTool();
  }

  void _applyTool() {
    final id = widget.initialTool;
    if (id == null) return;
    if (['npm', 'pip', 'uv', 'go'].contains(id)) {
      manager = MaintenanceManager.cache;
      target.clear();
    } else if (['android-sdk', 'android-ndk', 'cmake', 'adb'].contains(id)) {
      manager = MaintenanceManager.android;
      target.clear();
    } else {
      manager = MaintenanceManager.formula;
      const apps = {
        'android-studio': 'android-studio',
        'bruno': 'bruno',
        'reqable': 'reqable',
        'vscode': 'visual-studio-code',
        'cursor': 'cursor',
        'idea': 'intellij-idea',
        'datagrip': 'datagrip',
        'jetbrains-toolbox': 'jetbrains-toolbox',
      };
      if (apps.containsKey(id)) manager = MaintenanceManager.cask;
      target.text = apps[id] ?? id;
    }
  }

  @override
  void dispose() {
    target.dispose();
    search.dispose();
    super.dispose();
  }

  Future<void> perform(MaintenanceRequest request) async {
    if (flowOpen || ref.read(taskCenterProvider).busy) return;
    flowOpen = true;
    setState(() {
      planning = true;
      message = null;
    });
    try {
      final service = ref.read(maintenanceServiceProvider);
      final plan = await service.prepare(request);
      if (!mounted) return;
      setState(() => planning = false);
      final confirmed = await showActionPreviewDialog(
        context,
        data: ActionPreviewDialogData(
          title: plan.title,
          summary:
              '${request.manager.label} · ${plan.beforeVersion?.isNotEmpty == true ? plan.beforeVersion : '未安装'}${plan.targetVersion == null ? '' : ' → ${plan.targetVersion}'}',
          command: plan.commands.map((c) => c.display).join('\n'),
          level: HealthLevel.warning,
          affectedFiles: plan.paths,
          impactScope: plan.notes,
          riskNotes: [
            if (plan.previewOutput.isNotEmpty) '原生预览：\n${plan.previewOutput}',
            '执行前会重新核对安装记录与路径；状态变化时需要重新预览。',
          ],
          confirmLabel: '确认${request.action.label} ${request.target}',
        ),
      );
      if (!confirmed || !mounted) return;
      if (!identical(service, ref.read(maintenanceServiceProvider))) {
        throw StateError('管理器设置已变化，请重新预览');
      }
      if (ref.read(taskCenterProvider).busy) {
        throw StateError('已有任务开始执行，请稍后重新预览');
      }
      final future = service.execute(plan);
      unawaited(
        future.then((_) {
          if (!mounted) return;
          ref.invalidate(maintenanceSnapshotProvider);
          ref.invalidate(localToolsProvider);
          ref.invalidate(classifiedVersionsProvider);
          ref.invalidate(directoryScanCancellationProvider);
        }, onError: (Object error, StackTrace stack) {}),
      );
      GoRouter.maybeOf(context)?.go('/tasks');
      await future;
    } catch (error) {
      if (mounted) setState(() => message = '$error');
    } finally {
      flowOpen = false;
      if (mounted) setState(() => planning = false);
    }
  }

  Widget packageCard(ManagedPackage p, bool busy) => AppPanel(
    key: ValueKey('maintenance-${p.key}'),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(p.id, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        Text('已安装 ${p.version}${p.pinned ? ' · 已固定' : ''}'),
        if (maintenanceRestriction(manager, MaintenanceAction.update, p.id) !=
            null)
          Text(
            maintenanceRestriction(manager, MaintenanceAction.update, p.id)!,
          ),
        if (p.location != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(p.location!),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed:
                  busy ||
                      p.pinned ||
                      maintenanceRestriction(
                            manager,
                            MaintenanceAction.update,
                            p.id,
                          ) !=
                          null
                  ? null
                  : () => perform(
                      MaintenanceRequest(
                        manager,
                        MaintenanceAction.update,
                        p.id,
                      ),
                    ),
              child: const Text('预览更新'),
            ),
            OutlinedButton(
              onPressed:
                  busy ||
                      p.pinned ||
                      maintenanceRestriction(
                            manager,
                            MaintenanceAction.uninstall,
                            p.id,
                          ) !=
                          null
                  ? null
                  : () => perform(
                      MaintenanceRequest(
                        manager,
                        MaintenanceAction.uninstall,
                        p.id,
                      ),
                    ),
              child: const Text('预览卸载'),
            ),
          ],
        ),
      ],
    ),
  );
  @override
  Widget build(BuildContext context) {
    final data = ref.watch(maintenanceSnapshotProvider);
    final busy = planning || ref.watch(taskCenterProvider).busy;
    return AppPageScaffold(
      title: '工具维护',
      description: '按实际管理器安装、更新、卸载与清理缓存',
      actions: [
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => ref.invalidate(maintenanceSnapshotProvider),
          icon: const Icon(Icons.refresh),
          label: const Text('刷新安装记录'),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Homebrew 和 Android SDK 使用原生安装记录。手动安装的软件保留原管理方式；运行时仍从 mise 版本管理安装或切换。',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  children: [
                    OutlinedButton(
                      onPressed: () => context.go('/tools'),
                      child: const Text('mise 版本管理'),
                    ),
                    OutlinedButton(
                      onPressed: () => context.go('/managers'),
                      child: const Text('管理器路径与选项'),
                    ),
                    OutlinedButton(
                      onPressed: () => context.go('/storage'),
                      child: const Text('查看目录占用'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Xcode 在 App Store / Xcode 中维护。链接式 mise SDK 的卸载会保留实际目录，本阶段继续保护已有运行时和共享 rustup。',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final m in MaintenanceManager.values)
                ChoiceChip(
                  label: Text(m.label),
                  selected: manager == m,
                  onSelected: busy ? null : (_) => setState(() => manager = m),
                ),
            ],
          ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: SelectableText(
                message!,
                style: const TextStyle(color: Colors.orange),
              ),
            ),
          if (planning)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 18),
          if (manager == MaintenanceManager.cache) ...[
            const Text(
              '仅开放原生管理器支持的四个缓存范围。不会整体删除 Maven、Gradle、Flutter、抓包或 IDE 数据。',
            ),
            const SizedBox(height: 14),
            for (final (id, description) in [
              ('npm', '包下载缓存，保留全局包'),
              ('pip', 'HTTP 与 wheel 缓存，保留虚拟环境'),
              ('uv', '下载与构建缓存，保留工具环境'),
              ('go', '编译缓存，保留模块缓存和 GOPATH'),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: AppPanel(
                  child: Wrap(
                    spacing: 20,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('$id · $description'),
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => perform(
                                MaintenanceRequest(
                                  manager,
                                  MaintenanceAction.clean,
                                  id,
                                ),
                              ),
                        icon: const Icon(Icons.cleaning_services_outlined),
                        label: Text('预览清理 $id'),
                      ),
                    ],
                  ),
                ),
              ),
          ] else ...[
            AppPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    manager == MaintenanceManager.android
                        ? '按完整 Android 包 ID 安装'
                        : '按 Homebrew 包名称安装',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: target,
                    enabled: !busy,
                    decoration: InputDecoration(
                      labelText: manager == MaintenanceManager.android
                          ? '例如 platforms;android-33 或 ndk;28.2.13676358'
                          : '例如 gh、wget 或 android-studio',
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => perform(
                            MaintenanceRequest(
                              manager,
                              MaintenanceAction.install,
                              target.text.trim(),
                            ),
                          ),
                    icon: const Icon(Icons.add),
                    label: const Text('预览安装'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: search,
              onChanged: (s) => setState(() => query = s),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                labelText: '筛选已安装的包',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            data.when(
              loading: () => const AppPanel(child: Text('读取本机安装记录…')),
              error: (e, _) => AppPanel(child: Text('安装记录读取失败：$e')),
              data: (snapshot) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final warning in snapshot.warnings)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        warning,
                        style: const TextStyle(color: Colors.orange),
                      ),
                    ),
                  Text(
                    '${snapshot.packages.where((p) => p.manager == manager).length} 个安装记录 · 版本来源于本机管理器元数据',
                  ),
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (context, c) => Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        for (final p in snapshot.packages.where(
                          (p) =>
                              p.manager == manager &&
                              p.id.toLowerCase().contains(query.toLowerCase()),
                        ))
                          SizedBox(
                            width: c.maxWidth >= 1000
                                ? (c.maxWidth - 12) / 2
                                : c.maxWidth,
                            child: packageCard(p, busy),
                          ),
                      ],
                    ),
                  ),
                  if (!snapshot.packages.any((p) => p.manager == manager))
                    const AppPanel(child: Text('当前管理器没有可显示的安装记录。')),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
