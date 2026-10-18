import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Keeps the operation and postcondition checks alive when a page is hidden.
class TrackedMiseActionService implements MiseActionService {
  TrackedMiseActionService(this.delegate, this.center, this.policy);
  final MiseActionService delegate;
  final TaskCenter center;
  final ClassifiedToolchainService policy;
  @override
  Future<MiseActionResult> runScript(
    String script, {
    String? workingDirectory,
    void Function(MiseActionProgressEvent)? onProgress,
  }) async {
    if (center.managerBusy('mise')) throw StateError('已有 mise 任务执行中，请在任务中心查看');
    var lines = const LineSplitter()
        .convert(script)
        .where((s) => s.trim().isNotEmpty && !s.trim().startsWith('#'))
        .toList();
    final task = center.startMutation(_title(script), 'mise', [
      '检查操作计划',
      ...lines,
      '验证安装与版本选择',
    ]);
    task.step(0, TaskStepStatus.running);
    try {
      final prepared = await policy.prepare(script);
      lines = const LineSplitter()
          .convert(prepared)
          .where((s) => s.trim().isNotEmpty && !s.trim().startsWith('#'))
          .toList();
      center.update(
        task.id,
        (t) => t.copy(
          steps: [
            const TaskStep('检查操作计划', status: TaskStepStatus.succeeded),
            ...lines.map((line) => TaskStep(line)),
            const TaskStep('验证安装与版本选择'),
          ],
        ),
      );
      final result = await delegate.runScript(
        prepared,
        workingDirectory: workingDirectory,
        onProgress: (event) {
          task.step(0, TaskStepStatus.succeeded);
          final index = event.commandIndex;
          switch (event.type) {
            case MiseActionProgressEventType.commandStarted:
              task.step(index, TaskStepStatus.running);
              task.output('\n\$ ${event.command}\n');
            case MiseActionProgressEventType.output:
              task.output(event.output ?? '');
            case MiseActionProgressEventType.commandFinished:
              task.step(
                index,
                event.exitCode == 0
                    ? TaskStepStatus.succeeded
                    : TaskStepStatus.failed,
                exitCode: event.exitCode,
              );
              task.output('\nexit ${event.exitCode}\n');
            case MiseActionProgressEventType.lockfileCleanup:
              task.output(event.lockfileCleanupReport?.detail ?? '');
          }
          onProgress?.call(event);
        },
      );
      if (!result.isSuccess) {
        task.finish(
          TaskVerification(false, '命令执行失败（exit ${result.exitCode}），后续步骤未执行。'),
        );
        return result;
      }
      task.step(lines.length + 1, TaskStepStatus.running);
      final verification = await verifyMisePostconditions(
        policy,
        prepared,
        workingDirectory: workingDirectory,
      );
      task.step(
        lines.length + 1,
        verification.passed ? TaskStepStatus.succeeded : TaskStepStatus.failed,
      );
      task.output('\n[验证] ${verification.detail}\n');
      task.finish(verification);
      return MiseActionResult(
        script: result.script,
        commands: result.commands,
        lockfileCleanupReport: result.lockfileCleanupReport,
        verification: verification,
      );
    } catch (error) {
      final current = center.find(task.id);
      for (var i = 0; i < (current?.steps.length ?? 0); i++) {
        if (current!.steps[i].status == TaskStepStatus.running) {
          task.step(i, TaskStepStatus.failed);
        }
      }
      task.output('\n$error\n');
      task.finish(TaskVerification(false, '执行或验证异常：$error'));
      rethrow;
    }
  }

  String _title(String script) {
    final args = parseCommandArguments(script.split('\n').first);
    return '${args.contains('use') ? '切换版本' : '安装并注册版本'} · ${args.where((s) => s.contains('@')).firstOrNull ?? 'mise'}';
  }
}

Future<TaskVerification> verifyMisePostconditions(
  ClassifiedToolchainService policy,
  String script, {
  String? workingDirectory,
}) async {
  final installed = await policy.inventory();
  final checks = <String>[];
  for (final line in const LineSplitter().convert(script)) {
    if (line.trim().isEmpty || line.trim().startsWith('#')) continue;
    final args = parseCommandArguments(line);
    final spec = args.where((a) => RegExp(r'^[a-z]+@').hasMatch(a)).firstOrNull;
    if (spec == null) continue;
    final split = spec.indexOf('@');
    final tool = spec.substring(0, split), version = spec.substring(split + 1);
    final match = installed
        .where((v) => v.tool == tool && v.version == version && v.classified)
        .firstOrNull;
    if (match == null ||
        !await Directory(match.rustSdkPath ?? match.actualPath).exists()) {
      return TaskVerification(false, '$spec 未通过分类目录与 mise 注册校验。');
    }
    final binary = {
      'java': 'java',
      'node': 'node',
      'python': 'python3',
      'go': 'go',
      'rust': 'rustc',
      'flutter': 'flutter',
    }[tool];
    if (binary == null ||
        !await File(
          '${match.rustSdkPath ?? match.actualPath}/bin/$binary',
        ).exists()) {
      return TaskVerification(false, '$spec 的 SDK 程序缺失。');
    }
    if (args.contains('use')) {
      final pathIndex = args.indexOf('--path');
      final cwd = pathIndex >= 0
          ? File(args[pathIndex + 1]).parent.path
          : policy.layout.home;
      final result = await policy.process.run(
        MiseCommandRequest(
          arguments: const ['ls', '--json'],
          workingDirectory: cwd,
        ),
      );
      final rows = (jsonDecode(result.stdout) as Map)[tool] as List? ?? [];
      if (!rows.any(
        (row) =>
            row['installed'] == true &&
            row['active'] == true &&
            row['version'] == version,
      )) {
        return TaskVerification(
          false,
          '$spec 已安装，但${pathIndex >= 0 ? '项目' : '全局'}版本选择验证失败。',
        );
      }
      checks.add('$spec 作用域选择通过');
    } else {
      checks.add('$spec 注册与分类目录通过');
    }
  }
  return TaskVerification(
    checks.isNotEmpty,
    checks.isEmpty ? '没有可验证的版本目标。' : checks.toSet().join('\n'),
  );
}
