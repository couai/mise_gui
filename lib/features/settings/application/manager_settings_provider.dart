import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

final managerSettingsStoreProvider = Provider(
  (ref) => WorkbenchJsonStore(
    File('${ToolchainLayout.current.appDir}/config/managers.json'),
  ),
);
final managerSettingsProvider =
    StateNotifierProvider<ManagerSettingsController, ManagerSettings>(
      (ref) => ManagerSettingsController(
        ref.watch(managerSettingsStoreProvider),
        ToolchainLayout.current,
      ),
    );

class ManagerSettingsController extends StateNotifier<ManagerSettings> {
  ManagerSettingsController(this.store, this.layout)
    : super(ManagerSettings.defaults(layout)) {
    try {
      final raw = store.read();
      if (raw != null) {
        final value = ManagerSettings.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        value.validate();
        state = value;
      }
    } catch (_) {
      store.readable = false;
      store.error = '管理器配置格式损坏，原文件已保留。';
    }
  }
  final WorkbenchJsonStore store;
  final ToolchainLayout layout;
  bool _saving = false;
  Future<void> save(ManagerSettings value) async {
    if (_saving) throw StateError('配置正在保存');
    _saving = true;
    try {
      await value.validatePaths();
      await store.write(value.toJson());
      state = value;
    } finally {
      _saving = false;
    }
  }
}

final managerLayoutProvider = Provider((ref) {
  final settings = ref.watch(managerSettingsProvider);
  return ToolchainLayout(
    home: ToolchainLayout.current.home,
    environment: {
      ...ToolchainLayout.current.environment,
      ...settings.environment,
      'DEVWORKBENCH_HOMEBREW_PREFIX': settings.homebrewPrefix,
    },
  );
});
