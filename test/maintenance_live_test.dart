import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/maintenance_process.dart';
import 'package:mise_gui/services/managed_package_catalog.dart';
import 'package:mise_gui/services/maintenance_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

void main() {
  test(
    'read-only local maintenance acceptance loads actual receipts and previews scoped operations',
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
      final catalog = ManagedPackageCatalog(
        const SystemMaintenanceProcess(),
        layout,
        settings.state,
      );
      final tasks = TaskCenter(WorkbenchJsonStore(null));
      try {
        final snapshot = await catalog.installed();
        stdout.writeln(
          '${snapshot.packages.length} owned package receipts; warnings=${snapshot.warnings}',
        );
        expect(snapshot.warnings, isEmpty);
        expect(
          snapshot.packages.any(
            (p) => p.manager == MaintenanceManager.formula && p.id == 'wget',
          ),
          isTrue,
        );
        expect(
          snapshot.packages.any((p) => p.id == 'platforms;android-33'),
          isTrue,
        );
        final service = MaintenanceService(
          catalog,
          ClassifiedToolchainService(
            LocalMiseProcessService(
              environmentOverrides: settings.state.environment,
            ),
            layout,
          ),
          tasks,
        );
        final uninstall = await service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.formula,
            MaintenanceAction.uninstall,
            'wget',
          ),
        );
        stdout.writeln(
          'Read-only preview: ${uninstall.commands.single.display}',
        );
        for (final id in MaintenanceService.cacheIds) {
          final plan = await service.prepare(
            MaintenanceRequest(
              MaintenanceManager.cache,
              MaintenanceAction.clean,
              id,
            ),
          );
          stdout.writeln(
            'Read-only cache preview: ${plan.commands.single.display}',
          );
        }
        expect(tasks.state.tasks, isEmpty);
      } finally {
        settings.dispose();
        tasks.dispose();
      }
    },
    skip: Platform.environment['DEVWORKBENCH_LIVE_MAINTENANCE'] != '1',
  );
}
