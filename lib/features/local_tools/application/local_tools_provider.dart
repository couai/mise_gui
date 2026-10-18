import 'dart:io';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/local_tool_registry.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

final localToolProcessProvider = Provider<LocalToolProcess>(
  (ref) => const SystemLocalToolProcess(),
);
final localToolRegistryProvider = Provider<LocalToolRegistry>(
  (ref) => LocalToolRegistry(
    file: File('${ToolchainLayout.current.appDir}/config/imported_tools.json'),
    process: ref.watch(localToolProcessProvider),
  ),
);
final localToolInventoryProvider = Provider<LocalToolInventory>(
  (ref) => SystemLocalToolInventory(
    layout: ref.watch(managerLayoutProvider),
    executableOverrides: {
      if (ref.watch(managerSettingsProvider).miseExecutable.isNotEmpty)
        'mise': ref.watch(managerSettingsProvider).miseExecutable,
      'homebrew': ref.watch(managerSettingsProvider).brewExecutable,
    },
    probeTimeout: Duration(
      seconds: ref.watch(managerSettingsProvider).probeTimeoutSeconds,
    ),
    fallbackBins: [
      '${ref.watch(managerSettingsProvider).homebrewPrefix}/bin',
      '/usr/bin',
      '/bin',
    ],
    process: ref.watch(localToolProcessProvider),
    loadVersions: ref.watch(classifiedToolchainServiceProvider).inventory,
    registry: ref.watch(localToolRegistryProvider),
  ),
);
final localToolOpenerProvider = Provider<LocalToolOpener>(
  (ref) => MacLocalToolOpener(ref.watch(localToolProcessProvider)),
);
final localToolsProvider = FutureProvider<LocalToolSnapshot>(
  (ref) => ref.watch(localToolInventoryProvider).scan(),
);
