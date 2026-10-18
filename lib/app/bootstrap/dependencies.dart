import 'dart:ui';
import 'package:mise_gui/services/tracked_config_service.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/services/tracked_mise_action_service.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/repositories/config_repository.dart';
import 'package:mise_gui/repositories/dashboard_repository.dart';
import 'package:mise_gui/repositories/projects_repository.dart';
import 'package:mise_gui/repositories/tools_repository.dart';
import 'package:mise_gui/services/app_release_service.dart';
import 'package:mise_gui/services/config_service.dart';
import 'package:mise_gui/services/config_watch_service.dart';
import 'package:mise_gui/services/desktop_window_service.dart';
import 'package:mise_gui/services/history_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/mise_cli_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_scan_service.dart';
import 'package:mise_gui/services/scan_directory_service.dart';

enum AppThemePreference { system, light, dark }

ThemeMode resolveSystemThemeMode() {
  try {
    final brightness = PlatformDispatcher.instance.platformBrightness;
    return brightness == Brightness.light ? ThemeMode.light : ThemeMode.dark;
  } catch (_) {
    return ThemeMode.dark;
  }
}

final systemThemeModeProvider = StateProvider<ThemeMode>(
  (ref) => resolveSystemThemeMode(),
);

final themePreferenceProvider = StateProvider<AppThemePreference>(
  (ref) => AppThemePreference.system,
);

final themeModeProvider = Provider<ThemeMode>((ref) {
  final preference = ref.watch(themePreferenceProvider);
  final systemThemeMode = ref.watch(systemThemeModeProvider);

  return switch (preference) {
    AppThemePreference.system => systemThemeMode,
    AppThemePreference.light => ThemeMode.light,
    AppThemePreference.dark => ThemeMode.dark,
  };
});

final appReleaseServiceProvider = Provider<AppReleaseService>(
  (ref) => const PackageInfoAppReleaseService(),
);

final appVersionInfoProvider = FutureProvider<AppVersionInfo>(
  (ref) => ref.watch(appReleaseServiceProvider).load(),
);

final desktopWindowServiceProvider = Provider<DesktopWindowService>(
  (ref) => const MethodChannelDesktopWindowService(),
);

final miseAvailableProvider = FutureProvider<bool>((ref) async {
  final processService = ref.watch(miseProcessServiceProvider);

  try {
    await processService.run(
      const MiseCommandRequest(
        arguments: ['--version'],
        timeout: Duration(seconds: 5),
      ),
    );
    return true;
  } catch (error) {
    if (isMiseCommandUnavailable(error)) {
      return false;
    }
    rethrow;
  }
});

final miseProcessServiceProvider = Provider<MiseProcessService>((ref) {
  final settings = ref.watch(managerSettingsProvider);
  return LocalMiseProcessService(
    executablePath: settings.miseExecutable.isEmpty
        ? null
        : settings.miseExecutable,
    environmentOverrides: settings.environment,
  );
});

final miseQueryServiceProvider = Provider<MiseQueryService>(
  (ref) => CliMiseQueryService(ref.watch(miseProcessServiceProvider)),
);

final classifiedToolchainServiceProvider = Provider<ClassifiedToolchainService>(
  (ref) => ClassifiedToolchainService(
    ref.watch(miseProcessServiceProvider),
    ref.watch(managerLayoutProvider),
  ),
);

final miseActionServiceProvider = Provider<MiseActionService>(
  (ref) => TrackedMiseActionService(
    LocalMiseActionService(
      ref.watch(miseProcessServiceProvider),
      policy: ref.watch(classifiedToolchainServiceProvider),
      timeout: Duration(
        minutes: ref.watch(managerSettingsProvider).actionTimeoutMinutes,
      ),
    ),
    ref.read(taskCenterProvider.notifier),
    ref.watch(classifiedToolchainServiceProvider),
  ),
);

final miseCliServiceProvider = Provider<MiseCliService>(
  (ref) => LiveMiseCliService(
    queryService: ref.watch(miseQueryServiceProvider),
    processService: ref.watch(miseProcessServiceProvider),
  ),
);

final configServiceProvider = Provider<ConfigService>(
  (ref) => TrackedConfigService(
    const LiveConfigService(),
    ref.read(taskCenterProvider.notifier),
  ),
);

final configWatchServiceProvider = Provider<ConfigWatchService>(
  (ref) => const LocalConfigWatchService(),
);

final projectScanServiceProvider = Provider<ProjectScanService>(
  (ref) =>
      LiveProjectScanService(queryService: ref.watch(miseQueryServiceProvider)),
);

final scanDirectoryServiceProvider = Provider<ScanDirectoryService>(
  (ref) => const LocalScanDirectoryService(),
);

final historyServiceProvider = Provider<HistoryService>(
  (ref) => const LocalHistoryService(),
);

final toolsRepositoryProvider = Provider<ToolsRepository>(
  (ref) => ToolsRepository(ref.watch(miseCliServiceProvider)),
);

final projectsRepositoryProvider = Provider<ProjectsRepository>(
  (ref) => ProjectsRepository(
    ref.watch(projectScanServiceProvider),
    ref.watch(scanDirectoryServiceProvider),
  ),
);

final configRepositoryProvider = Provider<ConfigRepository>(
  (ref) => ConfigRepository(ref.watch(configServiceProvider)),
);

final dashboardRepositoryProvider = Provider<DashboardRepository>(
  (ref) => DashboardRepository(
    miseCliService: ref.watch(miseCliServiceProvider),
    projectsRepository: ref.watch(projectsRepositoryProvider),
    processService: ref.watch(miseProcessServiceProvider),
    historyService: ref.watch(historyServiceProvider),
  ),
);
