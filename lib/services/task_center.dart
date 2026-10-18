import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

class TaskCenterState {
  const TaskCenterState(this.tasks, {this.persistenceError});
  final List<WorkbenchTask> tasks;
  final String? persistenceError;
  bool get busy => tasks.any((t) => t.running);
}

/// Owns work independently of page lifetimes. Output and disk writes are bounded.
class TaskCenter extends StateNotifier<TaskCenterState> {
  TaskCenter(this.store) : super(const TaskCenterState([])) {
    _load();
  }
  final WorkbenchJsonStore store;
  Future<void> _writes = Future.value();
  Timer? _timer;
  int _sequence = 0;
  bool _disposed = false;
  void _load() {
    try {
      final raw = store.read();
      final rows = raw == null
          ? <WorkbenchTask>[]
          : (raw['tasks'] as List)
                .take(40)
                .map(
                  (t) => WorkbenchTask.fromJson(
                    Map<String, dynamic>.from(t as Map),
                  ),
                )
                .toList();
      state = TaskCenterState(
        rows
            .map(
              (t) => t.running
                  ? t.copy(
                      status: TaskStatus.interrupted,
                      finishedAt: DateTime.now(),
                      steps: t.steps
                          .map(
                            (s) => s.status == TaskStepStatus.running
                                ? TaskStep(
                                    s.title,
                                    status: TaskStepStatus.failed,
                                  )
                                : s,
                          )
                          .toList(),
                      verification: '应用上次退出前未收到完成结果，请检查实际状态后再操作。',
                    )
                  : t,
            )
            .toList(),
        persistenceError: store.error,
      );
    } catch (_) {
      store.readable = false;
      store.error = '任务记录格式损坏，原文件已保留。';
      state = TaskCenterState(const [], persistenceError: store.error);
    }
  }

  WorkbenchTask? find(String id) =>
      state.tasks.where((t) => t.id == id).firstOrNull;
  bool managerBusy(String manager) =>
      state.tasks.any((t) => t.manager == manager && t.running);
  bool get busy => state.busy;
  TaskHandle startMutation(String title, String manager, List<String> steps) {
    const managers = {'mise', 'Homebrew', 'Android SDK', '缓存维护', '管理器设置'};
    if (state.tasks.any((t) => t.running && managers.contains(t.manager))) {
      throw StateError('已有写操作执行中，请在任务中心查看');
    }
    return start(title, manager, steps);
  }

  TaskHandle start(String title, String manager, List<String> steps) {
    if (_disposed) throw StateError('任务中心已关闭');
    if (manager != '管理器设置' && manager != '目录扫描' && managerBusy('管理器设置')) {
      throw StateError('管理器设置正在保存，请稍后重试');
    }
    final id = '${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
    final task = WorkbenchTask(
      id: id,
      title: cleanTaskOutput(title),
      manager: manager,
      startedAt: DateTime.now(),
      steps: steps.map((s) => TaskStep(cleanTaskOutput(s))).toList(),
    );
    state = TaskCenterState([
      task,
      ...state.tasks.where((t) => t.running),
      ...state.tasks.where((t) => !t.running).take(39),
    ], persistenceError: state.persistenceError);
    _persist();
    return TaskHandle(this, id);
  }

  void update(
    String id,
    WorkbenchTask Function(WorkbenchTask) change, {
    bool immediate = false,
  }) {
    if (_disposed) return;
    state = TaskCenterState([
      for (final t in state.tasks) t.id == id ? change(t) : t,
    ], persistenceError: state.persistenceError);
    if (immediate) {
      _persist();
    } else {
      _timer ??= Timer(const Duration(milliseconds: 300), () {
        _timer = null;
        _persist();
      });
    }
  }

  void _persist() {
    final data = {
      'schema': 1,
      'tasks': state.tasks.map((t) => t.toJson()).toList(),
    };
    _writes = _writes.then((_) => store.write(data)).catchError((Object error) {
      if (!_disposed) {
        state = TaskCenterState(
          state.tasks,
          persistenceError: '任务记录保存失败：$error',
        );
      }
    });
  }

  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    _persist();
    await _writes;
  }

  @override
  void dispose() {
    if (_timer != null) {
      _timer!.cancel();
      _persist();
    }
    _disposed = true;
    super.dispose();
  }
}

class TaskHandle {
  TaskHandle(this.center, this.id);
  final TaskCenter center;
  final String id;
  String _rawOutput = '';
  void step(int index, TaskStepStatus status, {int? exitCode}) => center.update(
    id,
    (t) => t.copy(
      steps: [
        for (var i = 0; i < t.steps.length; i++)
          i == index
              ? TaskStep(t.steps[i].title, status: status, exitCode: exitCode)
              : t.steps[i],
      ],
    ),
  );
  void output(String text) => center.update(id, (t) {
    _rawOutput += text;
    if (_rawOutput.length > 65536) {
      final boundary = _rawOutput.indexOf('\n', _rawOutput.length - 32768);
      _rawOutput =
          '[较早输出已截断]\n${boundary < 0 ? '[过长单行已截断]\n' : _rawOutput.substring(boundary + 1)}';
    }
    final value = cleanTaskOutput(_rawOutput);
    return t.copy(
      output: value.length > 32768
          ? '[较早输出已截断]\n${value.substring(value.length - 32768)}'
          : value,
    );
  });
  void finish(TaskVerification result, {TaskStatus? status}) => center.update(
    id,
    (t) => t.copy(
      status:
          status ??
          (result.passed
              ? (result.warning ? TaskStatus.warning : TaskStatus.succeeded)
              : TaskStatus.failed),
      steps: [
        for (final s in t.steps)
          s.status == TaskStepStatus.pending
              ? TaskStep(s.title, status: TaskStepStatus.skipped)
              : s.status == TaskStepStatus.running
              ? TaskStep(
                  s.title,
                  status: TaskStepStatus.failed,
                  exitCode: s.exitCode,
                )
              : s,
      ],
      verification: cleanTaskOutput(result.detail),
      finishedAt: DateTime.now(),
    ),
    immediate: true,
  );
}

String cleanTaskOutput(String text) => text
    .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
    .replaceAllMapped(
      RegExp(
        r'(authorization\s*:\s*)(?:Bearer|Basic)\s+[^\s,;]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[已隐藏]',
    )
    .replaceAllMapped(
      RegExp(r'(https?://)[^\s/@]+:[^\s/@]+@'),
      (m) => '${m[1]}[已隐藏]@',
    )
    .replaceAllMapped(
      RegExp(
        r'((?:token|password|secret|authorization|api[_-]?key)\s*[:=]\s*)[^\s,;]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}[已隐藏]',
    );
