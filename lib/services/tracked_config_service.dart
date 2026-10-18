import 'dart:io';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/config_service.dart';
import 'package:mise_gui/services/task_center.dart';

class TrackedConfigService implements ConfigService {
  const TrackedConfigService(this.delegate, this.center);
  final ConfigService delegate;
  final TaskCenter center;
  @override
  Future<ConfigWorkspaceData> fetchWorkspace({
    String? projectPath,
    String? projectConfigPath,
    String? projectName,
    bool includeProjectConfig = true,
  }) => delegate.fetchWorkspace(
    projectPath: projectPath,
    projectConfigPath: projectConfigPath,
    projectName: projectName,
    includeProjectConfig: includeProjectConfig,
  );
  @override
  Future<ConfigSavePreview> previewDocumentSave({
    required ConfigDocumentData document,
    required String nextContent,
  }) => delegate.previewDocumentSave(
    document: document,
    nextContent: nextContent,
  );
  @override
  Future<ConfigSavePreview> previewRuntimeSettingsSave({
    required ConfigRuntimeSettingsUpdate update,
  }) => delegate.previewRuntimeSettingsSave(update: update);
  @override
  Future<ConfigSavePreview> previewProxySettingsSave({
    required ConfigProxySettingsUpdate update,
  }) => delegate.previewProxySettingsSave(update: update);
  @override
  Future<void> saveDocument({
    required ConfigDocumentData document,
    required String nextContent,
  }) async {
    if (center.managerBusy('mise')) throw StateError('已有 mise 任务执行中，请稍后保存配置');
    final task = center.startMutation(
      '保存 mise 配置 · ${document.title}',
      'mise',
      ['检查文件状态', '写入配置', '回读验证'],
    );
    task.step(0, TaskStepStatus.running);
    try {
      final file = File(document.path);
      final exists = await file.exists();
      if (exists != document.exists ||
          (exists && await file.readAsString() != document.content)) {
        throw StateError('配置已被其他程序修改，请刷新后重新编辑。');
      }
      task.step(0, TaskStepStatus.succeeded);
      task.step(1, TaskStepStatus.running);
      await delegate.saveDocument(document: document, nextContent: nextContent);
      task.step(1, TaskStepStatus.succeeded);
      task.step(2, TaskStepStatus.running);
      final normalized = nextContent.replaceAll('\r\n', '\n').trimRight();
      if (await file.readAsString() !=
          (normalized.isEmpty ? '' : '$normalized\n')) {
        throw StateError('配置回读结果与保存内容不一致');
      }
      task.step(2, TaskStepStatus.succeeded);
      task.output('已保存并回读：${document.path}\n');
      task.finish(const TaskVerification(true, '配置内容回读一致。'));
    } catch (error) {
      task.output('$error\n');
      task.finish(TaskVerification(false, '配置保存或验证失败：$error'));
      rethrow;
    }
  }
}
