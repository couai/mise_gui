import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class Probe implements LocalToolProcess {
  final calls = <(String, List<String>)>[];
  final results = <String, LocalCommandResult>{};
  final environments = <Map<String, String>>[];
  Duration delay = Duration.zero;
  int running = 0, maximumRunning = 0;
  @override
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    calls.add((executable, arguments));
    environments.add(environment);
    running++;
    if (running > maximumRunning) maximumRunning = running;
    try {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      return results[executable] ?? const LocalCommandResult(1, '', '');
    } finally {
      running--;
    }
  }
}

void main() {
  late Directory temp;
  late ToolchainLayout layout;
  late Probe probe;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dev-workbench-test-');
    layout = ToolchainLayout(
      home: temp.path,
      environment: {'PATH': '${temp.path}/bin'},
    );
    probe = Probe();
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  Future<String> binary(String path) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString('#!/bin/sh\n');
    await Process.run('/bin/chmod', ['755', path]);
    return path;
  }

  Future<LocalToolSnapshot> scan({
    List<ClassifiedVersion> versions = const [],
    bool missingMise = false,
  }) => SystemLocalToolInventory(
    layout: layout,
    process: probe,
    applications: '${temp.path}/Applications',
    fallbackBins: [],
    loadVersions: () async {
      if (missingMise) throw StateError('missing');
      return versions;
    },
  ).scan();

  test('inventory limits simultaneous probes without dropping tools', () async {
    probe.delay = const Duration(milliseconds: 20);
    for (final name in ['gh', 'wget', 'git', 'uv']) {
      await binary('${temp.path}/bin/$name');
    }
    final result = await scan();
    expect(probe.maximumRunning, 1);
    expect(
      result.tools.map((tool) => tool.id),
      containsAll(['gh', 'wget', 'git', 'uv']),
    );
  });

  test(
    'discovers real CLI evidence, keeps source separate, and never creates tool folders',
    () async {
      final path = await binary('${temp.path}/bin/gh');
      probe.results[path] = const LocalCommandResult(
        0,
        'gh version 2.102.0 (2026-09-25)',
        '',
      );
      final gopls = await binary('${temp.path}/bin/gopls');
      probe.results[gopls] = const LocalCommandResult(
        0,
        'golang.org/x/tools/gopls v0.23.0',
        '',
      );
      final before = await temp
          .list(recursive: true)
          .map((e) => e.path)
          .toList();
      final result = await scan();
      final gh = result.tools.singleWhere((t) => t.id == 'gh');
      expect(
        result.tools.singleWhere((t) => t.id == 'gopls').version,
        '0.23.0',
      );
      expect(gh.status, LocalToolStatus.ready);
      expect(gh.version, '2.102.0');
      expect(gh.manager, '本地 CLI');
      expect(gh.executable, path);
      expect(
        result.tools.singleWhere((t) => t.id == 'maven').status,
        LocalToolStatus.missing,
      );
      expect(
        await temp.list(recursive: true).map((e) => e.path).toList(),
        before,
      );
      expect(
        probe.environments.every(
          (e) => e['MISE_OFFLINE'] == '1' && e['MISE_AUTO_INSTALL'] == '0',
        ),
        isTrue,
      );
    },
  );

  test(
    'preserves other discovery when mise is unavailable and ignores unresolved shims',
    () async {
      final shim = await binary('${temp.path}/bin/shims/node');
      await Link('${temp.path}/bin/node').create(shim);
      final path = await binary('${temp.path}/bin/uv');
      probe.results[path] = const LocalCommandResult(0, 'uv 0.13.0', '');
      final result = await scan(missingMise: true);
      expect(result.warnings, hasLength(1));
      expect(result.tools.singleWhere((t) => t.id == 'uv').installed, isTrue);
      expect(
        result.tools.singleWhere((t) => t.id == 'node').installed,
        isFalse,
      );
      expect(probe.calls.any((c) => c.$1.endsWith('/node')), isFalse);
    },
  );

  test(
    'runtime versions preserve global selection and bundled Dart without invoking SDKs',
    () async {
      final sdk = '${layout.root}/flutter/versions/3.47.7';
      await Directory('$sdk/bin/cache/dart-sdk').create(recursive: true);
      await binary('$sdk/bin/cache/dart-sdk/bin/dart');
      await File('$sdk/bin/cache/dart-sdk/version').writeAsString('3.13.5');
      final result = await scan(
        versions: [
          ClassifiedVersion(
            tool: 'flutter',
            version: '3.47.7',
            active: true,
            registeredPath: '${layout.dataDir}/installs/flutter/3.47.7',
            actualPath: sdk,
            classified: true,
            dartVersion: '3.13.5',
          ),
        ],
      );
      final flutter = result.tools.singleWhere((t) => t.id == 'flutter');
      final dart = result.tools.singleWhere((t) => t.id == 'dart');
      expect(flutter.manager, 'mise');
      expect(flutter.versions.single.active, isTrue);
      expect(flutter.version, '3.47.7');
      expect(dart.version, '3.13.5');
      expect(dart.miseTool, 'flutter');
      expect(probe.calls, isEmpty);
    },
  );

  test(
    'broken or unclassified mise registrations are reported, not silently treated as healthy',
    () async {
      final result = await scan(
        versions: [
          ClassifiedVersion(
            tool: 'java',
            version: 'oracle-17.0.20',
            active: false,
            registeredPath: '${temp.path}/missing',
            actualPath: '${temp.path}/missing',
            classified: false,
          ),
        ],
      );
      final java = result.tools.singleWhere((t) => t.id == 'java');
      expect(java.installed, isFalse);
      expect(java.versions.single.active, isFalse);
      expect(java.notes.any((n) => n.contains('目录已不存在')), isTrue);
      expect(java.notes.any((n) => n.contains('分类目录之外')), isTrue);
    },
  );

  test(
    'reads GUI metadata, retains GUI when CLI fails, and resolves Xcode 27 Simulator location',
    () async {
      final app = '${temp.path}/Applications/Bruno.app';
      await File('$app/Contents/Info.plist').create(recursive: true);
      final cli = await binary('${layout.root}/bruno/bin/bru');
      probe.results['/usr/bin/plutil'] = LocalCommandResult(
        0,
        jsonEncode({
          'CFBundleShortVersionString': '4.2.1',
          'CFBundleIdentifier': 'com.usebruno.app',
        }),
        '',
      );
      final simulator =
          '${temp.path}/Applications/Xcode.app/Contents/Applications/Simulator.app';
      await File('$simulator/Contents/Info.plist').create(recursive: true);
      final result = await scan();
      final bruno = result.tools.singleWhere((t) => t.id == 'bruno');
      expect(bruno.status, LocalToolStatus.attention);
      expect(bruno.version, '4.2.1');
      expect(bruno.locations.singleWhere((p) => p.application).path, app);
      expect(bruno.notes.any((n) => n.contains('GUI 应用仍可打开')), isTrue);
      expect(probe.calls.any((c) => c.$1 == cli), isTrue);
      expect(
        result.tools.singleWhere((t) => t.id == 'simulator').installed,
        isTrue,
      );
    },
  );

  test(
    'checks Android SDK package metadata and Gradle distributions rather than guessing from empty folders',
    () async {
      final ndk = '${layout.root}/android/sdk/ndk';
      await Directory(
        '${layout.root}/android/sdk/platforms/android-33',
      ).create(recursive: true);
      await Directory('$ndk/empty').create(recursive: true);
      await Directory('$ndk/28.2.13676358').create();
      await File(
        '$ndk/28.2.13676358/source.properties',
      ).writeAsString('Pkg.Revision = 28.2.13676358');
      final dist =
          '${layout.root}/gradle/user-home/wrapper/dists/gradle-7.3.3-bin/hash/gradle-7.3.3';
      await binary('$dist/bin/gradle');
      final result = await scan();
      final tool = result.tools.singleWhere((t) => t.id == 'android-ndk');
      expect(
        result.tools.singleWhere((t) => t.id == 'android-sdk').installed,
        isFalse,
      );
      expect(tool.versions.map((v) => v.version), ['28.2.13676358']);
      final gradle = result.tools.singleWhere((t) => t.id == 'gradle');
      expect(gradle.version, '7.3.3');
      expect(gradle.manager, 'Gradle Wrapper');
      expect(probe.calls, isEmpty);
    },
  );

  test(
    'opens paths with spaces and shell syntax as literal arguments, revalidates vanished targets',
    () async {
      final app = Directory('${temp.path}/Sample \$(touch nope).app');
      await app.create();
      final opener = MacLocalToolOpener(probe);
      probe.results['/usr/bin/open'] = const LocalCommandResult(0, '', '');
      await opener.open(app.path, application: true);
      expect(probe.calls.single.$1, '/usr/bin/open');
      expect(probe.calls.single.$2, [app.path]);
      await app.delete();
      await expectLater(
        opener.open(app.path, application: true),
        throwsStateError,
      );
      expect(probe.calls, hasLength(1));
      await expectLater(opener.open('relative/path'), throwsStateError);
    },
    skip: !Platform.isMacOS,
  );

  test('probe timeout kills the process and bounds output', () async {
    const runner = SystemLocalToolProcess();
    final timer = Stopwatch()..start();
    await expectLater(
      runner.run('/bin/sleep', [
        '10',
      ], timeout: const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );
    expect(timer.elapsedMilliseconds, lessThan(2000));
    final output = await runner.run('/usr/bin/head', [
      '-c',
      '200000',
      '/dev/zero',
    ]);
    expect(output.exitCode, 0);
    expect(output.stdout.length, 128 * 1024);
  }, skip: Platform.isWindows);
}
