import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

final localToolProcessProvider = Provider<LocalToolProcess>(
  (ref) => const SystemLocalToolProcess(),
);
final localToolInventoryProvider = Provider<LocalToolInventory>(
  (ref) => SystemLocalToolInventory(
    layout: ToolchainLayout.current,
    process: ref.watch(localToolProcessProvider),
    loadVersions: ref.watch(classifiedToolchainServiceProvider).inventory,
  ),
);
final localToolOpenerProvider = Provider<LocalToolOpener>(
  (ref) => MacLocalToolOpener(ref.watch(localToolProcessProvider)),
);
final localToolsProvider = FutureProvider<LocalToolSnapshot>(
  (ref) => ref.watch(localToolInventoryProvider).scan(),
);
