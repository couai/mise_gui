import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/shared/ui/tool_logo.dart';

/// The accordion and the local workbench share the same resolved mise inventory.
class ClassifiedVersionInfo extends ConsumerWidget {
  const ClassifiedVersionInfo({
    super.key,
    required this.tool,
    required this.version,
  });
  final String tool, version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ToolchainLayout.categories.containsKey(tool)) {
      return const Text('该工具尚未接入分类目录策略。');
    }
    final colors = AppTheme.colorsOf(context);
    return ref
        .watch(classifiedVersionsProvider)
        .when(
          loading: () => Text(
            '正在读取实际目录…',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          error: (_, _) => Row(
            children: [
              const Expanded(child: Text('实际目录暂不可用；可重新读取。')),
              TextButton(
                onPressed: () => ref.invalidate(classifiedVersionsProvider),
                child: const Text('重读目录'),
              ),
            ],
          ),
          data: (entries) {
            final entry = entries
                .where((v) => v.tool == tool && v.version == version)
                .firstOrNull;
            if (entry == null) {
              return const Text(
                '尚未取得此版本的实际目录，请刷新状态。',
                style: TextStyle(fontSize: 12),
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Path(
                  label: tool == 'rust' ? '共享代理位置' : 'SDK 实际位置',
                  path: entry.actualPath,
                ),
                if (entry.rustSdkPath != null)
                  _Path(label: 'rustup 工具链位置', path: entry.rustSdkPath!),
                Wrap(
                  spacing: 14,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.classified ? '已符合分类目录规范' : '目录需要检查',
                      style: TextStyle(
                        fontSize: 12,
                        color: entry.classified
                            ? colors.accent
                            : colors.warning,
                      ),
                    ),
                    if (entry.dartVersion != null)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const ToolLogo(tool: 'dart', size: 16),
                          const SizedBox(width: 6),
                          Text(
                            '配套 Dart ${entry.dartVersion}',
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                  ],
                ),
                Material(
                  type: MaterialType.transparency,
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('注册与配置', style: TextStyle(fontSize: 12)),
                    children: [
                      _Path(label: 'mise 注册路径', path: entry.registeredPath),
                      if (entry.sourcePath != null)
                        _Path(label: '全局配置来源', path: entry.sourcePath!),
                    ],
                  ),
                ),
                if (tool == 'rust')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Rust 版本共享 cargo/bin 代理，真实 SDK 由 rustup 管理。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                if (tool == 'flutter')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Dart 随 Flutter SDK 配套切换。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            );
          },
        );
  }
}

class _Path extends ConsumerWidget {
  const _Path({required this.label, required this.path});
  final String label, path;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: AppTheme.colorsOf(context).textMuted,
                  fontSize: 12,
                ),
              ),
            ),
            IconButton(
              tooltip: '复制$label',
              visualDensity: VisualDensity.compact,
              onPressed: () => Clipboard.setData(ClipboardData(text: path)),
              icon: const Icon(Icons.copy_outlined, size: 15),
            ),
            IconButton(
              tooltip: '打开$label',
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                try {
                  await ref.read(localToolOpenerProvider).open(path);
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text('打开失败：$error')));
                  }
                }
              },
              icon: const Icon(Icons.folder_open_outlined, size: 16),
            ),
          ],
        ),
        SelectableText(
          path,
          style: const TextStyle(
            fontFamily: 'FiraCode',
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ],
    ),
  );
}
