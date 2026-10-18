import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/features/tasks/application/task_provider.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

// UI tests never read or write the user's task history or manager preferences.
List<Override> isolatedWorkbenchOverrides() => [
  taskStoreProvider.overrideWithValue(WorkbenchJsonStore(null)),
  managerSettingsStoreProvider.overrideWithValue(WorkbenchJsonStore(null)),
];
