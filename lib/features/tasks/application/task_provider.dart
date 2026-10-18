import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

final taskStoreProvider = Provider(
  (ref) => WorkbenchJsonStore(
    File('${ToolchainLayout.current.appDir}/state/tasks.json'),
  ),
);
final taskCenterProvider = StateNotifierProvider<TaskCenter, TaskCenterState>(
  (ref) => TaskCenter(ref.watch(taskStoreProvider)),
);
