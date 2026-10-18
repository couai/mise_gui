import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/local_tools/presentation/import_tool_dialog.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';
import 'package:mise_gui/shared/ui/tool_logo.dart';

class LocalToolsPage extends ConsumerStatefulWidget {
  const LocalToolsPage({
    super.key,
    this.initialTool,
    this.initialCategory,
    this.initialStatus,
  });
  final String? initialTool, initialCategory, initialStatus;
  @override
  ConsumerState<LocalToolsPage> createState() => _LocalToolsPageState();
}

class _LocalToolsPageState extends ConsumerState<LocalToolsPage> {
  LocalToolCategory? category;
  String query = '';
  String? selectedId;
  bool installedOnly = true;
  String? status;
  final search = TextEditingController();
  final catalogScroll = ScrollController();
  String? _lastScrolledSelection;

  @override
  void initState() {
    super.initState();
    _applyRoute();
  }

  @override
  void didUpdateWidget(covariant LocalToolsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTool != widget.initialTool ||
        oldWidget.initialCategory != widget.initialCategory ||
        oldWidget.initialStatus != widget.initialStatus) {
      _applyRoute();
    }
  }

  void _applyRoute() {
    selectedId = widget.initialTool;
    category = LocalToolCategory.values
        .where((c) => c.name == widget.initialCategory)
        .firstOrNull;
    status =
        const ['attention', 'missing', 'ready'].contains(widget.initialStatus)
        ? widget.initialStatus
        : null;
    query = '';
    search.clear();
    installedOnly = status != 'missing' && selectedId == null;
  }

  Future<void> importTool() async {
    final tools = ref.read(localToolsProvider).valueOrNull?.tools;
    if (tools == null) return;
    final id = await showDialog<String>(
      context: context,
      builder: (_) => ImportToolDialog(knownTools: tools),
    );
    if (!mounted || id == null) return;
    selectTool(id);
    ref.invalidate(localToolsProvider);
  }

  void selectTool(String id) {
    setState(() {
      selectedId = id;
      category = null;
      status = null;
      installedOnly = false;
      query = '';
      search.clear();
    });
    _syncRoute();
  }

  void _syncRoute() {
    GoRouter.maybeOf(context)?.go(
      Uri(
        path: '/local-tools',
        queryParameters: {
          if (selectedId != null) 'tool': selectedId!,
          if (category != null) 'category': category!.name,
          if (status != null) 'status': status!,
        },
      ).toString(),
    );
  }

  bool _visible(LocalTool t, {LocalToolCategory? inCategory}) =>
      (inCategory == null || t.category == inCategory) &&
      (status == null ||
          (status == 'attention' &&
              (t.status == LocalToolStatus.attention ||
                  t.status == LocalToolStatus.unavailable)) ||
          (status == 'missing' && t.status == LocalToolStatus.missing) ||
          (status == 'ready' && t.status == LocalToolStatus.ready)) &&
      (!installedOnly ||
          t.installed ||
          t.imported ||
          t.status == LocalToolStatus.unavailable);

  @override
  void dispose() {
    search.dispose();
    catalogScroll.dispose();
    super.dispose();
  }

  void refresh() {
    ref.invalidate(localToolsProvider);
    ref.invalidate(classifiedVersionsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(localToolsProvider);
    return AppPageScaffold(
      title: '开发工具',
      description: '本地工具工作台 · 识别、分类、查看详情与快速打开',
      actions: [
        OutlinedButton.icon(
          onPressed: () => context.go(
            Uri(
              path: '/maintenance',
              queryParameters: {if (selectedId != null) 'tool': selectedId!},
            ).toString(),
          ),
          icon: const Icon(Icons.build_outlined),
          label: const Text('安装与维护'),
        ),
        FilledButton.icon(
          onPressed: snapshot.hasValue && !snapshot.isLoading
              ? importTool
              : null,
          icon: const Icon(Icons.add_rounded),
          label: const Text('导入已有工具'),
        ),
        OutlinedButton.icon(
          onPressed: snapshot.isLoading ? null : refresh,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重新扫描'),
        ),
      ],
      child: snapshot.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(48),
          child: Center(
            child: Column(
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 20),
                Text('正在检查本地工具…'),
              ],
            ),
          ),
        ),
        error: (_, _) => AppPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('工具识别失败，请检查本地目录权限后重试。'),
              TextButton(onPressed: refresh, child: const Text('重试')),
            ],
          ),
        ),
        data: (data) => _content(data),
      ),
    );
  }

  Widget _content(LocalToolSnapshot snapshot) {
    final colors = AppTheme.colorsOf(context);
    final installed = snapshot.tools.where((t) => t.installed).length;
    final visible = snapshot.tools
        .where((t) => _visible(t, inCategory: category) && t.matches(query))
        .toList();
    final selected =
        visible.where((t) => t.id == selectedId).firstOrNull ??
        visible.firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _tag('$installed 个已识别工具', colors.accent),
            _tag('${snapshot.miseCount} 个由 mise 管理 / 配套', colors.info),
            Text(
              '本地扫描 ${_time(snapshot.scannedAt)}',
              style: TextStyle(color: colors.textMuted, fontSize: 12),
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (status != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: InputChip(
              label: Text(
                status == 'attention'
                    ? '需检查的工具'
                    : status == 'ready'
                    ? '可用的工具'
                    : '未检测到的目录项',
              ),
              onDeleted: () {
                setState(() => status = null);
                _syncRoute();
              },
            ),
          ),
        Row(
          children: [
            Icon(Icons.folder_outlined, size: 16, color: colors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                ToolchainLayout.current.root,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
          ],
        ),
        for (final warning in snapshot.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(warning, style: TextStyle(color: colors.warning)),
          ),
        const SizedBox(height: 22),
        LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;
            final categories = _categories(snapshot);
            final paneHeight = (MediaQuery.sizeOf(context).height - 340).clamp(
              420.0,
              760.0,
            );
            final catalog = _catalog(visible, selected, paneHeight - 174);
            final details = selected == null
                ? null
                : _ToolDetail(
                    key: ValueKey('selected-${selected.id}'),
                    tool: selected,
                    snapshot: snapshot,
                    onSelect: selectTool,
                    height: constraints.maxWidth >= 690 ? paneHeight : null,
                  );
            if (wide) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 166, child: categories),
                  const SizedBox(width: 16),
                  Expanded(flex: 5, child: catalog),
                  const SizedBox(width: 18),
                  Expanded(
                    flex: 6,
                    child: details ?? const AppPanel(child: Text('选择工具查看详情')),
                  ),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                categories,
                const SizedBox(height: 16),
                if (constraints.maxWidth >= 690)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: catalog),
                      const SizedBox(width: 16),
                      Expanded(
                        child:
                            details ?? const AppPanel(child: Text('选择工具查看详情')),
                      ),
                    ],
                  )
                else ...[
                  catalog,
                  if (details != null) ...[const SizedBox(height: 18), details],
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _categories(LocalToolSnapshot snapshot) {
    final colors = AppTheme.colorsOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('工具分类', style: TextStyle(color: colors.textMuted, fontSize: 12)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final c in [null, ...LocalToolCategory.values])
              ChoiceChip(
                label: Text(
                  '${c?.label ?? '全部工具'}  ${snapshot.tools.where((t) => _visible(t, inCategory: c)).length}',
                ),
                selected: category == c,
                onSelected: (_) {
                  setState(() {
                    category = c;
                    selectedId = null;
                  });
                  _syncRoute();
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _catalog(
    List<LocalTool> visible,
    LocalTool? selected,
    double listHeight,
  ) {
    final colors = AppTheme.colorsOf(context);
    final itemExtent = 88.0 * MediaQuery.textScalerOf(context).scale(1);
    final index = visible.indexWhere((t) => t.id == selected?.id);
    final selection = '${selected?.id}:$index:${visible.length}';
    if (selectedId != null &&
        index >= 0 &&
        _lastScrolledSelection != selection) {
      _lastScrolledSelection = selection;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !catalogScroll.hasClients ||
            _lastScrolledSelection != selection) {
          return;
        }
        final position = catalogScroll.position;
        final start = index * itemExtent;
        final end = start + itemExtent;
        final target = start < position.pixels
            ? start
            : end > position.pixels + position.viewportDimension
            ? end - position.viewportDimension
            : position.pixels;
        catalogScroll.jumpTo(target.clamp(0, position.maxScrollExtent));
      });
    }
    return AppPanel(
      padding: const EdgeInsets.all(14),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: search,
            onChanged: (v) => setState(() => query = v),
            decoration: InputDecoration(
              hintText: '搜索工具、目录或管理方式',
              prefixIcon: const Icon(Icons.search, size: 20),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      onPressed: () {
                        search.clear();
                        setState(() => query = '');
                      },
                      icon: const Icon(Icons.close, size: 18),
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${visible.length} 个工具',
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              const Spacer(),
              const Text('已安装或登记', style: TextStyle(fontSize: 12)),
              const SizedBox(width: 6),
              Switch(
                value: installedOnly,
                onChanged: (v) => setState(() => installedOnly = v),
              ),
            ],
          ),
          const Divider(),
          if (visible.isEmpty)
            const Padding(
              padding: EdgeInsets.all(22),
              child: Text('没有匹配的本地工具。可清除搜索或显示未检测到的工具。'),
            ),
          if (visible.isNotEmpty)
            SizedBox(
              height: listHeight,
              child: Scrollbar(
                controller: catalogScroll,
                thumbVisibility: true,
                child: ListView(
                  controller: catalogScroll,
                  itemExtent: itemExtent,
                  padding: EdgeInsets.zero,
                  children: [
                    for (final tool in visible)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Material(
                          color: selected?.id == tool.id
                              ? colors.accent.withValues(alpha: .10)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            key: ValueKey('local-tool-${tool.id}'),
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              setState(() => selectedId = tool.id);
                              _syncRoute();
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 13,
                              ),
                              child: Row(
                                children: [
                                  ToolLogo(tool: tool.id, size: 30),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          tool.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          tool.version ??
                                              (tool.versions.isEmpty
                                                  ? tool.statusLabel
                                                  : '${tool.versions.length} 个版本'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: colors.textMuted,
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Tooltip(
                                    message: tool.statusLabel,
                                    child: Icon(
                                      tool.status == LocalToolStatus.ready
                                          ? Icons.check_circle_outline
                                          : Icons.info_outline,
                                      size: 16,
                                      color:
                                          tool.status == LocalToolStatus.ready
                                          ? colors.accent
                                          : colors.warning,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tag(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(label, style: TextStyle(color: color, fontSize: 12)),
  );
  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _ToolDetail extends ConsumerStatefulWidget {
  const _ToolDetail({
    super.key,
    required this.tool,
    required this.snapshot,
    required this.onSelect,
    this.height,
  });
  final LocalToolSnapshot snapshot;
  final ValueChanged<String> onSelect;
  final LocalTool tool;
  final double? height;
  @override
  ConsumerState<_ToolDetail> createState() => _ToolDetailState();
}

class _ToolDetailState extends ConsumerState<_ToolDetail> {
  bool opening = false;
  final detailScroll = ScrollController();
  @override
  void dispose() {
    detailScroll.dispose();
    super.dispose();
  }

  Future<void> open(ToolLocation location) async {
    if (opening) return;
    setState(() => opening = true);
    try {
      await ref
          .read(localToolOpenerProvider)
          .open(location.path, application: location.application);
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

  Future<void> forget() async {
    setState(() => opening = true);
    try {
      await ref.read(localToolRegistryProvider).forget(widget.tool.id);
      if (mounted) ref.invalidate(localToolsProvider);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('移除登记失败：$error')));
      }
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  Widget relationRow(LocalToolRelation relation) {
    final target = widget.snapshot.tool(relation.toolId);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  target?.name ?? relation.toolId,
                  style: const TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  '${relation.reason} · ${target?.statusLabel ?? '未纳入清单'}',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: AppTheme.colorsOf(context).textMuted,
                  ),
                ),
              ],
            ),
          ),
          if (target != null)
            IconButton(
              tooltip: '查看${target.name}档案',
              onPressed: () => widget.onSelect(target.id),
              icon: const Icon(Icons.arrow_forward_rounded, size: 17),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tool;
    final colors = AppTheme.colorsOf(context);
    final app = t.locations.where((p) => p.application && p.exists).firstOrNull;
    final panel = AppPanel(
      key: ValueKey('detail-${t.id}'),
      padding: const EdgeInsets.all(22),
      radius: 16,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ToolLogo(tool: t.id, size: 44),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.name, style: Theme.of(context).textTheme.titleLarge),
                    const SizedBox(height: 5),
                    Text(
                      t.category.label,
                      style: TextStyle(color: colors.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            t.description,
            style: TextStyle(color: colors.textMuted, height: 1.6),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (app != null)
                FilledButton.icon(
                  onPressed: opening ? null : () => open(app),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('打开应用'),
                ),
              if (t.miseTool != null && t.versions.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: () => context.go('/tools?tool=${t.miseTool}'),
                  icon: const Icon(Icons.swap_horiz, size: 17),
                  label: const Text('版本管理'),
                ),
              if (app == null && t.locations.any((p) => p.exists))
                OutlinedButton.icon(
                  onPressed: opening
                      ? null
                      : () => open(
                          t.locations.firstWhere(
                            (p) => p.exists && !p.application,
                          ),
                        ),
                  icon: const Icon(Icons.folder_open, size: 17),
                  label: const Text('打开所在位置'),
                ),
            ],
          ),
          const SizedBox(height: 22),
          const Divider(),
          const SizedBox(height: 12),
          _fact('状态', t.statusLabel),
          _fact(
            '当前版本',
            t.version ?? (t.versions.isNotEmpty ? '未设置全局默认' : '未取得'),
          ),
          _fact('管理方式', t.manager),
          _fact('来源', t.source),
          TextButton.icon(
            onPressed: () => context.go(
              Uri(path: '/storage', queryParameters: {'tool': t.id}).toString(),
            ),
            icon: const Icon(Icons.storage_outlined, size: 17),
            label: const Text('查看目录占用与链接'),
          ),
          if (t.imported)
            TextButton.icon(
              onPressed: opening ? null : forget,
              icon: const Icon(Icons.remove_circle_outline, size: 16),
              label: const Text('移除登记（保留程序和数据）'),
            ),
          if (t.relations.isNotEmpty ||
              widget.snapshot.tools.any(
                (other) =>
                    other.relations.any((r) => r.toolId == t.id) &&
                    !t.relations.any((r) => r.toolId == other.id),
              )) ...[
            const SizedBox(height: 16),
            Text('依赖与关联', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final relation in t.relations) relationRow(relation),
            for (final other in widget.snapshot.tools.where(
              (other) =>
                  other.relations.any((r) => r.toolId == t.id) &&
                  !t.relations.any((r) => r.toolId == other.id),
            ))
              relationRow(
                LocalToolRelation(
                  other.id,
                  '关联此工具 · ${other.relations.firstWhere((r) => r.toolId == t.id).reason}',
                ),
              ),
          ],
          if (t.versions.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('已安装版本', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 10),
            for (final v in t.versions)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Icon(
                      v.active
                          ? Icons.radio_button_checked
                          : Icons.circle_outlined,
                      size: 14,
                      color: v.active ? colors.accent : colors.textMuted,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${v.version}${v.active ? ' · 全局默认' : ''}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 18),
          Text('目录档案', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          if (t.locations.isEmpty) const Text('尚无可打开的本地路径。'),
          for (final kind in ToolLocationKind.values.where(
            (kind) => t.locations.any((p) => p.kind == kind),
          )) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 6),
              child: Text(
                kind.label,
                style: TextStyle(
                  color: colors.info,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final location in t.locations.where((p) => p.kind == kind))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${location.label}${location.exists ? '' : ' · 未创建或已移除'}',
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textMuted,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '复制${location.label}路径',
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await Clipboard.setData(
                              ClipboardData(text: location.path),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('路径已复制')),
                              );
                            }
                          },
                          icon: const Icon(Icons.copy_outlined, size: 15),
                        ),
                        IconButton(
                          tooltip: '打开${location.label}',
                          visualDensity: VisualDensity.compact,
                          onPressed: !location.exists || opening
                              ? null
                              : () => open(location),
                          icon: const Icon(Icons.open_in_new, size: 15),
                        ),
                      ],
                    ),
                    SelectableText(
                      location.path,
                      style: TextStyle(
                        fontSize: 11,
                        color: location.exists
                            ? colors.textPrimary
                            : colors.textMuted,
                        height: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
          ],
          for (final note in t.notes)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                note,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  height: 1.5,
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
        controller: detailScroll,
        thumbVisibility: true,
        child: SingleChildScrollView(controller: detailScroll, child: panel),
      ),
    );
  }

  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 78,
          child: Text(
            label,
            style: TextStyle(
              color: AppTheme.colorsOf(context).textMuted,
              fontSize: 12,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 12, height: 1.4),
          ),
        ),
      ],
    ),
  );
}
