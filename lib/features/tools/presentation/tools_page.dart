import 'dart:async';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/shared/ui/tool_logo.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/features/toolchains/application/toolchains_provider.dart';

import 'package:flutter/material.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/features/tasks/presentation/tasks_page.dart';
import 'package:mise_gui/features/projects/application/projects_provider.dart';
import 'package:mise_gui/features/tools/presentation/classified_version_info.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/dashboard/application/dashboard_provider.dart';
import 'package:mise_gui/features/tools/application/tools_provider.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/mise_cli_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/shared/ui/action_preview_dialog.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';
import 'package:mise_gui/shared/ui/async_state_view.dart';
import 'package:mise_gui/shared/ui/history_entry_dialog.dart';
import 'package:mise_gui/shared/ui/inline_notice_bar.dart';

List<String> selectVersionSuggestions(List<MiseRemoteToolVersionRef> versions) {
  final stableVersions = versions
      .where(
        (version) =>
            !version.rolling &&
            isStableToolVersion(version.version) &&
            !(version.tool == 'java' &&
                _isJavaRuntimeOnlySuggestion(version.version)),
      )
      .toList();
  final source = stableVersions;
  if (source.isEmpty) {
    return const [];
  }

  final latestByMajor = <String, String>{};
  for (final version in source) {
    final value = version.version.trim();
    if (value.isEmpty) {
      continue;
    }

    final majorKey = _majorVersionKey(value);
    final current = latestByMajor[majorKey];
    if (current == null || compareToolVersions(value, current) > 0) {
      latestByMajor[majorKey] = value;
    }
  }

  final selected = latestByMajor.values.toList()
    ..sort((left, right) => compareToolVersions(right, left));
  return selected.take(5).toList(growable: false);
}

String _majorVersionKey(String input) {
  return toolVersionMajor(input) ?? input;
}

bool _isJavaRuntimeOnlySuggestion(String version) {
  final normalized = version.toLowerCase();
  return normalized.contains('-jre') || normalized.contains('+jre');
}

class ToolsPage extends ConsumerStatefulWidget {
  const ToolsPage({super.key, this.initialTool, this.initialTab});
  final String? initialTool, initialTab;

  @override
  ConsumerState<ToolsPage> createState() => _ToolsPageState();
}

class _ToolsPageState extends ConsumerState<ToolsPage> {
  String? _selectedToolId;
  final Set<String> _requestedToolIds = <String>{};
  final Set<String> _loadingToolIds = <String>{};
  final Set<String> _failedToolIds = <String>{};
  final Map<String, ToolRecord> _hydratedTools = <String, ToolRecord>{};
  var _refreshing = false;
  var _actionInProgress = false;
  var _detailEpoch = 0;
  _VersionInventoryType _inventoryType = _VersionInventoryType.installed;

  @override
  void initState() {
    super.initState();
    _applyLocation();
  }

