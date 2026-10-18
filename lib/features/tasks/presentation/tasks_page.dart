import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/features/storage/application/storage_provider.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/shared/ui/app_page_scaffold.dart';
import 'package:mise_gui/shared/ui/app_panel.dart';

class TasksPage extends ConsumerStatefulWidget {
  const TasksPage({super.key});
  @override
  ConsumerState<TasksPage> createState() => _TasksPageState();
}

class _TasksPageState extends ConsumerState<TasksPage> {
  String? selected, manager;
  String filter = '全部';
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(taskCenterProvider);
    final tasks = state.tasks
        .where(
          (t) =>
              (manager == null || manager == t.manager) &&
              (filter == '全部' ||
                  (filter == '执行中'
                      ? t.running
                      : filter == '需检查'
                      ? [
                          TaskStatus.failed,
                          TaskStatus.warning,
                          TaskStatus.interrupted,
                          TaskStatus.cancelled,
                        ].contains(t.status)
                      : t.status == TaskStatus.succeeded)),
        )
        .toList();
    final current =
        tasks.where((t) => t.id == selected).firstOrNull ?? tasks.firstOrNull;
    return AppPageScaffold(
      title: '任务中心',
      description: '操作步骤、实时输出与验证记录',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              for (final (label, count) in [
                ('执行中', state.tasks.where((t) => t.running).length),
                (
                  '已完成',
                  state.tasks
                      .where((t) => t.status == TaskStatus.succeeded)
                      .length,
                ),
                (
                  '需检查',
                  state.tasks
                      .where(
                        (t) => !t.running && t.status != TaskStatus.succeeded,
                      )
                      .length,
                ),
              ])
                SizedBox(
                  width: 200,
                  child: AppPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label),
                        const SizedBox(height: 8),
                        Text(
                          '$count',
                          style: Theme.of(context).textTheme.headlineMedium,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 18),
          const Text('进度按已完成步骤计算。下载中的单个命令保持运行状态；任务随应用进程执行。'),
          if (state.persistenceError != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                state.persistenceError!,
                style: const TextStyle(color: Colors.orange),
              ),
            ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final value in ['全部', '执行中', '已完成', '需检查'])
                ChoiceChip(
                  label: Text(value),
                  selected: filter == value,
                  onSelected: (_) => setState(() => filter = value),
                ),
              DropdownButton<String>(
                value: manager,
                hint: const Text('全部管理器'),
                items: [
                  const DropdownMenuItem<String>(child: Text('全部管理器')),
                  for (final value in state.tasks.map((t) => t.manager).toSet())
                    DropdownMenuItem(value: value, child: Text(value)),
                ],
                onChanged: (value) => setState(() => manager = value),
              ),
            ],
          ),
          const SizedBox(height: 18),
          if (tasks.isEmpty)
            const AppPanel(
              child: Text('暂无任务。从 mise 版本管理、目录扫描或管理器设置发起操作后，会在这里显示。'),
            )
          else
            LayoutBuilder(
              builder: (context, c) {
                final list = AppPanel(
                  padding: const EdgeInsets.all(8),
                  child: Material(
                    type: MaterialType.transparency,
                    child: SizedBox(
                      height: 460,
                      child: ListView(
                        children: [
                          for (final t in tasks)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: ListTile(
                                selected: t.id == current?.id,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                title: Text(
                                  t.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Text(
                                    '${t.manager} · ${t.status.label}\n${_time(t.startedAt)}',
                                  ),
                                ),
                                trailing: Icon(_icon(t.status), size: 19),
                                onTap: () => setState(() => selected = t.id),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
                final detail = Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (current!.running && current.manager == '目录扫描')
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: OutlinedButton.icon(
                          onPressed: () => ref
                              .read(directoryScanCancellationProvider)
                              .cancel(),
                          icon: const Icon(Icons.stop_circle_outlined),
                          label: const Text('停止目录扫描'),
                        ),
                      ),
                    TaskDetail(task: current),
                  ],
                );
                return c.maxWidth >= 950
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 310, child: list),
                          const SizedBox(width: 18),
                          Expanded(child: detail),
                        ],
                      )
                    : Column(
                        children: [list, const SizedBox(height: 16), detail],
                      );
              },
            ),
        ],
      ),
    );
  }
}

class TaskDetail extends StatelessWidget {
  const TaskDetail({super.key, required this.task});
  final WorkbenchTask task;
  @override
  Widget build(BuildContext context) {
    final colors = AppTheme.colorsOf(context);
    return AppPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  task.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                task.status.label,
                style: TextStyle(
                  color: task.status == TaskStatus.failed
                      ? Colors.red
                      : colors.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${task.manager} · ${_time(task.startedAt)}${task.finishedAt == null ? '' : ' · 用时 ${task.finishedAt!.difference(task.startedAt).inSeconds} 秒'}',
          ),
          const SizedBox(height: 16),
          LinearProgressIndicator(value: task.progress),
          const SizedBox(height: 8),
          Text('${task.completed}/${task.steps.length} 步完成'),
          const SizedBox(height: 12),
          for (final (i, step) in task.steps.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (step.status) {
                      TaskStepStatus.pending => Icons.radio_button_unchecked,
                      TaskStepStatus.running => Icons.pending_outlined,
                      TaskStepStatus.succeeded => Icons.check_circle_outline,
                      TaskStepStatus.failed => Icons.error_outline,
                      TaskStepStatus.skipped => Icons.remove_circle_outline,
                    },
                    size: 18,
                    color: step.status == TaskStepStatus.failed
                        ? Colors.red
                        : step.status == TaskStepStatus.succeeded
                        ? colors.accent
                        : colors.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Expanded(child: SelectableText('${i + 1}. ${step.title}')),
                  if (step.exitCode != null)
                    Text(
                      'exit ${step.exitCode}',
                      style: TextStyle(color: colors.textMuted),
                    ),
                ],
              ),
            ),
          const Divider(height: 28),
          Text(
            task.running ? '当前状态' : '验证结果',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          SelectableText(task.verification),
          const SizedBox(height: 18),
          Text('输出', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: colors.panelMuted,
              borderRadius: BorderRadius.circular(12),
            ),
            constraints: const BoxConstraints(maxHeight: 280, minHeight: 100),
            child: SingleChildScrollView(
              child: SelectableText(
                task.output.isEmpty ? '等待命令输出…' : task.output,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '保留最近 40 项完成记录，每项输出保留末尾约 32K 字符。',
            style: TextStyle(color: colors.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

IconData _icon(TaskStatus status) => switch (status) {
  TaskStatus.running => Icons.pending_outlined,
  TaskStatus.succeeded => Icons.check_circle_outline,
  TaskStatus.warning || TaskStatus.interrupted => Icons.warning_amber_rounded,
  TaskStatus.failed => Icons.error_outline,
  TaskStatus.cancelled => Icons.stop_circle_outlined,
};
String _time(DateTime value) =>
    '${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}:${value.second.toString().padLeft(2, '0')}';
