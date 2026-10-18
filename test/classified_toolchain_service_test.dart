import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class InventoryProcess implements MiseProcessService {
  InventoryProcess(this.rows);
  final Map<String, dynamic> rows;
  final requests = <MiseCommandRequest>[];
  @override
  Future<MiseCommandResult> run(MiseCommandRequest request) async {
    requests.add(request);
    return MiseCommandResult(
      request: request,
      stdout: request.arguments.first == 'ls' ? jsonEncode(rows) : '',
      stderr: '',
      exitCode: 0,
      duration: Duration.zero,
    );
  }

  @override
  Future<String> resolveExecutablePath() async => '/opt/homebrew/bin/mise';
  @override
  Future<ShellEnvironmentLoadResult> inspectShellEnvironment() async =>
      const ShellEnvironmentLoadResult(source: ShellEnvironmentSource.shell);
  @override
  Future<WindowsShimPathStatus> inspectWindowsShimPath() async =>
      const WindowsShimPathStatus(source: WindowsShimPathSource.unsupported);
}

/// Actual CLI in an isolated HOME/config/data/cache, without loading login shell.
class IsolatedMiseProcess extends InventoryProcess {
  IsolatedMiseProcess(this.layout) : super({});
  final ToolchainLayout layout;
  @override
  Future<MiseCommandResult> run(MiseCommandRequest request) async {
    final result = await Process.run(
      '/opt/homebrew/bin/mise',
      request.arguments,
      workingDirectory: request.workingDirectory ?? layout.home,
      environment: {
        'HOME': layout.home,
        'MISE_CONFIG_DIR': layout.configDir,
        'MISE_DATA_DIR': layout.dataDir,
        'MISE_CACHE_DIR': '${layout.root}/mise/cache',
        'MISE_STATE_DIR': '${layout.root}/mise/state',
        'MISE_YES': '1',
        'MISE_QUIET': '1',
        'MISE_NO_UPDATE_CHECK': '1',
      },
    );
    final value = MiseCommandResult(
      request: request,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
      exitCode: result.exitCode,
      duration: Duration.zero,
    );
    if (result.exitCode != 0 && !request.allowNonZeroExit) {
      throw StateError('${request.arguments}: ${result.stderr}');
    }
    return value;
  }
}

class FailedInstallProcess extends InventoryProcess {
  FailedInstallProcess(this.lock) : super({});
  final File lock;
  @override
  Future<MiseCommandResult> run(MiseCommandRequest request) async {
    if (request.arguments.first != 'install-into') return super.run(request);
    await lock.parent.create(recursive: true);
    await lock.writeAsString('owned by another mise process');
    return MiseCommandResult(
      request: request,
      stdout: '',
      stderr: 'install failed',
      exitCode: 1,
      duration: Duration.zero,
    );
  }
}

