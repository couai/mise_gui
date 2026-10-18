import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/directory_storage_service.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/models/workbench_task.dart';

final directoryStorageServiceProvider = Provider(
  (ref) => DirectoryStorageService(
    layout: ref.watch(managerLayoutProvider),
    homebrew: ref.watch(managerSettingsProvider).homebrewPrefix,
    reader: PosixDirectoryUsageReader(
      timeout: Duration(
        seconds: ref.watch(managerSettingsProvider).storageTimeoutSeconds,
      ),
    ),
  ),
);
final directoryScanCancellationProvider = Provider((ref) {
  ref.watch(managerSettingsProvider);
  final token = DirectoryScanCancellation();
  ref.onDispose(token.cancel);
  return token;
});
// A scan is performed on first use or explicit refresh, never on dashboard timers.
final directoryStorageProvider = StreamProvider<StorageSnapshot>((ref) async* {
  final service = ref.watch(directoryStorageServiceProvider);
  final cancellation = ref.watch(directoryScanCancellationProvider);
  final task = ref.read(taskCenterProvider.notifier).start('扫描目录与缓存', '目录扫描', [
    '读取工具档案',
    '检查目录与软链接',
    '测量磁盘占用',
    '汇总验证结果',
  ]);
  var finished = false;
  ref.onDispose(() {
    if (!finished) {
      task.finish(
        const TaskVerification(false, '扫描已停止；已读取的数据仅代表部分范围。'),
        status: TaskStatus.cancelled,
      );
    }
  });
  ref.onDispose(cancellation.cancel);
  try {
    task.step(0, TaskStepStatus.running);
    final inventory = await ref.read(localToolsProvider.future);
    if (cancellation.cancelled) {
      task.finish(
        const TaskVerification(false, '扫描已停止。'),
        status: TaskStatus.cancelled,
      );
      finished = true;
      return;
    }
    task.step(0, TaskStepStatus.succeeded);
    task.step(1, TaskStepStatus.running);
    await for (final snapshot in service.scan(inventory, cancellation)) {
      task.step(1, TaskStepStatus.succeeded);
      task.step(
        2,
        snapshot.scanning
            ? TaskStepStatus.running
            : snapshot.cancelled
            ? TaskStepStatus.skipped
            : TaskStepStatus.succeeded,
      );
      task.center.update(
        task.id,
        (t) => t.copy(
          verification: '已测量 ${snapshot.completed}/${snapshot.total} 个目标',
        ),
      );
      if (!snapshot.scanning) {
        final incomplete = snapshot.entries
            .where(
              (e) =>
                  e.usage.state == StorageUsageState.failed ||
                  e.usage.state == StorageUsageState.timeout ||
                  e.usage.state == StorageUsageState.partial,
            )
            .length;
        final detail =
            '${snapshot.completed}/${snapshot.total} 个测量目标；${snapshot.entries.where((e) => e.needsReview).length} 个路径待检查；$incomplete 个测量不完整。';
        task.step(3, TaskStepStatus.succeeded);
        task.output('$detail\n');
        task.finish(
          TaskVerification(
            !snapshot.cancelled,
            detail,
            warning:
                incomplete > 0 ||
                snapshot.warnings.isNotEmpty ||
                snapshot.entries.any((e) => e.needsReview),
          ),
          status: snapshot.cancelled ? TaskStatus.cancelled : null,
        );
        finished = true;
      }
      yield snapshot;
    }
  } catch (error) {
    task.output('$error\n');
    task.finish(TaskVerification(false, '目录扫描失败：$error'));
    finished = true;
    rethrow;
  }
});
