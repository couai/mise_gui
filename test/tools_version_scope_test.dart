import 'workbench_test_overrides.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/tools/application/tools_provider.dart';
import 'package:mise_gui/features/tools/presentation/tools_page.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/history_service.dart';
import 'package:mise_gui/services/mise_cli_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class ScopeProcess implements MiseProcessService {
  ScopeProcess(this.layout);
  final ToolchainLayout layout;
  final calls = <List<String>>[];
  var selected = '99.1.1';
  Map<String, dynamic> get rows => {
    'node': [
      for (final v in ['99.1.1', '99.1.2'])
        {
          'version': v,
          'installed': true,
          'active': selected == v,
          'install_path': layout.installTarget('node', v),
          'source': {'type': 'mise.toml', 'path': layout.globalConfigPath},
        },
    ],
  };
  @override
  Future<MiseCommandResult> run(MiseCommandRequest request) async {
    final args = request.arguments;
    calls.add(args);
    var output = '';
    if (args.first == 'ls') {
      final scoped = rows;
      if (request.workingDirectory != layout.home &&
          request.workingDirectory != null) {
        final config = File('${request.workingDirectory}/mise.toml');
        if (config.existsSync()) {
          final version = RegExp(
            r'node = "([^"]+)"',
          ).firstMatch(config.readAsStringSync())?.group(1);
          for (final row in scoped['node'] as List) {
            row['active'] = row['version'] == version;
          }
        }
      }
      output = jsonEncode(scoped);
    } else if (args.first == 'use') {
      final project = args[1] == '--path';
      final file = File(project ? args[2] : layout.globalConfigPath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        '[tools]\nnode = "${args.last.split('@').last}"\n',
      );
      if (!project) selected = args.last.split('@').last;
    } else {
      throw StateError('Unexpected mutation: $args');
    }
    return MiseCommandResult(
      request: request,
      stdout: output,
      stderr: '',
      exitCode: 0,
      duration: Duration.zero,
    );
  }

  @override
  Future<String> resolveExecutablePath() async => 'mise';
  @override
  Future<ShellEnvironmentLoadResult> inspectShellEnvironment() async =>
      const ShellEnvironmentLoadResult(source: ShellEnvironmentSource.shell);
  @override
  Future<WindowsShimPathStatus> inspectWindowsShimPath() async =>
      const WindowsShimPathStatus(source: WindowsShimPathSource.unsupported);
}

class ScopeCli extends MockMiseCliService {
  ScopeCli(this.process, {this.empty = false});
  final ScopeProcess process;
  final bool empty;
  int remoteCalls = 0;
  @override
  Future<List<ToolRecord>> fetchTools() async => empty
      ? []
      : [
          ToolRecord(
            id: 'node',
            name: 'Node.js',
            category: 'Node.js 版本管理',
            description: '测试运行时',
            activeVersion: process.selected,
            requestedVersion: '99',
            source: '全局',
            strategy: '分类目录',
            latestStableVersion: '待同步',
            latestPreviewVersion: '待同步',
            installedVersions: [
              for (final v in ['99.1.1', '99.1.2'])
                ToolVersionRecord(
                  version: v,
                  channel: '本机',
                  note: '',
                  commandPreview: '',
                  level: HealthLevel.info,
                  isInstalled: true,
                  isActive: v == process.selected,
                ),
            ],
            remoteVersions: const [],
            projectImpacts: const [],
            quickActions: const [],
            commandPreview: '',
            level: HealthLevel.info,
            remoteState: ToolRemoteState.pending,
          ),
        ];
  @override
  Future<ToolRecord> hydrateToolRemoteState(ToolRecord tool) async {
    remoteCalls++;
    return tool.copyWith(
      remoteState: ToolRemoteState.ready,
      latestStableVersion: '99.9.9',
      remoteVersions: const [
        ToolVersionRecord(
          version: '99.9.9',
          channel: '稳定',
          note: '',
          commandPreview: 'mise use --global go@99.9.9',
          level: HealthLevel.info,
        ),
      ],
    );
  }
}

Future<void> settleIO(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 40));
    if (ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Expected isolated operation did not complete.');
}

class ImmediateHistory implements HistoryService {
  const ImmediateHistory();
  @override
  Future<List<HistoryEntry>> fetchHistory() async => [];
  @override
  Future<void> appendEntry(HistoryEntry entry) async {}
}