void main() {
  late Directory temp;
  late ToolchainLayout layout;
  late InventoryProcess process;
  late ClassifiedToolchainService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('mise-classified-');
    // macOS /var is a symlink; use the canonical path for containment assertions.
    temp = Directory(await temp.resolveSymbolicLinks());
    layout = ToolchainLayout(home: temp.path);
    process = InventoryProcess({});
    service = ClassifiedToolchainService(process, layout);
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'recognizes exact linked SDK paths rather than the JSON symlink label',
    () async {
      final actual = Directory('${layout.root}/python/default');
      await actual.create(recursive: true);
      final link = Link('${temp.path}/python-link');
      await link.create(actual.path);
      process.rows['python'] = [
        {
          'version': '3.14.8',
          'installed': true,
          'active': true,
          'install_path': link.path,
          'symlinked_to': link.path,
        },
      ];
      final row = (await service.inventory()).single;
      expect(row.actualPath, actual.path);
      expect(row.classified, isTrue);
      expect(process.requests.last.workingDirectory, layout.home);
    },
  );

  test(
    'every standalone runtime installs in its category and registers afterwards',
    () async {
      for (final tool in ['java', 'node', 'python', 'go', 'flutter']) {
        final version = tool == 'java' ? 'temurin-21.0.12.1+1' : '3.47.7';
        final script = await service.installPlan(tool, version);
        expect(script, contains('mise install-into $tool@$version'));
        expect(script, contains(layout.installTarget(tool, version)));
        expect(script, contains('mise link $tool@$version'));
        expect(script, isNot(contains('mise use')));
        expect(await service.prepare(script), script);
      }
    },
  );

  test(
    'upstream install and switch is expanded before the command preview',
    () async {
      final script = await service.prepare(
        'mise install go@1.28.0\nmise use --global go@1.28.0',
      );
      expect(script, startsWith('mise install-into go@1.28.0'));
      expect(script, endsWith('mise use --global go@1.28.0'));
      expect(await service.prepare(script), script);
    },
  );

  test('rejects occupied targets including dangling links', () async {
    final target = layout.installTarget('go', '1.28.0');
    await Directory(target).parent.create(recursive: true);
    await Link(target).create('${temp.path}/missing');
    await expectLater(service.installPlan('go', '1.28.0'), throwsStateError);
    expect(
      await FileSystemEntity.type(target, followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test(
    'rejects category symlinks redirected outside the toolchain root',
    () async {
      await Directory(layout.root).create(recursive: true);
      final outside = Directory('${temp.path}/elsewhere');
      await outside.create();
      await Link('${layout.root}/go').create(outside.path);
      await expectLater(service.installPlan('go', '1.28.0'), throwsStateError);
      expect(await outside.list().isEmpty, isTrue);
    },
  );

  test(
    'rejects floating versions, traversal and unsupported categories',
    () async {
      for (final version in [
        'latest',
        '24',
        '24.1',
        '../escape',
        '1.2.3/../../escape',
        '3.1.0\nmise uninstall --all go',
      ]) {
        await expectLater(
          service.installPlan('node', version),
          throwsArgumentError,
        );
      }
      await expectLater(
        service.installPlan('unknown', '1.2.3'),
        throwsArgumentError,
      );
    },
  );

  test('Rust installs via rustup and links the shared proxies', () async {
    final script = await service.installPlan('rust', '1.100.0');
    expect(
      script,
      contains('rustup toolchain install 1.100.0 --profile default'),
    );
    expect(script, contains('${layout.cargoHome}/bin'));
    expect(script, isNot(contains('install-into')));
    expect(await service.prepare(script), script);
  });

  test(
    'switching requires an installed exact version and an explicit scope',
    () async {
      process.rows['java'] = [
        {
          'version': 'temurin-17.0.20.1+1',
          'installed': true,
          'active': false,
          'install_path': '/missing',
        },
      ];
      expect(
        await service.switchPlan('java', 'temurin-17.0.20.1+1'),
        'mise use --global java@temurin-17.0.20.1+1',
      );
      await expectLater(
        service.switchPlan('java', 'temurin-21.0.12.1+1'),
        throwsStateError,
      );
      final project = Directory('${temp.path}/project with space');
      await project.create();
      final plan = await service.switchPlan(
        'java',
        'temurin-17.0.20.1+1',
        projectPath: project.path,
      );
      expect(parseCommandArguments(plan), [
        'mise',
        'use',
        '--path',
        '${project.path}/mise.toml',
        'java@temurin-17.0.20.1+1',
      ]);
      expect(await service.prepare(plan), plan);
    },
  );

  test(
    'uninstall, forced installs, arbitrary exec and mismatched paths are blocked',
    () async {
      for (final script in [
        'mise uninstall --all rust',
        'mise use --global --remove java',
        'mise install go@1.28.0 --force',
        'mise upgrade go',
        'mise exec -- sh -c rm',
        'mise install-into go@1.28.0 /tmp/other',
        'mise link go@1.28.0 /tmp/other',
      ]) {
        await expectLater(
          service.prepare(script),
          throwsA(
            anyOf(
              isA<ArgumentError>(),
              isA<StateError>(),
              isA<UnsupportedError>(),
            ),
          ),
        );
      }
    },
  );

  test(
    'quote parsing preserves spaces and apostrophes without shell evaluation',
    () {
      const value = "/tmp/owner's project/\$(echo never)";
      expect(
        parseCommandArguments(
          'mise use --path ${quoteArgument(value)} node@24.21.0',
        )[3],
        value,
      );
      expect(
        () => parseCommandArguments("mise use 'unfinished"),
        throwsFormatException,
      );
    },
  );

  test('execution refuses a target occupied after preview', () async {
    final script = await service.installPlan('go', '1.28.0');
    await Directory(
      layout.installTarget('go', '1.28.0'),
    ).create(recursive: true);
    final executor = LocalMiseActionService(process, policy: service);
    await expectLater(executor.runScript(script), throwsStateError);
    expect(
      process.requests.where((r) => r.arguments.first == 'install-into'),
      isEmpty,
    );
  });

  test(
    'failed classified installation preserves concurrent mise locks',
    () async {
      final lock = File('${temp.path}/mise/lockfiles/concurrent');
      final failed = FailedInstallProcess(lock);
      final policy = ClassifiedToolchainService(failed, layout);
      final executor = LocalMiseActionService(
        failed,
        policy: policy,
        lockfileCleaner: MiseLockfileCleaner(
          lockfileDirectories: [lock.parent.path],
        ),
      );
      final plan = await policy.installPlan('go', '1.28.0');
      final result = await executor.runScript(plan);
      expect(result.isSuccess, isFalse);
      expect(await lock.readAsString(), 'owned by another mise process');
    },
  );

  test(
    'real mise preserves global and project scopes in an isolated environment',
    () async {
      if (!File('/opt/homebrew/bin/mise').existsSync()) return;
      final live = IsolatedMiseProcess(layout);
      final classified = ClassifiedToolchainService(live, layout);
      for (final version in ['24.21.0', '22.20.0']) {
        final target = layout.installTarget('node', version);
        await Directory('$target/bin').create(recursive: true);
        await live.run(
          MiseCommandRequest(arguments: ['link', 'node@$version', target]),
        );
      }
      final global = File(layout.globalConfigPath);
      await global.parent.create(recursive: true);
      await global.writeAsString(
        '[env]\nKEEP_ME = "unchanged"\n[tools]\nnode = "24.21.0"\n[tools.flutter]\nversion = "3.47.7"\n[tools.flutter.platforms.macos-arm64]\nurl = "https://example.invalid/flutter.zip"\n',
      );
      final before = await global.readAsString();
      final project = Directory('${temp.path}/project');
      await project.create();
      final executor = LocalMiseActionService(live, policy: classified);
      final script = await classified.switchPlan(
        'node',
        '22.20.0',
        projectPath: project.path,
      );
      expect((await executor.runScript(script)).isSuccess, isTrue);
      expect(await global.readAsString(), before);
      expect(
        await File('${project.path}/mise.toml').readAsString(),
        contains('22.20.0'),
      );
      final globalScript = await classified.switchPlan('node', '22.20.0');
      expect((await executor.runScript(globalScript)).isSuccess, isTrue);
      final after = await global.readAsString();
      expect(after, contains('KEEP_ME = "unchanged"'));
      expect(after, contains('[tools.flutter.platforms.macos-arm64]'));
      expect(after, contains('22.20.0'));
    },
  );
}
