import 'dart:io';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/features/local_tools/application/local_tools_provider.dart';
import 'package:mise_gui/features/settings/application/manager_settings_provider.dart';
import 'package:mise_gui/features/storage/application/storage_provider.dart';
import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/manager_check_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/tracked_mise_action_service.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

class ProbeRecorder implements LocalToolProcess {
  final calls = <(String, List<String>, Map<String, String>, Duration)>[];
  bool failBrew = false;
  @override
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    calls.add((executable, arguments, environment, timeout));
    return LocalCommandResult(
      failBrew && executable.endsWith('/brew') ? 1 : 0,
      '1.2.3\n',
      '',
    );
  }
}

void main() {
  late Directory temp;
  late ToolchainLayout layout;
  late ManagerSettings settings;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('devworkbench-managers-');
    layout = ToolchainLayout(home: temp.resolveSymbolicLinksSync());
    for (final sub in [
      'bin',
      'brew',
      'sdk/cmdline-tools/latest/bin',
      'Xcode.app/Contents/Developer/usr/bin',
    ]) {
      Directory('${temp.path}/$sub').createSync(recursive: true);
    }
    for (final name in ['mise', 'brew']) {
      final file = File('${temp.path}/bin/$name')
        ..writeAsStringSync('#!/bin/sh\nprintf "1.2.3\\n"\n');
      await Process.run('/bin/chmod', ['700', file.path]);
    }
    settings = ManagerSettings(
      miseExecutable: '${temp.path}/bin/mise',
      brewExecutable: '${temp.path}/bin/brew',
      homebrewPrefix: '${temp.path}/brew',
      androidSdk: '${temp.path}/sdk',
      xcodeDeveloper: '${temp.path}/Xcode.app/Contents/Developer',
      miseOffline: true,
      actionTimeoutMinutes: 7,
      probeTimeoutSeconds: 9,
      storageTimeoutSeconds: 12,
    );
  });
  tearDown(() => temp.delete(recursive: true));
  test(
    'validated settings persist atomically with private permissions and round trip',
    () async {
      final file = File('${temp.path}/config/managers.json');
      final controller = ManagerSettingsController(
        WorkbenchJsonStore(file),
        layout,
      );
      await controller.save(settings);
      final loaded = ManagerSettingsController(
        WorkbenchJsonStore(file),
        layout,
      );
      expect(loaded.state.toJson(), settings.toJson());
      expect(file.statSync().mode & 0x1ff, 0x180);
      expect(file.parent.listSync().length, 1);
      controller.dispose();
      loaded.dispose();
    },
  );
  test(
    'invalid paths or timeout values retain the previous configuration',
    () async {
      final file = File('${temp.path}/managers.json');
      final c = ManagerSettingsController(WorkbenchJsonStore(file), layout);
      await c.save(settings);
      final before = file.readAsStringSync();
      final invalid = ManagerSettings.fromJson({
        ...settings.toJson(),
        'brewExecutable': '/absent/brew',
      });
      await expectLater(c.save(invalid), throwsArgumentError);
      final flag = ManagerSettings.fromJson({
        ...settings.toJson(),
        'miseExecutable': '/bin/mise --yes',
      });
      await expectLater(c.save(flag), throwsArgumentError);
      expect(
        () => ManagerSettings.fromJson({
          ...settings.toJson(),
          'probeTimeoutSeconds': 999,
        }).validate(),
        throwsArgumentError,
      );
      expect(file.readAsStringSync(), before);
      expect(c.state.toJson(), settings.toJson());
      c.dispose();
    },
  );
  test(
    'corrupt settings retain the original file and block replacement',
    () async {
      final file = File('${temp.path}/managers.json')
        ..writeAsStringSync('{bad');
      final c = ManagerSettingsController(WorkbenchJsonStore(file), layout);
      expect(c.store.error, isNotNull);
      await expectLater(c.save(settings), throwsStateError);
      expect(file.readAsStringSync(), '{bad');
      c.dispose();
    },
  );
  test(
    'saved settings reach actual command, inventory and storage services',
    () async {
      final container = ProviderContainer(
        overrides: [
          managerSettingsStoreProvider.overrideWithValue(
            WorkbenchJsonStore(null),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(managerSettingsProvider.notifier).save(settings);
      final process =
          container.read(miseProcessServiceProvider) as LocalMiseProcessService;
      expect(await process.resolveExecutablePath(), settings.miseExecutable);
      expect(process.environmentOverrides['ANDROID_HOME'], settings.androidSdk);
      final actions =
          container.read(miseActionServiceProvider) as TrackedMiseActionService;
      expect(
        (actions.delegate as LocalMiseActionService).timeout,
        const Duration(minutes: 7),
      );
      final inventory =
          container.read(localToolInventoryProvider)
              as SystemLocalToolInventory;
      expect(
        inventory.executableOverrides['homebrew'],
        settings.brewExecutable,
      );
      expect(inventory.probeTimeout, const Duration(seconds: 9));
      expect(
        inventory.layout.environment['DEVELOPER_DIR'],
        settings.xcodeDeveloper,
      );
      expect(
        container.read(directoryStorageServiceProvider).homebrew,
        settings.homebrewPrefix,
      );
    },
  );
  test(
    'explicit paths and environment survive preferShellExecution without interpolation',
    () async {
      final script = File('${temp.path}/bin/custom mise')
        ..writeAsStringSync(
          '#!/bin/sh\nprintf "%s\\n" "\$MISE_OFFLINE" "\$ANDROID_HOME" "\$DEVELOPER_DIR" "\$1"\n',
        );
      await Process.run('/bin/chmod', ['700', script.path]);
      final service = LocalMiseProcessService(
        executablePath: script.path,
        environmentOverrides: settings.environment,
      );
      final result = await service.run(
        const MiseCommandRequest(
          arguments: ['literal \$(echo unsafe)'],
          preferShellExecution: true,
        ),
      );
      expect(result.stdout.trim().split('\n'), [
        '1',
        settings.androidSdk,
        settings.xcodeDeveloper,
        'literal \$(echo unsafe)',
      ]);
    },
  );
  test(
    'manager checks use only fixed version commands and continue after a failure',
    () async {
      final recorder = ProbeRecorder()..failBrew = true;
      final center = TaskCenter(WorkbenchJsonStore(null));
      await ManagerCheckService(
        recorder,
        LocalMiseProcessService(executablePath: settings.miseExecutable),
      ).check(settings, layout, center);
      expect(recorder.calls.map((c) => c.$2), [
        ['--version'],
        ['--version'],
        ['--version'],
        ['-version'],
      ]);
      expect(
        recorder.calls[2].$1,
        '${settings.androidSdk}/cmdline-tools/latest/bin/sdkmanager',
      );
      expect(
        recorder.calls.every((c) => c.$4 == const Duration(seconds: 9)),
        isTrue,
      );
      expect(
        recorder.calls.every((c) => c.$3['HOMEBREW_NO_AUTO_UPDATE'] == '1'),
        isTrue,
      );
      expect(center.state.tasks.first.steps[2].status, TaskStepStatus.failed);
      expect(
        center.state.tasks.first.steps[4].status,
        TaskStepStatus.succeeded,
      );
      expect(center.state.tasks.first.status, TaskStatus.failed);
      center.dispose();
    },
  );
}
