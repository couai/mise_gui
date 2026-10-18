import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class ManagerCheckService {
  const ManagerCheckService(this.process, this.mise);
  final LocalToolProcess process;
  final MiseProcessService mise;
  Future<void> check(
    ManagerSettings settings,
    ToolchainLayout layout,
    TaskCenter center,
  ) async {
    if (center.managerBusy('管理器检查')) throw StateError('管理器检查正在进行');
    final task = center.start('检查管理器配置', '管理器检查', [
      '检查路径与选项',
      'mise 版本',
      'Homebrew 版本',
      'Android SDK 管理器',
      'Xcode 工具链',
      '汇总验证结果',
    ]);
    var failed = false;
    task.step(0, TaskStepStatus.running);
    try {
      await settings.validatePaths();
      task.step(0, TaskStepStatus.succeeded);
      final executable = settings.miseExecutable.isEmpty
          ? await mise.resolveExecutablePath()
          : settings.miseExecutable;
      final commands = [
        (executable, const ['--version']),
        (settings.brewExecutable, const ['--version']),
        (
          '${settings.androidSdk}/cmdline-tools/latest/bin/sdkmanager',
          const ['--version'],
        ),
        ('${settings.xcodeDeveloper}/usr/bin/xcodebuild', const ['-version']),
      ];
      for (var i = 0; i < commands.length; i++) {
        task.step(i + 1, TaskStepStatus.running);
        final (program, args) = commands[i];
        task.output('\n\$ $program ${args.join(' ')}\n');
        try {
          final result = await process.run(
            program,
            args,
            environment: {
              ...layout.environment,
              ...settings.environment,
              'MISE_AUTO_INSTALL': '0',
              'MISE_NOT_FOUND_AUTO_INSTALL': '0',
              'RUSTUP_AUTO_INSTALL': '0',
            },
            workingDirectory: layout.home,
            timeout: Duration(seconds: settings.probeTimeoutSeconds),
          );
          task.output(
            '${result.stdout}${result.stderr}\nexit ${result.exitCode}\n',
          );
          final passed =
              result.exitCode == 0 &&
              '${result.stdout}${result.stderr}'.trim().isNotEmpty;
          failed |= !passed;
          task.step(
            i + 1,
            passed ? TaskStepStatus.succeeded : TaskStepStatus.failed,
            exitCode: result.exitCode,
          );
        } catch (error) {
          failed = true;
          task.step(i + 1, TaskStepStatus.failed);
          task.output('$error\n');
        }
      }
      task.step(5, failed ? TaskStepStatus.failed : TaskStepStatus.succeeded);
      task.finish(
        TaskVerification(
          !failed,
          failed ? '部分管理器检查失败，请根据步骤输出核对路径、许可或运行依赖。' : '四个管理器均返回版本信息，配置路径可用。',
        ),
      );
    } catch (error) {
      task.step(0, TaskStepStatus.failed);
      task.output('$error\n');
      task.finish(TaskVerification(false, '路径检查失败：$error'));
    }
  }
}
