import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/storage/application/storage_provider.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';

class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key, this.initialTool});
  final String? initialTool;
  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  final search = TextEditingController();
  final listScroll = ScrollController();
  String query = '';
  String? selectedPath, toolFilter;
  ToolLocationKind? kind;
  bool issuesOnly = false, linksOnly = false, showMissing = false;
  @override
  void initState() {
    super.initState();
    toolFilter = widget.initialTool;
  }

  @override
  void didUpdateWidget(covariant StoragePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTool != widget.initialTool) {
      toolFilter = widget.initialTool;
      kind = null;
      query = '';
      search.clear();
      issuesOnly = linksOnly = showMissing = false;
      selectedPath = null;
    }
  }

  @override
  void dispose() {
    search.dispose();
    listScroll.dispose();
    super.dispose();
  }

  void refresh() {
    ref.invalidate(localToolsProvider);
    ref.invalidate(directoryScanCancellationProvider);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(directoryStorageProvider);
    final scanning = state.isLoading || state.valueOrNull?.scanning == true;
    return AppPageScaffold(
      title: '目录与缓存',
      description: '真实占用、目录归属、软链接与分类规范',
      actions: [
        if (scanning)
          OutlinedButton.icon(
            onPressed: () =>
                ref.read(directoryScanCancellationProvider).cancel(),
            icon: const Icon(Icons.stop_circle_outlined),
            label: const Text('停止扫描'),
          ),
        OutlinedButton.icon(
          onPressed: scanning ? null : refresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新扫描目录'),
        ),
      ],
      child: state.when(
        loading: () => const AppPanel(
          child: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 14),
              Expanded(child: Text('正在整理工具目录和软链接…')),
            ],
          ),
        ),
        error: (_, _) => AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('目录清单暂不可用，请检查本地读取权限。'),
              TextButton(onPressed: refresh, child: const Text('重试目录扫描')),
            ],
          ),
        ),
        data: content,
      ),
    );
  }

  Widget content(StorageSnapshot data) {
    final colors = AppTheme.colorsOf(context);
    final visible =
        data.entries
            .where(
              (e) =>
                  e.matches(query) &&
                  (kind == null || e.kinds.contains(kind)) &&
                  (!issuesOnly || e.needsReview) &&
                  (!linksOnly || e.links.isNotEmpty) &&
                  (showMissing || e.linkState != StorageLinkState.missing) &&
                  (toolFilter == null ||
                      e.owners.any((o) => o.id == toolFilter)),
            )
            .toList()
          ..sort(
            (a, b) => (b.usage.bytes ?? -1).compareTo(a.usage.bytes ?? -1) != 0
                ? (b.usage.bytes ?? -1).compareTo(a.usage.bytes ?? -1)
                : a.path.compareTo(b.path),
          );
    final selected =
        visible.where((e) => e.path == selectedPath).firstOrNull ??
        visible.firstOrNull;
    final hasSize = data.roots.any((e) => e.usage.bytes != null);
    final hasCache = data.entries.any(
      (e) => e.kinds.contains(ToolLocationKind.cache) && e.usage.bytes != null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, c) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (label, value) in [
                (
                  '已测目录占用',
                  hasSize
                      ? '${data.complete ? '' : '≥ '}${formatStorageBytes(data.measuredBytes)}'
                      : '待测量',
                ),
                (
                  '已测缓存占用',
                  hasCache ? formatStorageBytes(data.cacheBytes) : '待测量',
                ),
                ('待检查路径', '${data.entries.where((e) => e.needsReview).length}'),
                (
                  '含软链接路径',
                  '${data.entries.where((e) => e.links.isNotEmpty).length}',
                ),
              ])
                SizedBox(
                  width:
                      (c.maxWidth -
                          (c.maxWidth >= 800
                                  ? 3
                                  : c.maxWidth >= 400
                                  ? 1
                                  : 0) *
                              12) /
                      (c.maxWidth >= 800
                          ? 4
                          : c.maxWidth >= 400
                          ? 2
                          : 1),
                  child: AppPanel(
                    padding: const EdgeInsets.all(18),
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
                          value,
                          style: const TextStyle(
                            fontSize: 23,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        if (data.scanning) ...[
          LinearProgressIndicator(
            value: data.total == 0 ? null : data.completed / data.total,
          ),
          const SizedBox(height: 8),
        ],
        Text(
          '${data.scanning
              ? '正在测量'
              : data.cancelled
              ? '已停止，保留已测结果'
              : '扫描完成'} · ${data.completed}/${data.total} 个实际目标 · ${data.scannedAt.toLocal().toString().split('.').first}',
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        Text(
          '汇总覆盖全部登记路径，不随列表筛选变化。占用采用文件系统报告的已分配空间，排除父子路径和相同软链接目标。未测、部分可读与超时单独标记；内部链接和跨文件系统挂载不递归统计。缓存占用是目录占用的一部分。',
          style: TextStyle(color: colors.textMuted, height: 1.5, fontSize: 12),
        ),
        Text(
          'APFS 克隆及不同根目录间的硬链接可能共享磁盘块；这些数值不等于删除后可释放空间。',
          style: TextStyle(color: colors.textMuted, height: 1.5, fontSize: 11),
        ),
        for (final warning in data.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              warning,
              style: TextStyle(color: colors.warning, fontSize: 12),
            ),
          ),
        const SizedBox(height: 20),
        TextField(
          controller: search,
          onChanged: (v) => setState(() => query = v),
          decoration: InputDecoration(
            hintText: '搜索工具、归属或路径',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: query.isEmpty
                ? null
                : IconButton(
                    onPressed: () => setState(() {
                      query = '';
                      search.clear();
                    }),
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final value in [null, ...ToolLocationKind.values])
              ChoiceChip(
                label: Text(value?.label ?? '全部类型'),
                selected: kind == value,
                onSelected: (_) => setState(() => kind = value),
              ),
            FilterChip(
              label: const Text('仅待检查'),
              selected: issuesOnly,
              onSelected: (v) => setState(() => issuesOnly = v),
            ),
            FilterChip(
              label: const Text('仅含软链接'),
              selected: linksOnly,
              onSelected: (v) => setState(() => linksOnly = v),
            ),
            FilterChip(
              label: const Text('显示未找到项'),
              selected: showMissing,
              onSelected: (v) => setState(() => showMissing = v),
            ),
            if (toolFilter != null)
              InputChip(
                label: Text(
                  '工具：${data.entries.expand((e) => e.owners).where((o) => o.id == toolFilter).firstOrNull?.name ?? toolFilter}',
                ),
                onDeleted: () => setState(() => toolFilter = null),
              ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '${visible.length} 个路径 · 按已测占用排序',
          style: TextStyle(color: colors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, c) {
            final height = (MediaQuery.sizeOf(context).height - 380).clamp(
              450.0,
              780.0,
            );
            final list = AppPanel(
              padding: const EdgeInsets.all(10),
              child: visible.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('没有匹配的目录，可调整筛选条件。'),
                    )
                  : SizedBox(
                      height: height,
                      child: Scrollbar(
                        controller: listScroll,
                        thumbVisibility: true,
                        child: ListView.builder(
                          controller: listScroll,
                          itemCount: visible.length,
                          itemExtent: 112,
                          itemBuilder: (context, i) {
                            final e = visible[i];
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Material(
                                color: selected?.path == e.path
                                    ? colors.accent.withValues(alpha: .1)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(12),
                                child: InkWell(
                                  key: ValueKey('storage-row-${e.path}'),
                                  borderRadius: BorderRadius.circular(12),
                                  onTap: () =>
                                      setState(() => selectedPath = e.path),
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                e.owners
                                                    .map((o) => o.name)
                                                    .toSet()
                                                    .join(' / '),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Text(
                                              e.usage.bytes == null
                                                  ? e.usage.label
                                                  : '${e.usage.state == StorageUsageState.partial ? '≥ ' : ''}${formatStorageBytes(e.usage.bytes!)}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: colors.info,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          e.path,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: colors.textMuted,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          '${e.compliance.label} · ${e.linkState.label}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: e.needsReview
                                                ? colors.warning
                                                : colors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
            );
            final detail = selected == null
                ? null
                : _StorageDetail(
                    key: ValueKey(selected.path),
                    entry: selected,
                    height: c.maxWidth >= 850 ? height + 20 : null,
                  );
            if (c.maxWidth >= 850) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 5, child: list),
                  const SizedBox(width: 18),
                  Expanded(
                    flex: 6,
                    child: detail ?? const AppPanel(child: Text('选择目录查看详情')),
                  ),
                ],
              );
            }
            return Column(
              children: [
                list,
                if (detail != null) ...[const SizedBox(height: 16), detail],
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StorageDetail extends ConsumerStatefulWidget {
  const _StorageDetail({super.key, required this.entry, this.height});
  final StorageEntry entry;
  final double? height;
  @override
  ConsumerState<_StorageDetail> createState() => _StorageDetailState();
}

class _StorageDetailState extends ConsumerState<_StorageDetail> {
  final scroll = ScrollController();
  bool opening = false;
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  Future<void> open(String path) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await ref
          .read(localToolOpenerProvider)
          .open(path.endsWith('.app') ? Directory(path).parent.path : path);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开失败：$error')));
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final colors = AppTheme.colorsOf(context);
    final panel = AppPanel(
      key: ValueKey('storage-detail-${e.path}'),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('目录档案', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          SelectableText(
            e.path,
            style: const TextStyle(fontSize: 13, height: 1.6),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: opening || !e.exists ? null : () => open(e.path),
                icon: const Icon(Icons.folder_open, size: 17),
                label: const Text('打开所在位置'),
              ),
              OutlinedButton(
                onPressed: opening
                    ? null
                    : () => open(Directory(e.path).parent.path),
                child: const Text('打开父目录'),
              ),
              IconButton(
                tooltip: '复制目录路径',
                onPressed: () => Clipboard.setData(ClipboardData(text: e.path)),
                icon: const Icon(Icons.copy_outlined, size: 17),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Text(
            e.usage.bytes == null
                ? e.usage.label
                : '${e.usage.state == StorageUsageState.partial ? '≥ ' : ''}${formatStorageBytes(e.usage.bytes!)}',
            style: TextStyle(
              fontSize: 25,
              color: colors.info,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            e.usage.label,
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
          if (e.usage.note.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                e.usage.note,
                style: TextStyle(color: colors.warning, fontSize: 12),
              ),
            ),
          if (e.exists && e.usage.state != StorageUsageState.skipped)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                e.coveredBy == null
                    ? '此目标作为独立根目录参与汇总。'
                    : '由 ${e.coveredBy} 涵盖，汇总不重复累加。',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11,
                  height: 1.5,
                ),
              ),
            ),
          const SizedBox(height: 22),
          const Divider(),
          const SizedBox(height: 12),
          Text('目录归属', style: Theme.of(context).textTheme.titleSmall),
          for (final o in e.owners)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${o.name} · ${o.label}\n${o.kind.label}',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                  ),
                  if (!const [
                    'shared',
                    'unassigned',
                    'devworkbench',
                    'typescript',
                  ].contains(o.id))
                    IconButton(
                      tooltip: '查看${o.name}工具档案',
                      onPressed: () => context.go(
                        Uri(
                          path: '/local-tools',
                          queryParameters: {'tool': o.id},
                        ).toString(),
                      ),
                      icon: const Icon(Icons.arrow_forward, size: 17),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 20),
          Text(
            '路径规范 · ${e.compliance.label}',
            style: TextStyle(
              color: e.compliance.needsReview ? colors.warning : colors.accent,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            e.policyNote,
            style: TextStyle(
              color: colors.textMuted,
              fontSize: 12,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            '链接状态 · ${e.linkState.label}',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          if (e.canonicalPath != null) ...[
            const SizedBox(height: 8),
            const Text('实际路径', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            SelectableText(
              e.canonicalPath!,
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 12,
                height: 1.6,
              ),
            ),
            if (e.exists && e.canonicalPath != e.path)
              TextButton(
                onPressed: opening ? null : () => open(e.canonicalPath!),
                child: const Text('打开实际目标'),
              ),
          ],
          for (final hop in e.links)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(
                '${hop.path}\n→ ${hop.target}',
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 11,
                  height: 1.6,
                ),
              ),
            ),
        ],
      ),
    );
    if (widget.height == null) return panel;
    return SizedBox(
      height: widget.height,
      child: Scrollbar(
        controller: scroll,
        thumbVisibility: true,
        child: SingleChildScrollView(controller: scroll, child: panel),
      ),
    );
  }
}
