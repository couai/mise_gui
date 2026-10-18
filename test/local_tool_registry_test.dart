import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/local_tool_inventory.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/local_tool_profiles.dart';
import 'package:mise_gui/services/local_tool_registry.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class MetadataProcess implements LocalToolProcess {
  final calls = <(String, List<String>)>[];
  @override
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    calls.add((executable, arguments));
    if (executable != '/usr/bin/plutil') {
      throw StateError('Unexpected execution');
    }
    return LocalCommandResult(
      0,
      jsonEncode({
        'CFBundleExecutable': 'Example',
        'CFBundleShortVersionString': '2.3.4',
      }),
      '',
    );
  }
}

void main() {
  late Directory temp;
  late LocalToolRegistry registry;
  late MetadataProcess process;
  late ToolchainLayout layout;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('devworkbench-registry-');
    layout = ToolchainLayout(
      home: temp.path,
      environment: {'PATH': '${temp.path}/empty'},
    );
    process = MetadataProcess();
    registry = LocalToolRegistry(
      file: File('${layout.appDir}/config/imported_tools.json'),
      process: process,
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  Future<File> executable(String path) async {
    final f = File(path);
    await f.parent.create(recursive: true);
    await f.writeAsString('#!/bin/sh\ntouch "${temp.path}/executed"\n');
    await Process.run('/bin/chmod', ['700', f.path]);
    return f;
  }

  ImportedTool draft(
    String path, {
    bool application = false,
    String version = '',
    String config = '',
  }) => ImportedTool(
    id: '',
    name: 'Example',
    category: LocalToolCategory.utility,
    path: path,
    application: application,
    version: version,
    configPath: config,
  );

  test('empty registry discovery never creates files', () async {
    expect(await registry.scan(), isEmpty);
    expect(await registry.file.exists(), isFalse);
  });

  test(
    'CLI import survives restart, never executes, and forget keeps program and data',
    () async {
      final f = await executable('${temp.path}/tools with spaces/a;\$(whoami)');
      final data = Directory('${temp.path}/my config');
      await data.create();
      await registry.importTool(
        draft(f.path, version: '1.2.3', config: data.path),
        knownTools: [],
      );
      registry = LocalToolRegistry(file: registry.file, process: process);
      final tools = await registry.scan();
      final t = tools.single;
      expect(t.installed, isTrue);
      expect(t.imported, isTrue);
      expect(t.version, '1.2.3 · 手动登记');
      expect(t.locations.last.kind, ToolLocationKind.configuration);
      expect(process.calls, isEmpty);
      expect(await File('${temp.path}/executed').exists(), isFalse);
      await registry.forget(t.id);
      expect(await registry.scan(), isEmpty);
      expect(await f.exists(), isTrue);
      expect(await data.exists(), isTrue);
    },
  );

  test(
    'app requires real launcher and reads bundle version without starting app',
    () async {
      final app = Directory('${temp.path}/Example.app');
      await Directory('${app.path}/Contents').create(recursive: true);
      await File('${app.path}/Contents/Info.plist').writeAsString('metadata');
      await expectLater(
        registry.importTool(draft(app.path, application: true), knownTools: []),
        throwsStateError,
      );
      await executable('${app.path}/Contents/MacOS/Example');
      await registry.importTool(
        draft(app.path, application: true, version: 'wrong'),
        knownTools: [],
      );
      final t = (await registry.scan()).single;
      expect(t.version, '2.3.4');
      expect(t.locations.first.application, isTrue);
      expect(process.calls.every((c) => c.$1 == '/usr/bin/plutil'), isTrue);
      expect(await File('${temp.path}/executed').exists(), isFalse);
    },
  );

  test(
    'canonical duplicate paths are rejected for imported and built-in tools',
    () async {
      final f = await executable('${temp.path}/example');
      final link = Link('${temp.path}/alias');
      await link.create(f.path);
      final builtIn = LocalTool(
        id: 'builtin',
        name: 'Example',
        category: LocalToolCategory.utility,
        description: '',
        status: LocalToolStatus.ready,
        manager: 'Homebrew',
        source: '',
        executable: f.path,
      );
      await expectLater(
        registry.importTool(draft(link.path), knownTools: [builtIn]),
        throwsStateError,
      );
      await registry.importTool(draft(f.path), knownTools: []);
      await expectLater(
        registry.importTool(draft(link.path), knownTools: []),
        throwsStateError,
      );
      expect((await registry.load()).length, 1);
    },
  );

  test(
    'rejects relative paths, directories, nonexecutables, missing files and mise shims',
    () async {
      final file = File('${temp.path}/plain');
      await file.writeAsString('text');
      final shim = await executable('${temp.path}/shims/node');
      final proxy = Link('${temp.path}/proxy');
      await proxy.create(shim.path);
      for (final path in [
        temp.path,
        file.path,
        '${temp.path}/absent',
        shim.path,
        proxy.path,
      ]) {
        await expectLater(
          registry.importTool(draft(path), knownTools: []),
          throwsStateError,
        );
      }
      await expectLater(
        registry.importTool(draft('relative/tool'), knownTools: []),
        throwsFormatException,
      );
      expect(await registry.file.exists(), isFalse);
    },
  );

  test(
    'moved or invalidated program is retained as an actionable registration',
    () async {
      final f = await executable('${temp.path}/example');
      final record = await registry.importTool(draft(f.path), knownTools: []);
      await Process.run('/bin/chmod', ['600', f.path]);
      expect((await registry.scan()).single.status, LocalToolStatus.attention);
      await f.delete();
      final t = (await registry.scan()).single;
      expect(t.status, LocalToolStatus.missing);
      expect(t.locations.first.exists, isFalse);
      expect((await registry.load()).single.id, record.id);
    },
  );

  test(
    'corrupt registry is preserved and does not block built-in discovery',
    () async {
      await registry.file.parent.create(recursive: true);
      await registry.file.writeAsString('{broken');
      final snapshot = await SystemLocalToolInventory(
        layout: layout,
        process: process,
        loadVersions: () async => [],
        applications: '${temp.path}/apps',
        fallbackBins: [],
        registry: registry,
      ).scan();
      expect(snapshot.tools.length, 46);
      expect(snapshot.warnings.single, contains('手动导入清单读取失败'));
      final f = await executable('${temp.path}/example');
      await expectLater(
        registry.importTool(draft(f.path), knownTools: []),
        throwsFormatException,
      );
      expect(await registry.file.readAsString(), '{broken');
    },
  );

  test(
    'IDE profiles include existing version directories without mixing other products',
    () async {
      final parent = '${temp.path}/Library/Application Support/JetBrains';
      await Directory('$parent/IntelliJIdea2026.2').create(recursive: true);
      await Directory('$parent/DataGrip2026.2').create();
      const idea = LocalTool(
        id: 'idea',
        name: 'IDEA',
        category: LocalToolCategory.editor,
        description: '',
        status: LocalToolStatus.ready,
        manager: 'macOS 应用',
        source: '',
      );
      final result = await LocalToolProfiles(layout).enrich(idea);
      expect(result.locations.single.path, '$parent/IntelliJIdea2026.2');
      expect(result.locations.single.kind, ToolLocationKind.configuration);
    },
  );

  test('profiles use configured paths and conditional relationships', () async {
    final cache = Directory('${temp.path}/custom go cache');
    await cache.create();
    final custom = ToolchainLayout(
      home: temp.path,
      environment: {
        'GOCACHE': cache.path,
        'MISE_CONFIG_DIR': '${temp.path}/mise config',
      },
    );
    const go = LocalTool(
      id: 'go',
      name: 'Go',
      category: LocalToolCategory.runtime,
      description: '',
      status: LocalToolStatus.ready,
      manager: 'mise',
      source: '',
      miseTool: 'go',
    );
    final enriched = await LocalToolProfiles(custom).enrich(go);
    expect(
      enriched.locations.singleWhere((p) => p.label == '编译缓存').path,
      cache.path,
    );
    expect(
      enriched.locations.singleWhere((p) => p.label == '编译缓存').kind,
      ToolLocationKind.cache,
    );
    expect(
      enriched.locations.singleWhere((p) => p.label == 'mise 全局配置').path,
      '${temp.path}/mise config/config.toml',
    );
    expect(
      LocalToolProfiles.relations['flutter']!
          .singleWhere((r) => r.toolId == 'xcode')
          .reason,
      contains('Apple'),
    );
  });
}