  @override
  void didUpdateWidget(covariant ToolsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialTool != widget.initialTool ||
        oldWidget.initialTab != widget.initialTab) {
      _applyLocation();
    }
  }

  void _applyLocation() {
    _selectedToolId = widget.initialTool;
    _inventoryType = widget.initialTab == 'available'
        ? _VersionInventoryType.remote
        : _VersionInventoryType.installed;
    if (_selectedToolId != null &&
        _inventoryType == _VersionInventoryType.remote) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _ensureRemoteDetail();
      });
    }
  }

  void _ensureRemoteDetail() {
    final id = _selectedToolId;
    if (id != null &&
        !_loadingToolIds.contains(id) &&
        !_hydratedTools.containsKey(id) &&
        !_failedToolIds.contains(id)) {
      unawaited(_loadToolDetail(id));
    }
  }

  void _selectInventory(_VersionInventoryType type) {
    setState(() => _inventoryType = type);
    if (type == _VersionInventoryType.remote) _ensureRemoteDetail();
    _syncLocation();
  }

  void _syncLocation() {
    GoRouter.maybeOf(context)?.replace(
      Uri(
        path: '/tools',
        queryParameters: {
          if (_selectedToolId != null) 'tool': _selectedToolId!,
          'tab': _inventoryType == _VersionInventoryType.remote
              ? 'available'
              : 'installed',
        },
      ).toString(),
    );
  }

  void _showFeedback(String message) {
    if (!mounted) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _loadToolDetail(
    String toolId, {
    bool forceRefresh = false,
  }) async {
    if (_loadingToolIds.contains(toolId)) {
      return;
    }

    final epoch = _detailEpoch;
    setState(() {
      _requestedToolIds.add(toolId);
      _loadingToolIds.add(toolId);
      _failedToolIds.remove(toolId);
    });

    try {
      final detail = forceRefresh
          ? await ref.refresh(toolDetailProvider(toolId).future)
          : await ref.read(toolDetailProvider(toolId).future);
      if (!mounted || epoch != _detailEpoch) {
        return;
      }
      setState(() {
        _hydratedTools[toolId] = detail;
        _failedToolIds.remove(toolId);
      });
    } catch (error) {
      if (!mounted || epoch != _detailEpoch) return;
      _showFeedback('读取版本详情失败，请稍后重试。');
      if (!mounted) {
        return;
      }
      setState(() {
        _failedToolIds.add(toolId);
      });
    } finally {
      if (mounted && epoch == _detailEpoch) {
        setState(() {
          _loadingToolIds.remove(toolId);
        });
      }
    }
  }

  Future<void> _refreshTools() async {
    if (_refreshing) {
      _showFeedback('工具数据正在刷新，请稍候。');
      return;
    }

    setState(() {
      _refreshing = true;
      _detailEpoch++;
      _hydratedTools.clear();
      _requestedToolIds.clear();
      _loadingToolIds.clear();
      _failedToolIds.clear();
    });

    try {
      ref.invalidate(classifiedVersionsProvider);
      ref.invalidate(localToolsProvider);
      final _ = await ref.refresh(toolsProvider.future);
      final selectedToolId = _selectedToolId;
      if (selectedToolId != null &&
          _inventoryType == _VersionInventoryType.remote) {
        await _loadToolDetail(selectedToolId, forceRefresh: true);
      }
      _showFeedback('工具状态已刷新。');
    } catch (_) {
      _showFeedback('刷新工具状态失败，请稍后重试。');
    } finally {
      if (mounted) {
        setState(() {
          _refreshing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final toolsValue = ref.watch(toolsProvider);

    return AsyncStateView(
      value: toolsValue,
      builder: (tools) {
        final displayTools = tools
            .map((tool) => _hydratedTools[tool.id] ?? tool)
            .where(
              (tool) => _inventoryType == _VersionInventoryType.installed
                  ? tool.installedVersions.isNotEmpty
                  : ToolchainLayout.categories.containsKey(tool.id),
            )
            .toList(growable: false);

        return AppPageScaffold(
          title: 'mise 版本管理',
          description: '按工具查看已安装与可安装版本，管理目录和全局／项目选择。',
          actions: [
            OutlinedButton.icon(
              onPressed: _refreshing ? null : _refreshTools,
              icon: _refreshing
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
              label: Text(_refreshing ? '刷新中...' : '刷新状态'),
            ),
            FilledButton.icon(
              onPressed: () => _openInstallToolFlow(context),
              icon: const Icon(Icons.add_circle_outline_rounded),
              label: const Text('安装版本'),
            ),
          ],
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<_VersionInventoryType>(
                segments: const [
                  ButtonSegment(
                    value: _VersionInventoryType.installed,
                    label: Text('已安装'),
                    icon: Icon(Icons.inventory_2_outlined),
                  ),
                  ButtonSegment(
                    value: _VersionInventoryType.remote,
                    label: Text('可安装'),
                    icon: Icon(Icons.cloud_download_outlined),
                  ),
                ],
                selected: {_inventoryType},
                onSelectionChanged: (values) => _selectInventory(values.single),
              ),
              const SizedBox(height: 20),
              _ToolList(
                inventoryType: _inventoryType,
                tools: displayTools,
                selectedToolId: _selectedToolId,
                hydratedTools: _hydratedTools,
                loadingToolIds: _loadingToolIds,
                requestedToolIds: _requestedToolIds,
                failedToolIds: _failedToolIds,
                onSelected: _selectTool,
                onRetryDetail: _retryToolDetail,
                onOpenPreview: _openToolActionPreview,
              ),
            ],
          ),
        );
      },
    );
  }

  void _selectTool(String id) {
    if (_selectedToolId == id) {
      setState(() {
        _selectedToolId = null;
      });
      _syncLocation();
      return;
    }

    setState(() {
      _selectedToolId = id;
    });
    _syncLocation();

    if (_inventoryType == _VersionInventoryType.remote &&
        !_loadingToolIds.contains(id) &&
        !_hydratedTools.containsKey(id) &&
        !_failedToolIds.contains(id)) {
      unawaited(_loadToolDetail(id));
    }
  }

  void _retryToolDetail(String id) {
    unawaited(_loadToolDetail(id, forceRefresh: true));
  }

  Future<void> _openInstallToolFlow(BuildContext context) async {
    final request = await showDialog<_InstallToolRequest>(
      context: context,
      builder: (dialogContext) => const _InstallToolDialog(),
    );
    if (request == null || !mounted || !context.mounted) {
      return;
    }

    final installCommand = 'mise install ${request.tool}@${request.version}';

    await _openToolActionPreview(
      context,
      ActionPreviewDialogData(
        title: '安装 ${request.tool}@${request.version}',
        summary: '按分类目录安装并注册，保留现有全局默认版本。',
        command: installCommand,
        level: HealthLevel.info,
        affectedFiles: [ToolchainLayout.current.root],
        impactScope: ['安装后可另行选择全局或项目版本。', '安装完成后会自动刷新工具页与总览页数据。'],
        riskNotes: const [
          '安装时需要访问网络，过程可能会持续一段时间。',
          '如果版本号无效，安装会失败，失败结果会记录到最近操作。',
        ],
        confirmLabel: '确认安装',
      ),
    );
  }

  Future<void> _openToolActionPreview(
    BuildContext context,
    ActionPreviewDialogData data,
  ) async {
    if (_actionInProgress) {
      _showFeedback('上一项操作仍在收尾，请稍后重试。');
      return;
    }
    _actionInProgress = true;
    try {
      await _executeToolActionPreview(context, data);
    } finally {
      _actionInProgress = false;
    }
  }

  Future<void> _executeToolActionPreview(
    BuildContext context,
    ActionPreviewDialogData data,
  ) async {
    final history = ref.read(historyServiceProvider);
    if (data.requiresConfirmation) {
      try {
        final command = await ref
            .read(classifiedToolchainServiceProvider)
            .prepare(data.command);
        data = ActionPreviewDialogData(
          title: data.title,
          summary: data.summary,
          command: command,
          level: data.level,
          diffPreview: data.diffPreview,
          affectedFiles: {
            ToolchainLayout.current.root,
            ...data.affectedFiles,
          }.toList(),
          impactScope: data.impactScope,
          riskNotes: data.riskNotes,
          confirmLabel: data.confirmLabel,
        );
      } catch (error) {
        if (mounted) _showFeedback('$error');
        return;
      }
      if (!mounted || !context.mounted) return;
    }
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showActionPreviewDialog(context, data: data);
    if (!confirmed) {
      if (data.requiresConfirmation) {
        await history.appendEntry(
          HistoryEntry(
            command: data.command,
            timestamp: _formatNow(),
            detail: '用户取消了 ${data.title}。',
            level: HealthLevel.info,
            status: HistoryStatus.canceled,
          ),
        );
      }
      return;
    }

    if (!mounted || !context.mounted || !data.requiresConfirmation) {
      return;
    }

    var runningDialogOpen = true;
    final runningDialog = _showRunningDialog(context);
    unawaited(runningDialog.then((_) => runningDialogOpen = false));
    HistoryEntry? failureEntryToShow;
    String? snackMessage;
    try {
      final result = await ref
          .read(miseActionServiceProvider)
          .runScript(data.command);
      if (!mounted || !context.mounted) {
        return;
      }

      ref.invalidate(classifiedVersionsProvider);
      ref.invalidate(localToolsProvider);
      ref.invalidate(projectsProvider);
      ref.invalidate(projectCoverageProvider);
      final success = result.isSuccess;
      final diagnosis = success
          ? null
          : diagnoseMiseCommandFailure(
              command: data.command,
              stdout: result.stdout,
              stderr: result.stderr,
            );
      final historyEntry = HistoryEntry(
        command: data.command,
        timestamp: _formatNow(),
        detail: success
            ? '已通过界面执行 ${data.title}。'
            : _appendLockfileCleanupDetail(
                diagnosis?.detail ??
                    result.verification?.detail ??
                    '${data.title} 执行失败，已保留实际 CLI 和错误输出。',
                result.lockfileCleanupReport.detail,
              ),
        level: success ? data.level : HealthLevel.warning,
        status: success ? HistoryStatus.success : HistoryStatus.failure,
        exitCode: result.exitCode,
        durationMs: result.duration.inMilliseconds,
        stdout: result.stdout,
        stderr: result.stderr,
        stdoutSnippet: result.stdoutSnippet,
        stderrSnippet: result.stderrSnippet,
      );
      await history.appendEntry(historyEntry);

      if (!mounted || !context.mounted) return;
      if (success) {
        if (mounted) {
          setState(() {
            _detailEpoch++;
            _hydratedTools.clear();
            _requestedToolIds.clear();
            _loadingToolIds.clear();
            _failedToolIds.clear();
          });
        }
        ref.invalidate(toolsProvider);
        await ref.read(toolsProvider.future);
        if (!mounted || !context.mounted) return;
        ref.invalidate(dashboardProvider);
        if (mounted && _inventoryType == _VersionInventoryType.remote) {
          _ensureRemoteDetail();
        }
      } else {
        ref.invalidate(dashboardProvider);
      }

      snackMessage = _actionSnackMessage(
        title: data.title,
        success: success,
        diagnosis: diagnosis,
        cleanedLockfiles: result.lockfileCleanupReport.removedPaths.isNotEmpty,
      );
      if (!success) {
        failureEntryToShow = historyEntry;
      }
    } catch (error) {
      final historyEntry = HistoryEntry(
        command: data.command,
        timestamp: _formatNow(),
        detail: '${data.title} 执行异常，界面已拦截并保留错误信息。',
        level: HealthLevel.warning,
        status: HistoryStatus.failure,
        exitCode: -1,
        stderr: error.toString(),
        stderrSnippet: error.toString(),
      );
      await history.appendEntry(historyEntry);
      snackMessage = '${data.title} 执行异常，已打开错误详情。';
      failureEntryToShow = historyEntry;
    } finally {
      if (runningDialogOpen &&
          rootNavigator.mounted &&
          rootNavigator.canPop()) {
        rootNavigator.pop();
        await runningDialog;
      }
    }

    if (!mounted || !context.mounted) {
      return;
    }

    messenger.removeCurrentSnackBar();
    messenger.showSnackBar(SnackBar(content: Text(snackMessage)));

    if (failureEntryToShow != null) {
      await showHistoryEntryDialog(context, entry: failureEntryToShow);
    }
  }

  Future<void> _showRunningDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: Dialog(
          child: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Consumer(
                    builder: (context, ref, _) {
                      final task = ref
                          .watch(taskCenterProvider)
                          .tasks
                          .where((t) => t.manager == 'mise')
                          .firstOrNull;
                      return task == null
                          ? const CircularProgressIndicator()
                          : TaskDetail(task: task);
                    },
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('后台继续，可在任务中心查看'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatNow() {
    final now = DateTime.now();
    final hours = now.hour.toString().padLeft(2, '0');
    final minutes = now.minute.toString().padLeft(2, '0');
    return '$hours:$minutes';
  }

  String _appendLockfileCleanupDetail(String detail, String? cleanupDetail) {
    final value = cleanupDetail?.trim();
    if (value == null || value.isEmpty) {
      return detail;
    }
    return '$detail\n\n$value';
  }

  String _actionSnackMessage({
    required String title,
    required bool success,
    required MiseFailureDiagnosis? diagnosis,
    required bool cleanedLockfiles,
  }) {
    if (success) {
      return '$title 已执行完成。';
    }
    if (cleanedLockfiles) {
      return '$title 执行失败，已清理残留锁文件。';
    }
    if (diagnosis == null) {
      return '$title 执行失败，已打开错误详情。';
    }
    return '$title 执行失败：${diagnosis.summary}';
  }
}

class _ToolWorkspaceError extends StatelessWidget {
  const _ToolWorkspaceError({required this.toolName, required this.onRetry});

  final String toolName;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return AppPanel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.warning.withValues(alpha: 0.24)),
            ),
            child: Icon(Icons.refresh_rounded, color: colors.warning, size: 21),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$toolName 详情读取失败',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  '可能是远端版本同步暂时不可用，或者当前网络无法访问 mise 数据源。',
                  style: TextStyle(color: colors.textMuted, height: 1.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          OutlinedButton.icon(
            key: ValueKey('retry-tool-detail-$toolName'),
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _InstallToolRequest {
  const _InstallToolRequest({required this.tool, required this.version});

  final String tool;
  final String version;
}

class _InstallToolDialog extends ConsumerStatefulWidget {
  const _InstallToolDialog();

  @override
  ConsumerState<_InstallToolDialog> createState() => _InstallToolDialogState();
}

class _InstallToolDialogState extends ConsumerState<_InstallToolDialog> {
  final TextEditingController _toolController = TextEditingController();
  final TextEditingController _versionController = TextEditingController();
  final FocusNode _versionFocusNode = FocusNode();
  Timer? _lookupDebounce;
  var _loadingVersions = false;
  List<String> _versionSuggestions = const [];
  String? _lookupMessage;
  int _lookupToken = 0;

  @override
  void initState() {
    super.initState();
    _toolController.addListener(_scheduleVersionLookup);
    _versionFocusNode.addListener(() {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _lookupDebounce?.cancel();
    _toolController.removeListener(_scheduleVersionLookup);
    _toolController.dispose();
    _versionController.dispose();
    _versionFocusNode.dispose();
    super.dispose();
  }

  void _scheduleVersionLookup() {
    final tool = _toolController.text.trim();
    final scheduledToken = ++_lookupToken;

    _lookupDebounce?.cancel();
    if (mounted) {
      setState(() {
        _versionSuggestions = const [];
        _lookupMessage = tool.isEmpty ? null : '正在读取远端版本...';
        _loadingVersions = tool.isNotEmpty;
      });
    }
    _lookupDebounce = Timer(
      const Duration(milliseconds: 350),
      () => _loadRemoteVersions(scheduledToken),
    );
  }

  Future<void> _loadRemoteVersions(int token) async {
    final tool = _toolController.text.trim();

    if (tool.isEmpty) {
      if (mounted && token == _lookupToken) {
        setState(() {
          _loadingVersions = false;
          _versionSuggestions = const [];
          _lookupMessage = null;
        });
      }
      return;
    }

    setState(() {
      _loadingVersions = true;
      _lookupMessage = null;
    });

    try {
      final versions = await ref
          .read(miseQueryServiceProvider)
          .fetchRemoteVersions(tool);
      if (!mounted || token != _lookupToken) {
        return;
      }
      final selected = selectVersionSuggestions(versions);

      setState(() {
        _loadingVersions = false;
        _versionSuggestions = selected;
        _lookupMessage = selected.isEmpty ? '没有拉到可选版本，仍可手动输入。' : null;
      });
    } catch (error) {
      if (!mounted || token != _lookupToken) {
        return;
      }
      setState(() {
        _loadingVersions = false;
        _versionSuggestions = const [];
        _lookupMessage = '远端版本读取失败，仍可手动输入版本号。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: colors.panel,
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: colors.borderStrong),
          boxShadow: [
            BoxShadow(
              color: colors.backgroundDeep.withValues(alpha: 0.14),
              blurRadius: 32,
              offset: const Offset(0, 18),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('安装新工具', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 10),
            Text(
              '输入要安装的工具名和版本，随后会进入执行前预览与确认。',
              style: TextStyle(color: colors.textMuted, height: 1.55),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _toolController,
              decoration: const InputDecoration(
                labelText: 'Tool',
                hintText: 'java / node / python / go / rust / flutter',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _versionController,
              focusNode: _versionFocusNode,
              decoration: const InputDecoration(
                labelText: 'Version',
                hintText: '精确版本，例如 24.21.0 或 temurin-21.0.12.1+1',
              ),
            ),
            if (_versionFocusNode.hasFocus &&
                (_loadingVersions ||
                    _versionSuggestions.isNotEmpty ||
                    _lookupMessage != null)) ...[
              const SizedBox(height: 10),
              _VersionSuggestionList(
                loading: _loadingVersions,
                versions: _versionSuggestions,
                message: _lookupMessage,
                selectedVersion: _versionController.text.trim(),
                onSelected: (version) {
                  _versionController.text = version;
                  _versionController.selection = TextSelection.collapsed(
                    offset: version.length,
                  );
                  _versionFocusNode.unfocus();
                  setState(() {});
                },
              ),
            ],
            const SizedBox(height: 18),
            Text(
              '安装到 ${ToolchainLayout.current.root} 下的对应分类目录；安装后另行选择全局或项目版本。',
              style: TextStyle(
                color: colors.textMuted,
                fontSize: 13,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.arrow_forward_rounded),
                  label: const Text('继续预览'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _submit() {
    final tool = _toolController.text.trim();
    final version = _versionController.text.trim();
    if (tool.isEmpty || version.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先填写工具名和版本号。')));
      return;
    }

    try {
      ToolchainLayout.current.categoryRoot(tool);
      ToolchainLayout.validateVersion(version);
    } catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    Navigator.of(
      context,
    ).pop(_InstallToolRequest(tool: tool, version: version));
  }
}

class _VersionSuggestionList extends StatelessWidget {
  const _VersionSuggestionList({
    required this.loading,
    required this.versions,
    required this.message,
    required this.selectedVersion,
    required this.onSelected,
  });

  final bool loading;
  final List<String> versions;
  final String? message;
  final String selectedVersion;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.panelRaised.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: colors.border),
      ),
      child: loading
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: LinearProgressIndicator(minHeight: 3),
            )
          : versions.isNotEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 8),
                  child: Text(
                    '远端可选版本（各大版本最新发行版）',
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                for (var index = 0; index < versions.length; index++)
                  _VersionSuggestionRow(
                    version: versions[index],
                    selected: versions[index] == selectedVersion,
                    isFirst: index == 0,
                    onTap: () => onSelected(versions[index]),
                  ),
              ],
            )
          : Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                message ?? '没有拉到可选版本，仍可手动输入。',
                style: TextStyle(color: colors.textMuted, height: 1.45),
              ),
            ),
    );
  }
}

class _VersionSuggestionRow extends StatelessWidget {
  const _VersionSuggestionRow({
    required this.version,
    required this.selected,
    required this.isFirst,
    required this.onTap,
  });

  final String version;
  final bool selected;
  final bool isFirst;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: selected
            ? colors.info.withValues(alpha: 0.12)
            : colors.panel.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTapDown: (_) => onTap(),
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          hoverColor: colors.hover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    version,
                    style: const TextStyle(
                      fontFamily: 'FiraCode',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (isFirst)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: colors.accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      '最新',
                      style: TextStyle(
                        color: colors.accent,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                if (selected) ...[
                  const SizedBox(width: 8),
                  Icon(Icons.check_rounded, size: 18, color: colors.info),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToolList extends StatelessWidget {
  const _ToolList({
    required this.inventoryType,
    required this.tools,
    required this.selectedToolId,
    required this.hydratedTools,
    required this.loadingToolIds,
    required this.requestedToolIds,
    required this.failedToolIds,
    required this.onSelected,
    required this.onRetryDetail,
    required this.onOpenPreview,
  });

  final _VersionInventoryType inventoryType;
  final List<ToolRecord> tools;
  final String? selectedToolId;
  final Map<String, ToolRecord> hydratedTools;
  final Set<String> loadingToolIds;
  final Set<String> requestedToolIds;
  final Set<String> failedToolIds;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onRetryDetail;
  final Future<void> Function(
    BuildContext context,
    ActionPreviewDialogData data,
  )
  onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            inventoryType == _VersionInventoryType.installed
                ? '已安装工具'
                : '可安装工具',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            inventoryType == _VersionInventoryType.installed
                ? '展开工具查看本机版本、真实目录与切换操作。'
                : '展开工具按需查询远端版本；安装后另行选择全局或项目版本。',
            style: TextStyle(color: colors.textMuted, height: 1.5),
          ),
          const SizedBox(height: 18),
          if (tools.isEmpty) const Text('尚未安装运行时，可切换到“可安装”查询版本。'),
          for (final tool in tools)
            KeyedSubtree(
              key: ValueKey('tool-accordion-${tool.id}'),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ToolAccordionItem(
                  inventoryType: inventoryType,
                  tool: tool,
                  hydratedTool: hydratedTools[tool.id],
                  expanded: tool.id == selectedToolId,
                  detailLoading: loadingToolIds.contains(tool.id),
                  detailRequested: requestedToolIds.contains(tool.id),
                  detailFailed: failedToolIds.contains(tool.id),
                  onTap: () => onSelected(tool.id),
                  onRetryDetail: () => onRetryDetail(tool.id),
                  onOpenPreview: onOpenPreview,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolAccordionItem extends StatelessWidget {
  const _ToolAccordionItem({
    required this.inventoryType,
    required this.tool,
    required this.hydratedTool,
    required this.expanded,
    required this.detailLoading,
    required this.detailRequested,
    required this.detailFailed,
    required this.onTap,
    required this.onRetryDetail,
    required this.onOpenPreview,
  });

  final _VersionInventoryType inventoryType;
  final ToolRecord tool;
  final ToolRecord? hydratedTool;
  final bool expanded;
  final bool detailLoading;
  final bool detailRequested;
  final bool detailFailed;
  final VoidCallback onTap;
  final VoidCallback onRetryDetail;
  final Future<void> Function(
    BuildContext context,
    ActionPreviewDialogData data,
  )
  onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final detail = _resolveDetail();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ToolListItem(
          inventoryType: inventoryType,
          tool: tool,
          selected: expanded,
          detailLoading: detailLoading,
          detailRequested: detailRequested,
          detailFailed: detailFailed,
          onTap: onTap,
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return SizeTransition(
              sizeFactor: animation,
              alignment: Alignment.topCenter,
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: detail,
        ),
      ],
    );
  }

  Widget _resolveDetail() {
    if (!expanded) {
      return const SizedBox.shrink(key: ValueKey('collapsed-detail'));
    }

    final detailTool = hydratedTool ?? tool;
    if (hydratedTool == null) {
      return _AccordionDetailShell(
        key: ValueKey('local-detail-${tool.id}'),
        child: Column(
          children: [
            if (inventoryType == _VersionInventoryType.remote && detailLoading)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text('正在同步远端版本，本机版本可先使用。'),
              ),
            if (inventoryType == _VersionInventoryType.remote && detailFailed)
              _ToolWorkspaceError(toolName: tool.name, onRetry: onRetryDetail),
            _ToolWorkspace(
              inventoryType: inventoryType,
              tool: tool,
              onRetryDetail: onRetryDetail,
              onOpenPreview: onOpenPreview,
            ),
          ],
        ),
      );
    }

    return _AccordionDetailShell(
      key: ValueKey('ready-detail-${tool.id}-${detailTool.activeVersion}'),
      child: _ToolWorkspace(
        inventoryType: inventoryType,
        tool: detailTool,
        onRetryDetail: onRetryDetail,
        onOpenPreview: onOpenPreview,
      ),
    );
  }
}

class _AccordionDetailShell extends StatelessWidget {
  const _AccordionDetailShell({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 20),
      child: child,
    );
  }
}

class _ToolListItem extends StatelessWidget {
  const _ToolListItem({
    required this.inventoryType,
    required this.tool,
    required this.selected,
    required this.detailLoading,
    required this.detailRequested,
    required this.detailFailed,
    required this.onTap,
  });

  final _VersionInventoryType inventoryType;
  final ToolRecord tool;
  final bool selected;
  final bool detailLoading;
  final bool detailRequested;
  final bool detailFailed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    final hasActiveVersion = tool.installedVersions.any(
      (version) => version.isActive,
    );
    final latestValue = switch ((
      detailLoading,
      detailRequested,
      detailFailed,
      tool.remoteState,
    )) {
      (true, _, _, _) => '加载中...',
      (false, _, true, _) => '读取失败',
      (false, false, _, _) => '点击查看',
      (false, true, _, ToolRemoteState.unavailable) => '未获取',
      _ => tool.latestStableVersion,
    };

    return Material(
      color: selected
          ? colors.info.withValues(alpha: 0.10)
          : colors.panelRaised.withValues(alpha: 0.84),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(22),
        hoverColor: colors.hover,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ToolLogo(tool: tool.id, size: 30),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tool.name,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(tool.category, style: TextStyle(color: colors.textMuted)),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _MiniFact(
                    label: '全局默认',
                    value: hasActiveVersion ? tool.activeVersion : '未设置',
                  ),
                  if (inventoryType == _VersionInventoryType.remote)
                    _MiniFact(label: '最新', value: latestValue)
                  else
                    _MiniFact(
                      label: '已安装',
                      value: '${tool.installedCount} 个版本',
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolWorkspace extends StatelessWidget {
  const _ToolWorkspace({
    required this.inventoryType,
    required this.tool,
    required this.onRetryDetail,
    required this.onOpenPreview,
  });
  final _VersionInventoryType inventoryType;
  final ToolRecord tool;
  final VoidCallback onRetryDetail;
  final Future<void> Function(BuildContext, ActionPreviewDialogData)
  onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final installed = inventoryType == _VersionInventoryType.installed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ToolHeroPanel(
          inventoryType: inventoryType,
          tool: tool,
          onRetryDetail: onRetryDetail,
        ),
        const SizedBox(height: 18),
        _VersionInventoryPanel(
          title: installed ? '已安装版本' : '可安装版本',
          subtitle: installed ? '选择全局默认，或固定到指定项目。' : '安装到对应分类目录，保留现有全局默认。',
          toolId: tool.id,
          toolName: tool.name,
          inventoryType: inventoryType,
          versions: installed ? tool.installedVersions : tool.remoteVersions,
          emptyState: _PanelEmptyStateData(
            icon: installed
                ? Icons.inventory_2_outlined
                : Icons.cloud_off_outlined,
            title: installed ? '当前没有已安装版本' : '尚未取得可安装版本',
            message: installed
                ? '切换到“可安装”查询并安装版本。'
                : '远端版本按需查询；可稍后重试或使用“安装版本”输入精确版本。',
            level: HealthLevel.info,
          ),
          onOpenPreview: onOpenPreview,
        ),
      ],
    );
  }
}

class _ToolHeroPanel extends StatelessWidget {
  const _ToolHeroPanel({
    required this.inventoryType,
    required this.tool,
    required this.onRetryDetail,
  });
  final _VersionInventoryType inventoryType;
  final ToolRecord tool;
  final VoidCallback onRetryDetail;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    final active = tool.installedVersions.where((v) => v.isActive).firstOrNull;
    final remote = inventoryType == _VersionInventoryType.remote;
    final latest = switch (tool.remoteState) {
      ToolRemoteState.pending => '待查询',
      ToolRemoteState.unavailable => '未获取',
      ToolRemoteState.ready => tool.latestStableVersion,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.panelRaised.withValues(alpha: .36),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border.withValues(alpha: .36)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            active == null ? '未设置全局默认' : '全局默认 ${active.version}',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              fontFamily: 'FiraCode',
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            remote ? '最新稳定版 $latest' : '项目固定版本优先于全局默认；切换仅使用已安装版本。',
            style: TextStyle(color: colors.textMuted, fontSize: 13),
          ),
          if (remote) ...[
            for (final notice in tool.notices)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: InlineNoticeBar(
                  notice: notice,
                  actionLabel: tool.remoteState == ToolRemoteState.unavailable
                      ? '重试'
                      : null,
                  actionIcon: Icons.refresh_rounded,
                  onAction: tool.remoteState == ToolRemoteState.unavailable
                      ? onRetryDetail
                      : null,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

enum _VersionInventoryType { installed, remote }

class _VersionInventoryPanel extends StatelessWidget {
  const _VersionInventoryPanel({
    required this.title,
    required this.subtitle,
    required this.toolId,
    required this.toolName,
    required this.inventoryType,
    required this.versions,
    this.emptyState,
    required this.onOpenPreview,
  });

  final String title;
  final String subtitle;
  final String toolId;
  final String toolName;
  final _VersionInventoryType inventoryType;
  final List<ToolVersionRecord> versions;
  final _PanelEmptyStateData? emptyState;
  final Future<void> Function(
    BuildContext context,
    ActionPreviewDialogData data,
  )
  onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.panelRaised.withValues(alpha: 0.24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: colors.border.withValues(alpha: 0.32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ToolSectionHeader(
            title: title,
            subtitle: subtitle,
            badgeLabel: versions.length > 1 ? '${versions.length} 条' : null,
          ),
          const SizedBox(height: 18),
          if (versions.isEmpty)
            _PanelEmptyStateCard(
              data:
                  emptyState ??
                  const _PanelEmptyStateData(
                    icon: Icons.info_outline_rounded,
                    title: '当前没有可展示的数据',
                    message: '稍后可以重新同步，或先使用当前本机版本继续操作。',
                    level: HealthLevel.info,
                  ),
              onOpenPreview: onOpenPreview,
            )
          else
            Column(
              children: [
                for (var index = 0; index < versions.length; index++) ...[
                  _VersionCard(
                    toolId: toolId,
                    toolName: toolName,
                    version: versions[index],
                    inventoryType: inventoryType,
                    onOpenPreview: onOpenPreview,
                  ),
                  if (index != versions.length - 1)
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.border.withValues(alpha: 0.46),
                    ),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _VersionCard extends StatelessWidget {
  const _VersionCard({
    required this.toolId,
    required this.toolName,
    required this.version,
    required this.inventoryType,
    required this.onOpenPreview,
  });

  final String toolId;
  final String toolName;
  final ToolVersionRecord version;
  final _VersionInventoryType inventoryType;
  final Future<void> Function(
    BuildContext context,
    ActionPreviewDialogData data,
  )
  onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    final statusLabel = _statusLabel();
    final statusLevel = _statusLevel();

    final row = LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < 520;
        final actionRow = _VersionActions(
          toolId: toolId,
          toolName: toolName,
          version: version,
          inventoryType: inventoryType,
          onOpenPreview: onOpenPreview,
        );

        final info = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(
              version.version,
              style: TextStyle(
                color: colors.textPrimary,
                fontFamily: 'FiraCode',
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            if (statusLabel != null) ...[
              const SizedBox(height: 6),
              _VersionStateLabel(label: statusLabel, level: statusLevel),
            ],
          ],
        );

        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 14),
              info,
              const SizedBox(height: 12),
              actionRow,
              const SizedBox(height: 14),
            ],
          );
        }

        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: info),
              const SizedBox(width: 16),
              actionRow,
            ],
          ),
        );
      },
    );
    return Padding(
      key: ValueKey('${inventoryType.name}-$toolId-${version.version}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          row,
          if (inventoryType == _VersionInventoryType.installed)
            ClassifiedVersionInfo(tool: toolId, version: version.version),
        ],
      ),
    );
  }

  String? _statusLabel() {
    if (version.isActive) {
      return '全局默认';
    }
    if (version.isRecommended) {
      return '推荐版本';
    }
    if (version.isAlias) {
      return '别名映射';
    }
    return null;
  }

  HealthLevel _statusLevel() {
    if (version.isActive) {
      return HealthLevel.healthy;
    }
    if (version.isRecommended) {
      return HealthLevel.info;
    }
    return version.level;
  }
}

class _VersionActions extends ConsumerWidget {
  const _VersionActions({
    required this.toolId,
    required this.toolName,
    required this.version,
    required this.inventoryType,
    required this.onOpenPreview,
  });
  final String toolId, toolName;
  final ToolVersionRecord version;
  final _VersionInventoryType inventoryType;
  final Future<void> Function(BuildContext, ActionPreviewDialogData)
  onOpenPreview;

  Future<void> _switch(
    BuildContext context,
    WidgetRef ref, {
    required bool project,
  }) async {
    try {
      final path = project
          ? await ref.read(projectDirectoryPickerProvider)()
          : null;
      if (!context.mounted || (project && path == null)) return;
      final command = await ref
          .read(classifiedToolchainServiceProvider)
          .switchPlan(toolId, version.version, projectPath: path);
      if (!context.mounted) return;
      await onOpenPreview(
        context,
        ActionPreviewDialogData(
          title: project ? '固定项目版本' : '设为全局默认',
          summary: project
              ? '仅修改所选项目的 mise.toml；保留全局默认和 SDK。'
              : '修改全局默认；已有项目固定版本继续优先。',
          command: command,
          level: HealthLevel.info,
          affectedFiles: [
            project
                ? '$path/mise.toml'
                : ToolchainLayout.current.globalConfigPath,
          ],
          impactScope: [project ? '项目：$path' : '全局默认', '切换仅使用已安装版本，不下载 SDK。'],
          confirmLabel: '确认切换',
        ),
      );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('无法准备切换：$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ToolchainLayout.categories.containsKey(toolId)) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (inventoryType == _VersionInventoryType.installed &&
            version.isInstalled) ...[
          TextButton(
            onPressed: version.isActive
                ? null
                : () => _switch(context, ref, project: false),
            child: Text(version.isActive ? '全局默认' : '设为全局默认'),
          ),
          TextButton(
            onPressed: () => _switch(context, ref, project: true),
            child: const Text('用于指定项目'),
          ),
        ] else if (!version.isInstalled)
          TextButton(
            onPressed: () => onOpenPreview(
              context,
              ActionPreviewDialogData(
                title: '安装 $toolName ${version.version}',
                summary: '按分类目录安装并注册，保留现有全局默认。',
                command: 'mise install $toolId@${version.version}',
                level: HealthLevel.info,
                affectedFiles: [ToolchainLayout.current.categoryRoot(toolId)],
                impactScope: const ['新增本机版本，安装后可另行选择全局或项目版本。'],
                confirmLabel: '确认安装',
              ),
            ),
            child: const Text('安装'),
          )
        else
          const Text('已安装'),
      ],
    );
  }
}

class _VersionStateLabel extends StatelessWidget {
  const _VersionStateLabel({required this.label, required this.level});

  final String label;
  final HealthLevel level;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    final color = switch (level) {
      HealthLevel.healthy => colors.accent,
      HealthLevel.info => colors.info,
      HealthLevel.warning => colors.warning,
      HealthLevel.critical => colors.danger,
    };

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _ToolSectionHeader extends StatelessWidget {
  const _ToolSectionHeader({
    required this.title,
    required this.subtitle,
    this.badgeLabel,
  });

  final String title;
  final String subtitle;
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    subtitle,
                    style: TextStyle(color: colors.textMuted, height: 1.5),
                  ),
                ],
              ),
            ),
            if (badgeLabel != null) ...[
              const SizedBox(width: 12),
              _SectionCountLabel(label: badgeLabel!),
            ],
          ],
        ),
        const SizedBox(height: 14),
        Container(
          height: 1,
          width: double.infinity,
          color: colors.border.withValues(alpha: 0.8),
        ),
      ],
    );
  }
}

