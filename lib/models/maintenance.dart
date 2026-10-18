import 'package:mise_gui/services/toolchain_layout.dart';

enum MaintenanceManager {
  formula('Homebrew CLI'),
  cask('Homebrew 应用'),
  android('Android SDK'),
  cache('缓存维护');

  const MaintenanceManager(this.label);
  final String label;
  String get taskManager =>
      this == formula || this == cask ? 'Homebrew' : label;
}

enum MaintenanceAction {
  install('安装'),
  update('更新'),
  uninstall('卸载'),
  clean('清理缓存');

  const MaintenanceAction(this.label);
  final String label;
}

String? maintenanceRestriction(
  MaintenanceManager manager,
  MaintenanceAction action,
  String id,
) {
  if (manager == MaintenanceManager.formula ||
      manager == MaintenanceManager.cask) {
    if (RegExp(
      r'^(?:mise|devworkbench|xcode|node|nodejs|npm|pnpm|python|python3|go|rust|rustup|rustup-init|java|jdk|oracle-jdk|openjdk|temurin|zulu|flutter|dart)(?:@.*)?$',
    ).hasMatch(id.split('/').last)) {
      return '保留原管理方式；运行时使用 mise 版本管理，mise 本体与 Xcode 在应用外维护。';
    }
  }
  if (manager == MaintenanceManager.android &&
      action == MaintenanceAction.uninstall &&
      (id == 'platform-tools' ||
          id == 'emulator' ||
          id.startsWith('cmdline-tools;'))) {
    return '保留 SDK 管理与设备启动的基础组件，请在 Android Studio 中处理。';
  }
  return null;
}

class ManagedPackage {
  const ManagedPackage({
    required this.manager,
    required this.id,
    required this.version,
    this.latest,
    this.location,
    this.pinned = false,
    this.dependencies = const [],
  });
  final MaintenanceManager manager;
  final String id, version;
  final String? latest, location;
  final bool pinned;
  final List<String> dependencies;
  String get key => '${manager.name}:$id';
}

class MaintenanceSnapshot {
  const MaintenanceSnapshot(this.packages, {this.warnings = const []});
  final List<ManagedPackage> packages;
  final List<String> warnings;
}

class MaintenanceRequest {
  const MaintenanceRequest(this.manager, this.action, this.target);
  final MaintenanceManager manager;
  final MaintenanceAction action;
  final String target;
}

class MaintenanceCommand {
  const MaintenanceCommand(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
  String get display => [executable, ...arguments].map(quoteArgument).join(' ');
}

class MaintenancePlan {
  const MaintenancePlan({
    required this.request,
    required this.commands,
    required this.paths,
    required this.identity,
    required this.notes,
    this.beforeVersion,
    this.targetVersion,
    this.previewOutput = '',
  });
  final MaintenanceRequest request;
  final List<MaintenanceCommand> commands;
  final List<String> paths, notes;
  final String identity, previewOutput;
  final String? beforeVersion, targetVersion;
  String get title => '${request.action.label} · ${request.target}';
}
