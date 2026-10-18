import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';
import 'package:mise_gui/shared/ui/tool_logo.dart';

class LocalEnvironmentOverview extends ConsumerWidget {
  const LocalEnvironmentOverview({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(localToolsProvider)
        .when(
          loading: () => const AppPanel(
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 14),
                Expanded(child: Text('正在汇总本机开发工具…')),
              ],
            ),
          ),
          error: (_, _) => AppPanel(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('本地工具清单暂不可用。'),
                TextButton(
                  onPressed: () => ref.invalidate(localToolsProvider),
                  child: const Text('重新扫描工具'),
                ),
              ],
            ),
          ),
          data: (snapshot) => _Overview(snapshot: snapshot),
        );
  }
}

class _Overview extends StatelessWidget {
  const _Overview({required this.snapshot});
  final LocalToolSnapshot snapshot;
  void open(BuildContext context, [Map<String, String> filters = const {}]) =>
      context.go(
        Uri(
          path: '/local-tools',
          queryParameters: filters.isEmpty ? null : filters,
        ).toString(),
      );

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    final ready = snapshot.tools
        .where((t) => t.status == LocalToolStatus.ready)
        .length;
    final managers = <String, int>{};
    for (final tool in snapshot.tools.where((t) => t.installed)) {
      managers.update(tool.manager, (n) => n + 1, ifAbsent: () => 1);
    }
    final attention = snapshot.tools
        .where(
          (t) =>
              t.status == LocalToolStatus.attention ||
              t.status == LocalToolStatus.unavailable,
        )
        .toList();
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 14,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('本地开发工具', style: Theme.of(context).textTheme.titleLarge),
              Text(
                '扫描于 ${snapshot.scannedAt.toLocal().toString().split('.').first}',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              OutlinedButton(
                onPressed: () => open(context),
                child: const Text('打开工具工作台'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 800
                  ? 4
                  : constraints.maxWidth >= 420
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final (id, label, count, caption, filter) in [
                    (
                      'installed',
                      '已识别工具',
                      snapshot.installedCount,
                      '应用与 CLI 按工具合并统计',
                      const <String, String>{},
                    ),
                    (
                      'ready',
                      '可用',
                      ready,
                      '已找到安装证据',
                      const <String, String>{'status': 'ready'},
                    ),
                    (
                      'attention',
                      '需检查',
                      snapshot.attentionCount,
                      '版本检查失败或安装证据异常',
                      const <String, String>{'status': 'attention'},
                    ),
                    (
                      'missing',
                      '未检测到',
                      snapshot.missingCount,
                      '识别清单未命中，不代表必须安装',
                      const <String, String>{'status': 'missing'},
                    ),
                  ])
                    SizedBox(
                      width: width,
                      child: Material(
                        color: colors.background.withValues(alpha: .45),
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          key: ValueKey('overview-$id'),
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => open(context, filter),
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: colors.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  '$count',
                                  style: TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w600,
                                    color: id == 'attention' && count > 0
                                        ? colors.warning
                                        : colors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  caption,
                                  style: TextStyle(
                                    fontSize: 11,
                                    height: 1.5,
                                    color: colors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 870
                  ? 3
                  : constraints.maxWidth >= 500
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * 12) / columns;
              return Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final c in LocalToolCategory.values)
                    SizedBox(
                      width: width,
                      child: OutlinedButton(
                        key: ValueKey('overview-category-${c.name}'),
                        onPressed: () => open(context, {'category': c.name}),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                        ),
                        child: Row(
                          children: [
                            ToolLogo(
                              tool: const {
                                LocalToolCategory.runtime: 'java',
                                LocalToolCategory.build: 'maven',
                                LocalToolCategory.mobile: 'android-studio',
                                LocalToolCategory.network: 'bruno',
                                LocalToolCategory.editor: 'vscode',
                                LocalToolCategory.utility: 'gh',
                              }[c]!,
                              size: 28,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    c.label,
                                    style: TextStyle(
                                      color: colors.textPrimary,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${snapshot.tools.where((t) => t.category == c && t.installed).length} 个已识别',
                                    style: TextStyle(
                                      color: colors.textMuted,
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(Icons.chevron_right, size: 16),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final manager in managers.entries)
                Chip(
                  label: Text(
                    '${manager.key} · ${manager.value}',
                    style: const TextStyle(fontSize: 11),
                  ),
                ),
            ],
          ),
          if (attention.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('需要检查', style: TextStyle(color: colors.warning, fontSize: 13)),
            for (final tool in attention.take(5))
              TextButton(
                onPressed: () => open(context, {'tool': tool.id}),
                child: Text(
                  '${tool.name} · ${tool.notes.firstOrNull ?? tool.statusLabel}',
                ),
              ),
          ],
          for (final warning in snapshot.warnings)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                warning,
                style: TextStyle(color: colors.warning, fontSize: 12),
              ),
            ),
          const SizedBox(height: 12),
          Text(
            '共 ${snapshot.tools.length} 个识别目录项，含 ${snapshot.tools.where((t) => t.imported).length} 个手动导入工具；数据与工具工作台共用同一份本地清单。',
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}
