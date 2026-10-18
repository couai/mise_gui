import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/services/maintenance_process.dart';
import 'package:mise_gui/services/managed_package_catalog.dart';
import 'package:mise_gui/services/maintenance_service.dart';

final maintenanceProcessProvider = Provider<MaintenanceProcess>(
  (ref) => const SystemMaintenanceProcess(),
);
final managedPackageCatalogProvider = Provider(
  (ref) => ManagedPackageCatalog(
    ref.watch(maintenanceProcessProvider),
    ref.watch(managerLayoutProvider),
    ref.watch(managerSettingsProvider),
  ),
);
final maintenanceServiceProvider = Provider(
  (ref) => MaintenanceService(
    ref.watch(managedPackageCatalogProvider),
    ref.watch(classifiedToolchainServiceProvider),
    ref.read(taskCenterProvider.notifier),
  ),
);
final maintenanceSnapshotProvider = FutureProvider<MaintenanceSnapshot>(
  (ref) => ref.watch(managedPackageCatalogProvider).installed(),
);