void main() {
  late Directory temp, project;
  late ToolchainLayout layout, previous;
  late ScopeProcess process;
  late ScopeCli cli;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('devworkbench-scope-');
    final root = await temp.resolveSymbolicLinks();
    previous = ToolchainLayout.current;
    layout = ToolchainLayout(home: root);
    ToolchainLayout.current = layout;
    process = ScopeProcess(layout);
    cli = ScopeCli(process);
    project = Directory("$root/Project O'Connor");
    await project.create();
    for (final v in ['99.1.1', '99.1.2']) {
      await Directory(
        '${layout.installTarget('node', v)}/bin',
      ).create(recursive: true);
      await File(
        '${layout.installTarget('node', v)}/bin/node',
      ).writeAsString('fixture');
    }
    await File(layout.globalConfigPath).parent.create(recursive: true);
    await File(layout.globalConfigPath).writeAsString('global-original');
    await File('${project.path}/mise.toml').writeAsString('project-original');
  });
  tearDown(() async {
    ToolchainLayout.current = previous;
    await temp.delete(recursive: true);
  });

  Future<void> page(WidgetTester tester, {bool empty = false}) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (empty) cli = ScopeCli(process, empty: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...isolatedWorkbenchOverrides(),
          miseProcessServiceProvider.overrideWithValue(process),
          miseCliServiceProvider.overrideWithValue(cli),
          historyServiceProvider.overrideWithValue(const ImmediateHistory()),
          projectDirectoryPickerProvider.overrideWithValue(
            () async => project.path,
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ToolsPage(
              initialTool: empty ? 'go' : 'node',
              initialTab: empty ? 'available' : null,
            ),
          ),
        ),
      ),
    );
    await settleIO(
      tester,
      () => empty
          ? find.text('可安装版本').evaluate().isNotEmpty
          : find.text('已安装版本').evaluate().isNotEmpty,
    );
  }

  Future<void> preview(WidgetTester tester, String action) async {
    final card = find.byKey(const ValueKey('installed-node-99.1.2'));
    final button = find.descendant(of: card, matching: find.text(action));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.runAsync(() => tester.tap(button));
    await settleIO(tester, () => find.text('确认切换').evaluate().isNotEmpty);
  }

  testWidgets(
    'project preview cancels safely, then writes only the chosen project with literal path quoting',
    (tester) async {
      await page(tester);
      expect(cli.remoteCalls, 0);
      await preview(tester, '用于指定项目');
      final dialog = find.byType(Dialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('${project.path}/mise.toml'),
        ),
        findsWidgets,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.text(layout.globalConfigPath),
        ),
        findsNothing,
      );
      expect(process.calls.where((c) => c.first == 'use'), isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(
        File('${project.path}/mise.toml').readAsStringSync(),
        'project-original',
      );
      await preview(tester, '用于指定项目');
      await tester.runAsync(() => tester.tap(find.text('确认切换')));
      await settleIO(
        tester,
        () =>
            process.calls.any((c) => c.first == 'use') &&
            find.byType(Dialog).evaluate().isEmpty,
      );
      expect(process.calls.where((c) => c.first == 'use').single, [
        'use',
        '--path',
        '${project.path}/mise.toml',
        'node@99.1.2',
      ]);
      expect(
        File(layout.globalConfigPath).readAsStringSync(),
        'global-original',
      );
      expect(
        File('${project.path}/mise.toml').readAsStringSync(),
        contains('99.1.2'),
      );
      expect(
        process.calls.where((c) => c.first.startsWith('install')),
        isEmpty,
      );
      expect(cli.remoteCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'global preview and execution retain the existing project configuration',
    (tester) async {
      await page(tester);
      await preview(tester, '设为全局默认');
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(layout.globalConfigPath),
        ),
        findsWidgets,
      );
      await tester.runAsync(() => tester.tap(find.text('确认切换')));
      await settleIO(
        tester,
        () =>
            process.calls.any((c) => c.first == 'use') &&
            find.byType(Dialog).evaluate().isEmpty,
      );
      expect(process.calls.where((c) => c.first == 'use').single, [
        'use',
        '--global',
        'node@99.1.2',
      ]);
      expect(
        File('${project.path}/mise.toml').readAsStringSync(),
        'project-original',
      );
      expect(
        File(layout.globalConfigPath).readAsStringSync(),
        contains('99.1.2'),
      );
      expect(cli.remoteCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'missing runtime has a real remote-install flow without fabricated installed versions or implicit activation',
    (tester) async {
      await page(tester, empty: true);
      expect(find.text('可安装工具'), findsOneWidget);
      expect(find.byKey(const ValueKey('tool-accordion-go')), findsOneWidget);
      expect(cli.remoteCalls, 1);
      final install = find.descendant(
        of: find.byKey(const ValueKey('remote-go-99.9.9')),
        matching: find.text('安装'),
      );
      await tester.ensureVisible(install);
      await tester.pumpAndSettle();
      await tester.runAsync(() => tester.tap(install));
      await settleIO(tester, () => find.text('确认安装').evaluate().isNotEmpty);
      expect(find.textContaining('mise install-into go@99.9.9'), findsWidgets);
      expect(
        find.textContaining(layout.installTarget('go', '99.9.9')),
        findsWidgets,
      );
      expect(process.calls.where((c) => c.first != 'ls'), isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('已安装').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('已安装').first);
      await tester.pumpAndSettle();
      expect(find.text('尚未安装运行时，可切换到“可安装”查询版本。'), findsOneWidget);
      expect(
        File(layout.globalConfigPath).readAsStringSync(),
        'global-original',
      );
      expect(
        Directory(layout.installTarget('go', '99.9.9')).existsSync(),
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
