import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/app/bootstrap/dependencies.dart';
import 'package:mise_gui/app/theme/app_theme.dart';
import 'package:mise_gui/features/tools/presentation/tools_page.dart';
import 'package:mise_gui/services/history_service.dart';
import 'package:mise_gui/services/mise_cli_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class _InstallRecorder implements MiseProcessService {
  final commands = <List<String>>[];
  final rows = <String, dynamic>{};
  @override
  Future<MiseCommandResult> run(MiseCommandRequest request) async {
    final args = request.arguments;
    commands.add(args);
    var output = '';
    if (args.first == 'ls') {
      output = jsonEncode(rows);
    } else if (args.first == 'ls-remote') {
      output = '[]';
    } else if (args.first == 'install-into') {
      // An offline installer fixture: exercise filesystem destinations without
      // downloading an SDK or touching the user's actual toolchains.
      Directory('${args[2]}/bin').createSync(recursive: true);
      File('${args[2]}/bin/node').writeAsStringSync('fixture');
    } else if (args.first == 'link') {
      final spec = args[1].split('@');
      rows[spec[0]] = [
        {
          'version': spec[1],
          'installed': true,
          'active': false,
          'install_path': args[2],
        },
      ];
    } else if (args.first != 'reshim') {
      throw StateError('Unexpected command: $args');
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

Future<void> _settleIO(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 300; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (ready()) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('The UI did not finish the expected I/O stage.');
}

void main() {
  testWidgets(
    'Tools install preview and execution use the classified target without switching defaults',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('mise-menu-install-');
      final previous = ToolchainLayout.current;
      final root = temp.resolveSymbolicLinksSync();
      final layout = ToolchainLayout(home: root);
      ToolchainLayout.current = layout;
      addTearDown(() async {
        ToolchainLayout.current = previous;
        temp.deleteSync(recursive: true);
      });
      tester.view.physicalSize = const Size(1600, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final recorder = _InstallRecorder();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            miseProcessServiceProvider.overrideWithValue(recorder),
            miseCliServiceProvider.overrideWithValue(
              const MockMiseCliService(),
            ),
            historyServiceProvider.overrideWithValue(
              const MockHistoryService(),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const Scaffold(body: ToolsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('安装工具'));
      await tester.pumpAndSettle();
      expect(find.text('安装后会直接写成全局默认版本。'), findsNothing);
      await tester.enterText(find.widgetWithText(TextField, 'Tool'), 'node');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Version'),
        '99.1.2',
      );
      await tester.runAsync(() => tester.tap(find.text('继续预览')));
      await _settleIO(tester, () => find.text('确认安装').evaluate().isNotEmpty);
      final target = layout.installTarget('node', '99.1.2');
      expect(
        find.textContaining('mise install-into node@99.1.2'),
        findsWidgets,
      );
      expect(find.textContaining(target), findsWidgets);
      expect(
        recorder.commands.where((c) => c.first == 'install-into'),
        isEmpty,
      );
      await tester.runAsync(() => tester.tap(find.text('确认安装')));
      await _settleIO(
        tester,
        () =>
            recorder.commands.any((c) => c.first == 'reshim') &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty &&
            find.byType(CircularProgressIndicator).evaluate().isEmpty,
      );
      final mutations = recorder.commands
          .where((c) => !['ls', 'ls-remote'].contains(c.first))
          .toList();
      expect(mutations, [
        ['install-into', 'node@99.1.2', target],
        ['link', 'node@99.1.2', target],
        ['reshim'],
      ]);
      expect(File('$target/bin/node').existsSync(), isTrue);
      expect(
        Directory('${layout.dataDir}/installs/node/99.1.2').existsSync(),
        isFalse,
      );
      expect(File(layout.globalConfigPath).existsSync(), isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
