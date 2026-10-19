import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/project_environment_service.dart';

Future<ProjectEnvironment> checkProjectEnvironment(
  ProjectEnvironmentService service,
  TaskCenter center,
  String path,
  Future<LocalToolSnapshot> local,
) async {
  final task = center.start('检查项目环境：${path.split('/').last}', '项目环境', [
    '读取项目声明',
    '对照本地工具与项目版本',
    '记录验证结果',
  ]);
  task.step(0, TaskStepStatus.running);
  try {
    final snapshot = await local;
    await service.profiles.inspect(path);
    task.step(0, TaskStepStatus.succeeded);
    task.step(1, TaskStepStatus.running);
    final result = await service.inspect(path, snapshot);
    task.output('项目：${result.profile.path}\n');
    for (final check in result.checks) {
      task.output('${check.tool}: ${check.state.label}\n');
    }
    for (final venv in result.pythonEnvironments) {
      task.output(
        'Python 环境：${venv.path} · ${venv.selected ? '已选择' : '候选'} · ${venv.issue == null ? '已读取' : '待核对'}\n',
      );
    }
    for (final module in result.modules) {
      task.output(
        '${module.module.manager} 模块 ${module.module.name}: ${module.state.label}\n',
      );
    }
    task.step(1, TaskStepStatus.succeeded);
    final passed =
        result.issueCount == 0 &&
        result.queryIssue == null &&
        result.profile.warnings.isEmpty;
    task.step(2, passed ? TaskStepStatus.succeeded : TaskStepStatus.failed);
    task.finish(
      TaskVerification(
        passed,
        passed ? '工具与已识别版本要求符合；未执行依赖安装或构建。' : '存在缺少工具、未满足的版本或待核对声明，请查看项目环境。',
      ),
      status: passed ? null : TaskStatus.warning,
    );
    return result;
  } catch (_) {
    task.finish(const TaskVerification(false, '项目检查未完成，请检查项目路径及工具状态。'));
    rethrow;
  }
}
