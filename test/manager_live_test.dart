import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/manager_check_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

// Explicit local acceptance: writes only the app's own preferences/task records.
// Ordinary tests skip this and use isolated stores.
void main() {
  test(
    'local manager acceptance saves settings and records actual version checks',
    () async {
      final shell = await const LocalMiseProcessService()
          .inspectShellEnvironment();
      final layout = ToolchainLayout(
        home: Platform.environment['HOME']!,
        environment: {...Platform.environment, ...?shell.environment},
      );
      final settings = ManagerSettingsController(
        WorkbenchJsonStore(File('${layout.appDir}/config/managers.json')),
        layout,
      );
      final center = TaskCenter(
        WorkbenchJsonStore(File('${layout.appDir}/state/tasks.json')),
      );
      try {
        expect(settings.store.error, isNull);
        final save = center.start('保存管理器配置', '管理器设置', [
          '验证配置路径',
          '保存当前设置',
          '回读配置',
        ]);
        save.step(0, TaskStepStatus.running);
        await settings.state.validatePaths();
        save.step(0, TaskStepStatus.succeeded);
        save.step(1, TaskStepStatus.running);
        await settings.save(settings.state);
        save.step(1, TaskStepStatus.succeeded);
        save.step(2, TaskStepStatus.running);
        final reloaded = ManagerSettingsController(
          WorkbenchJsonStore(File('${layout.appDir}/config/managers.json')),
          layout,
        );
        expect(reloaded.state.toJson(), settings.state.toJson());
        reloaded.dispose();
        save.step(2, TaskStepStatus.succeeded);
        save.finish(const TaskVerification(true, '当前管理器路径与选项已保存，配置回读一致。'));
        await ManagerCheckService(
          const SystemLocalToolProcess(),
          LocalMiseProcessService(
            environmentOverrides: settings.state.environment,
          ),
        ).check(settings.state, layout, center);
        await center.flush();
        final task = center.state.tasks.first;
        stdout.writeln(task.output);
        stdout.writeln(task.verification);
        expect(task.status, TaskStatus.succeeded);
      } finally {
        await center.flush();
        center.dispose();
        settings.dispose();
      }
    },
    skip: Platform.environment['DEVWORKBENCH_LIVE_MANAGERS'] != '1',
  );
}
