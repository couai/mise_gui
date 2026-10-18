import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/maintenance_process.dart';
import 'package:mise_gui/services/managed_package_catalog.dart';
import 'package:mise_gui/services/maintenance_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/workbench_json_store.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/models/storage_models.dart';

class ChangingUsage implements DirectoryUsageReader {
  ChangingUsage(this.change);
  final void Function() change;
  @override
  Future<StorageUsage> measure(
    String path,
    DirectoryScanCancellation cancellation,
  ) async {
    change();
    return const StorageUsage(StorageUsageState.complete, bytes: 1024);
  }
}

class RuntimeFixture extends ClassifiedToolchainService {
  RuntimeFixture(ToolchainLayout layout, this.versions)
    : super(_UnusedMise(), layout);
  final List<ClassifiedVersion> versions;
  @override
  Future<List<ClassifiedVersion>> inventory() async => versions;
}

class _UnusedMise implements MiseProcessService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('No mise subprocess expected');
}

void writeAndroid(String sdk, String id, String version) {
  final parts = version.split('.');
  final file = File('$sdk/${id.replaceAll(';', '/')}/package.xml');
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '<localPackage path="$id"><revision><major>${parts[0]}</major><minor>${parts.length > 1 ? parts[1] : 0}</minor><micro>${parts.length > 2 ? parts[2] : 0}</micro></revision></localPackage>',
  );
}

class PackageFixtureProcess implements MaintenanceProcess {
  PackageFixtureProcess(this.settings);
  final ManagerSettings settings;
  final formulas = <String, String>{'wget': '1.0.0'},
      casks = <String, String>{};
  final latest = <String, String>{
    'wget': '2.0.0',
    'jq': '2.0.0',
    'bruno': '4.2.1',
  };
  final calls = <MaintenanceCommand>[];
  String uses = '', prefixOverride = '';
  bool pinned = false, lie = false, retainOld = false;
  int mutations = 0;
  Map<String, String>? lastEnvironment;
  @override
  Future<LocalCommandResult> run(
    MaintenanceCommand c, {
    required Map<String, String> environment,
    required String workingDirectory,
    Duration timeout = const Duration(seconds: 30),
    void Function(String)? onOutput,
  }) async {
    calls.add(c);
    lastEnvironment = environment;
    final a = c.arguments;
    var out = '';
    if (a.first == '--prefix') {
      out = prefixOverride.isEmpty ? settings.homebrewPrefix : prefixOverride;
    } else if (a.first == 'info') {
      final all = a.contains('--installed');
      final cask = a.contains('--cask');
      final names = all
          ? formulas.keys.toList()
          : cask
          ? <String>[]
          : [a.last];
      final apps = all
          ? casks.keys.toList()
          : cask
          ? [a.last]
          : <String>[];
      out = jsonEncode({
        'formulae': [
          for (final id in names)
            {
              'name': id,
              'full_name': id,
              'versions': {'stable': latest[id] ?? '2.0.0'},
              'installed': [
                if (formulas[id] != null)
                  for (final v in formulas[id]!.split(' / ')) {'version': v},
              ],
              'pinned': pinned,
              'dependencies': [],
            },
        ],
        'casks': [
          for (final id in apps)
            {
              'token': id,
              'full_token': id,
              'version': latest[id] ?? '2.0.0',
              'installed': casks[id],
            },
        ],
      });
    } else if (a.first == 'uses') {
      out = uses;
    } else if (a.contains('--dry-run')) {
      out = 'Would install selected package and required dependencies';
    } else if (a.first == '--list') {
      out =
          'Available packages:\n  platforms/android-99 2.0.0 Android Platform 99\n  ndk/99.0.1 99.0.1 NDK\nAvailable updates:\n';
    } else {
      mutations++;
      onOutput?.call('token=fixture-secret\n');
      if (!lie) {
        if (c.executable.endsWith('sdkmanager')) {
          final id = a.last,
              dir = Directory(
                '${settings.androidSdk}/${a.last.replaceAll(';', '/')}',
              );
          if (a.contains('--uninstall')) {
            dir.deleteSync(recursive: true);
          } else {
            writeAndroid(
              settings.androidSdk,
              id,
              id == 'ndk;99.0.1' ? '99.0.1' : '2.0.0',
            );
          }
        } else if (['install', 'upgrade', 'uninstall'].contains(a.first)) {
          final map = a.contains('--cask') ? casks : formulas;
          if (a.first == 'uninstall') {
            map.remove(a.last);
          } else {
            map[a.last] = retainOld && map[a.last] != null
                ? '${map[a.last]} / ${latest[a.last]}'
                : latest[a.last] ?? '2.0.0';
          }
        }
      }
    }
    return LocalCommandResult(0, out, '');
  }
}