class _SectionCountLabel extends StatelessWidget {
  const _SectionCountLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Text(
      label,
      style: TextStyle(
        color: colors.textMuted,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _PanelEmptyStateData {
  const _PanelEmptyStateData({
    required this.icon,
    required this.title,
    required this.message,
    required this.level,
  });

  final IconData icon;
  final String title;
  final String message;
  final HealthLevel level;
}

class _PanelEmptyStateCard extends StatelessWidget {
  const _PanelEmptyStateCard({required this.data, this.onOpenPreview});

  final _PanelEmptyStateData data;
  final Future<void> Function(
    BuildContext context,
    ActionPreviewDialogData data,
  )?
  onOpenPreview;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.panelRaised.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: switch (data.level) {
                    HealthLevel.healthy => colors.accent.withValues(
                      alpha: 0.14,
                    ),
                    HealthLevel.info => colors.info.withValues(alpha: 0.14),
                    HealthLevel.warning => colors.warning.withValues(
                      alpha: 0.14,
                    ),
                    HealthLevel.critical => colors.danger.withValues(
                      alpha: 0.14,
                    ),
                  },
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(
                  data.icon,
                  color: switch (data.level) {
                    HealthLevel.healthy => colors.accent,
                    HealthLevel.info => colors.info,
                    HealthLevel.warning => colors.warning,
                    HealthLevel.critical => colors.danger,
                  },
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      data.message,
                      style: TextStyle(color: colors.textMuted, height: 1.45),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniFact extends StatelessWidget {
  const _MiniFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.backgroundSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          color: colors.textMuted,
          fontSize: 12,
          fontFamily: 'FiraCode',
        ),
      ),
    );
  }
}
