import 'package:file_selector/file_selector.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/models/app_models.dart';

final toolsProvider = FutureProvider<List<ToolRecord>>((ref) {
  return ref.watch(toolsRepositoryProvider).loadTools();
});

final toolDetailProvider = FutureProvider.family<ToolRecord, String>((
  ref,
  toolId,
) async {
  final tools = await ref.watch(toolsProvider.future);
  final baseTool = tools.firstWhere((tool) => tool.id == toolId);
  return ref.watch(toolsRepositoryProvider).hydrateToolRemoteState(baseTool);
});

/// The picker is injectable so scope-changing flows can be verified in isolation.
final projectDirectoryPickerProvider = Provider<Future<String?> Function()>(
  (ref) =>
      () => getDirectoryPath(confirmButtonText: '选择项目'),
);