void main() {
  late Directory temp;
  late ToolchainLayout layout;
  late ManagerSettings settings;
  late TaskCenter tasks;
  late PackageFixtureProcess process;
  late MaintenanceService service;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('devworkbench-maintenance-');
    layout = ToolchainLayout(home: temp.resolveSymbolicLinksSync());
    Directory('${layout.root}/android/sdk').createSync(recursive: true);
    settings = ManagerSettings(
      androidSdk: '${layout.root}/android/sdk',
      homebrewPrefix: '${temp.path}/brew',
    );
    process = PackageFixtureProcess(settings);
    tasks = TaskCenter(WorkbenchJsonStore(null));
    service = MaintenanceService(
      ManagedPackageCatalog(process, layout, settings),
      RuntimeFixture(layout, []),
      tasks,
    );
  });
  tearDown(() {
    tasks.dispose();
    temp.deleteSync(recursive: true);
  });
  test(
    'brew owned package upgrades with native dry-run and verifies a retained old keg',
    () async {
      final plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.formula,
          MaintenanceAction.update,
          'wget',
        ),
      );
      expect(plan.beforeVersion, '1.0.0');
      expect(plan.targetVersion, '2.0.0');
      expect(plan.previewOutput, contains('required dependencies'));
      process.retainOld = true;
      expect((await service.execute(plan)).passed, isTrue);
      expect(process.mutations, 1);
      expect(process.lastEnvironment!['HOMEBREW_NO_AUTOREMOVE'], '1');
      expect(tasks.state.tasks.first.output, isNot(contains('fixture-secret')));
    },
  );
  test(
    'cask installs in Applications without overwrite, zap or adoption',
    () async {
      final plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.cask,
          MaintenanceAction.install,
          'bruno',
        ),
      );
      expect(plan.commands.single.arguments, [
        'install',
        '--cask',
        '--appdir=/Applications',
        'bruno',
      ]);
      expect((await service.execute(plan)).passed, isTrue);
      final remove = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.cask,
          MaintenanceAction.uninstall,
          'bruno',
        ),
      );
      expect(remove.commands.single.arguments, [
        'uninstall',
        '--cask',
        'bruno',
      ]);
      expect((await service.execute(remove)).passed, isTrue);
    },
  );
  test(
    'explicit installation does not implicitly change installed packages',
    () async {
      final plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.formula,
          MaintenanceAction.install,
          'jq',
        ),
      );
      expect(process.mutations, 0);
      expect((await service.execute(plan)).passed, isTrue);
      expect(process.formulas['wget'], '1.0.0');
    },
  );
  test(
    'protected runtimes, options, missing receipts, pinned packages and dependents are rejected',
    () async {
      for (final id in [
        'node@24',
        'python',
        'mise',
        'xcode',
        '--force',
        'gh;rm',
      ]) {
        await expectLater(
          service.prepare(
            MaintenanceRequest(
              MaintenanceManager.formula,
              MaintenanceAction.install,
              id,
            ),
          ),
          throwsA(anything),
        );
      }
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.cask,
            MaintenanceAction.uninstall,
            'bruno',
          ),
        ),
        throwsStateError,
      );
      process.pinned = true;
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.formula,
            MaintenanceAction.update,
            'wget',
          ),
        ),
        throwsStateError,
      );
      process.pinned = false;
      process.uses = 'dependent-tool';
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.formula,
            MaintenanceAction.uninstall,
            'wget',
          ),
        ),
        throwsStateError,
      );
      expect(process.mutations, 0);
    },
  );
  test(
    'changed installation or prefix prevents stale plan execution',
    () async {
      final plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.formula,
          MaintenanceAction.uninstall,
          'wget',
        ),
      );
      process.formulas['wget'] = '1.1.0';
      expect((await service.execute(plan)).passed, isFalse);
      expect(process.mutations, 0);
      process.prefixOverride = '/another-prefix';
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.formula,
            MaintenanceAction.uninstall,
            'wget',
          ),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'native zero exit still fails when target version is not actually installed',
    () async {
      final plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.formula,
          MaintenanceAction.update,
          'wget',
        ),
      );
      process.lie = true;
      expect((await service.execute(plan)).passed, isFalse);
      expect(tasks.state.tasks.first.status, TaskStatus.failed);
    },
  );
  test(
    'Android install, update and uninstall use exact package ids and preserve siblings',
    () async {
      writeAndroid(settings.androidSdk, 'platforms;android-33', '1.0.0');
      var plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.android,
          MaintenanceAction.install,
          'platforms;android-99',
        ),
      );
      expect(plan.commands.single.arguments.last, 'platforms;android-99');
      expect((await service.execute(plan)).passed, isTrue);
      writeAndroid(settings.androidSdk, 'platforms;android-99', '1.0.0');
      plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.android,
          MaintenanceAction.update,
          'platforms;android-99',
        ),
      );
      expect((await service.execute(plan)).passed, isTrue);
      plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.android,
          MaintenanceAction.uninstall,
          'platforms;android-99',
        ),
      );
      expect((await service.execute(plan)).passed, isTrue);
      expect(
        File(
          '${settings.androidSdk}/platforms/android-33/package.xml',
        ).existsSync(),
        isTrue,
      );
    },
  );
  test(
    'Android bootstrap packages and AVD system images remain protected',
    () async {
      for (final id in ['platform-tools', 'cmdline-tools;latest', 'emulator']) {
        writeAndroid(settings.androidSdk, id, '1.0.0');
        await expectLater(
          service.prepare(
            MaintenanceRequest(
              MaintenanceManager.android,
              MaintenanceAction.uninstall,
              id,
            ),
          ),
          throwsStateError,
        );
      }
      const id = 'system-images;android-33;google_apis;arm64-v8a';
      writeAndroid(settings.androidSdk, id, '1.0.0');
      final file = File('${layout.root}/android/avd/device.avd/config.ini');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(
        'image.sysdir.1=system-images/android-33/google_apis/arm64-v8a/',
      );
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.android,
            MaintenanceAction.uninstall,
            id,
          ),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'Android orphan directories, invalid ids and redirected SDK paths cannot be modified',
    () async {
      Directory(
        '${settings.androidSdk}/platforms/android-99',
      ).createSync(recursive: true);
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.android,
            MaintenanceAction.install,
            'platforms;android-99',
          ),
        ),
        throwsStateError,
      );
      for (final id in [
        '../../home',
        'platforms;../foo',
        '--update',
        'ndk;latest',
      ]) {
        await expectLater(
          service.prepare(
            MaintenanceRequest(
              MaintenanceManager.android,
              MaintenanceAction.install,
              id,
            ),
          ),
          throwsArgumentError,
        );
      }
      Directory(settings.androidSdk).deleteSync(recursive: true);
      final outside = Directory('${temp.path}/outside')..createSync();
      Link(settings.androidSdk).createSync(outside.path);
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.android,
            MaintenanceAction.install,
            'platforms;android-99',
          ),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'cache cleanup rejects mixed data and redirects into package/configuration directories',
    () async {
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.cache,
            MaintenanceAction.clean,
            'maven',
          ),
        ),
        throwsArgumentError,
      );
      final global = Directory('${layout.root}/npm/global')
        ..createSync(recursive: true);
      Link('${layout.root}/npm/cache').createSync(global.path);
      await expectLater(
        service.prepare(
          const MaintenanceRequest(
            MaintenanceManager.cache,
            MaintenanceAction.clean,
            'npm',
          ),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'all cache plans use exact native commands and classified paths',
    () async {
      final versions = <ClassifiedVersion>[];
      for (final (tool, binary) in [
        ('node', 'node'),
        ('python', 'python3'),
        ('go', 'go'),
      ]) {
        final sdk = '${layout.root}/sdk-$tool';
        Directory('$sdk/bin').createSync(recursive: true);
        File('$sdk/bin/$binary').writeAsStringSync('fixture');
        if (tool == 'node') {
          final npm = File('$sdk/lib/node_modules/npm/bin/npm-cli.js');
          npm.parent.createSync(recursive: true);
          npm.writeAsStringSync('fixture');
        }
        versions.add(
          ClassifiedVersion(
            tool: tool,
            version: '99.0.0',
            active: true,
            registeredPath: sdk,
            actualPath: sdk,
            classified: true,
          ),
        );
      }
      final uv = File('${layout.root}/uv/bin/uv');
      uv.parent.createSync(recursive: true);
      uv.writeAsStringSync('fixture');
      final runner = MaintenanceService(
        ManagedPackageCatalog(process, layout, settings),
        RuntimeFixture(layout, versions),
        tasks,
      );
      for (final id in MaintenanceService.cacheIds) {
        Directory('${layout.root}/$id/cache').createSync(recursive: true);
        final plan = await runner.prepare(
          MaintenanceRequest(
            MaintenanceManager.cache,
            MaintenanceAction.clean,
            id,
          ),
        );
        expect(plan.paths.single, '${layout.root}/$id/cache');
        if (id == 'go') {
          expect(plan.commands.single.arguments, ['clean', '-cache']);
        } else {
          expect(plan.commands.single.arguments, contains(plan.paths.single));
        }
        expect(plan.commands.single.arguments, isNot(contains('--all')));
      }
    },
  );
  test('native pip purge changes only an isolated classified cache', () async {
    const python = '/Users/cua/Developer/toolchains/python/default/bin/python3';
    if (!File(python).existsSync()) return;
    final cache = '${layout.root}/pip/cache';
    final wheel = File('$cache/wheels/example/demo-1.0-py3-none-any.whl');
    wheel.parent.createSync(recursive: true);
    wheel.writeAsStringSync('fixture');
    final keep = File('${layout.root}/pip/config.ini')
      ..writeAsStringSync('retain');
    final nativeLayout = ToolchainLayout(
      home: layout.home,
      environment: {'PIP_CONFIG_FILE': '/dev/null', 'PIP_NO_INDEX': '1'},
    );
    final native = MaintenanceService(
      ManagedPackageCatalog(
        const SystemMaintenanceProcess(),
        nativeLayout,
        settings,
      ),
      RuntimeFixture(layout, [
        ClassifiedVersion(
          tool: 'python',
          version: '3.14.8',
          active: true,
          registeredPath: File(python).parent.parent.path,
          actualPath: File(python).parent.parent.path,
          classified: true,
        ),
      ]),
      tasks,
    );
    final plan = await native.prepare(
      const MaintenanceRequest(
        MaintenanceManager.cache,
        MaintenanceAction.clean,
        'pip',
      ),
    );
    final result = await native.execute(plan);
    expect(result.passed, isTrue);
    expect(wheel.existsSync(), isFalse);
    expect(keep.readAsStringSync(), 'retain');
  });

  test(
    'cache redirection during measurement is rejected immediately before native cleanup',
    () async {
      final cache = Directory('${layout.root}/uv/cache')
        ..createSync(recursive: true);
      final tools = Directory('${layout.root}/uv/tools')..createSync();
      final keep = File('${tools.path}/keep')..writeAsStringSync('retain');
      final binary = File('${layout.root}/uv/bin/uv');
      binary.parent.createSync();
      binary.writeAsStringSync('fixture');
      final runner = MaintenanceService(
        ManagedPackageCatalog(process, layout, settings),
        RuntimeFixture(layout, []),
        tasks,
        usage: ChangingUsage(() {
          cache.renameSync('${cache.path}.saved');
          Link(cache.path).createSync(tools.path);
        }),
      );
      final plan = await runner.prepare(
        const MaintenanceRequest(
          MaintenanceManager.cache,
          MaintenanceAction.clean,
          'uv',
        ),
      );
      expect((await runner.execute(plan)).passed, isFalse);
      expect(process.mutations, 0);
      expect(keep.readAsStringSync(), 'retain');
    },
  );

  test(
    'mutation ownership prevents manager or mise operations overlapping',
    () async {
      tasks.startMutation('active install', 'mise', ['install']);
      final plan = await service.prepare(
        const MaintenanceRequest(
          MaintenanceManager.formula,
          MaintenanceAction.uninstall,
          'wget',
        ),
      );
      await expectLater(service.execute(plan), throwsStateError);
      expect(process.mutations, 0);
    },
  );
  test(
    'legacy and current Android available listings parse only supported stable package ids',
    () {
      final legacy = parseAndroidAvailable(
        'Available Packages:\nplatforms;android-99 | 2 | Android\nmalicious;../home | 1 | bad\nAvailable Updates:\n',
      );
      expect(legacy.single.id, 'platforms;android-99');
      expect(
        parseAndroidAvailable(
          'Available packages:\n ndk/99.0.1 99.0.1 NDK\nAvailable updates:\n',
        ).single.id,
        'ndk;99.0.1',
      );
    },
  );
  test(
    'stream runner preserves literal arguments and reports a native timeout',
    () async {
      const runner = SystemMaintenanceProcess();
      final output = <String>[];
      final result = await runner.run(
        const MaintenanceCommand('/usr/bin/printf', [
          '%s',
          'literal \$(echo unsafe) 中文',
        ]),
        environment: {'HOME': temp.path},
        workingDirectory: temp.path,
        onOutput: output.add,
      );
      expect(result.stdout, 'literal \$(echo unsafe) 中文');
      expect(output.join(), result.stdout);
      await expectLater(
        runner.run(
          const MaintenanceCommand('/bin/sleep', ['2']),
          environment: {},
          workingDirectory: temp.path,
          timeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<TimeoutException>()),
      );
    },
  );
}
