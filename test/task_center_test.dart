import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/config_service.dart';
import 'package:mise_gui/services/tracked_config_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/tracked_mise_action_service.dart';
import 'package:mise_gui/services/workbench_json_store.dart';

class FixtureProcess implements MiseProcessService {
  FixtureProcess(this.layout);
  final ToolchainLayout layout;
  bool installed = true, active = true;
  int commandExit = 0;
  Completer<void>? gate;
  @override
  Future<MiseCommandResult> run(MiseCommandRequest request) async {
    String output = '';
    if (request.arguments.first == 'ls') {
      output = jsonEncode({
        'node': installed
            ? [
                {
                  'version': '99.1.2',
                  'installed': true,
                  'active': active,
                  'install_path': layout.installTarget('node', '99.1.2'),
                },
              ]
            : [],
      });
    } else {
      await gate?.future;
      request.onOutput?.call(
        const MiseCommandOutputChunk(
          source: MiseCommandOutputSource.stdout,
          text: 'token=private-test-value\n',
        ),
      );
    }
    return MiseCommandResult(
      request: request,
      stdout: output,
      stderr: '',
      exitCode: request.arguments.first == 'ls' ? 0 : commandExit,
      duration: Duration.zero,
    );
  }

  @override
  Future<String> resolveExecutablePath() async => 'fixture';
  @override
  Future<ShellEnvironmentLoadResult> inspectShellEnvironment() async =>
      const ShellEnvironmentLoadResult(
        source: ShellEnvironmentSource.unsupported,
      );
  @override
  Future<WindowsShimPathStatus> inspectWindowsShimPath() async =>
      const WindowsShimPathStatus(source: WindowsShimPathSource.unsupported);
}

void main() {
  late Directory temp;
  late TaskCenter center;
  late ToolchainLayout layout;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('devworkbench-tasks-');
    layout = ToolchainLayout(home: temp.resolveSymbolicLinksSync());
    Directory(
      '${layout.installTarget('node', '99.1.2')}/bin',
    ).createSync(recursive: true);
    File(
      '${layout.installTarget('node', '99.1.2')}/bin/node',
    ).writeAsStringSync('fixture');
    center = TaskCenter(WorkbenchJsonStore(File('${temp.path}/tasks.json')));
  });
  tearDown(() async {
    await center.flush();
    center.dispose();
    await temp.delete(recursive: true);
  });

  test(
    'persists real steps, output and verification; recovers unfinished tasks as interrupted',
    () async {
      final finished = center.start('version', 'mise', ['command', 'verify']);
      finished.step(0, TaskStepStatus.succeeded, exitCode: 0);
      finished.step(1, TaskStepStatus.succeeded);
      finished.output('done\n');
      finished.finish(const TaskVerification(true, 'selected scope verified'));
      final running = center.start('scan', '目录扫描', ['measure']);
      running.step(0, TaskStepStatus.running);
      await center.flush();
      final loaded = TaskCenter(
        WorkbenchJsonStore(File('${temp.path}/tasks.json')),
      );
      expect(loaded.find(running.id)!.status, TaskStatus.interrupted);
      expect(loaded.find(finished.id)!.verification, 'selected scope verified');
      expect(loaded.find(finished.id)!.steps.first.exitCode, 0);
      expect(loaded.busy, isFalse);
      loaded.dispose();
      expect(File('${temp.path}/tasks.json').statSync().mode & 0x1ff, 0x180);
    },
  );
  test(
    'bounds output, strips terminal escapes and redacts credentials across chunks',
    () {
      final t = center.start('probe', 'checks', ['run']);
      t.output('x' * 40000);
      t.output('\u001b[31mpassword=');
      t.output('private-value\nhttps://user:pass@example.test\n');
      final output = center.find(t.id)!.output;
      expect(output.length, lessThan(33000));
      expect(output, contains('[较早输出已截断]'));
      expect(output, contains('[已隐藏]'));
      expect(output, isNot(contains('private-value')));
      expect(output, isNot(contains('user:pass')));
      expect(output, isNot(contains('\u001b')));
      t.output('Authorization: Bearer private-');
      t.output('bearer-value\n');
      expect(
        center.find(t.id)!.output,
        isNot(contains('private-bearer-value')),
      );
    },
  );
  test(
    'failed task marks remaining steps skipped and never reports full completion',
    () {
      final t = center.start('fail', 'mise', ['run', 'verify']);
      t.step(0, TaskStepStatus.running);
      t.finish(const TaskVerification(false, 'failed'));
      expect(center.find(t.id)!.steps.map((s) => s.status), [
        TaskStepStatus.failed,
        TaskStepStatus.skipped,
      ]);
      expect(center.find(t.id)!.progress, 0);
    },
  );
  test('prunes completed history while retaining running work', () async {
    final running = center.start('active', 'mise', ['run']);
    for (var i = 0; i < 45; i++) {
      center
          .start('$i', 'checks', ['run'])
          .finish(const TaskVerification(true, 'ok'));
    }
    expect(center.find(running.id), isNotNull);
    expect(center.state.tasks.length, lessThanOrEqualTo(41));
  });
  test(
    'corrupt history is preserved and persistence errors remain visible',
    () async {
      final file = File('${temp.path}/broken.json')
        ..writeAsStringSync('{broken');
      final broken = TaskCenter(WorkbenchJsonStore(file));
      broken
          .start('task', 'mise', ['run'])
          .finish(const TaskVerification(true, 'ok'));
      await broken.flush();
      expect(file.readAsStringSync(), '{broken');
      expect(broken.state.persistenceError, isNotNull);
      broken.dispose();
    },
  );
  test('saving manager configuration excludes competing work', () {
    final t = center.start('save', '管理器设置', ['write']);
    expect(() => center.start('run', 'mise', ['run']), throwsStateError);
    t.finish(const TaskVerification(true, 'ok'));
    expect(() => center.start('run', 'mise', ['run']), returnsNormally);
  });
  test(
    'configuration save verifies content without recording its values',
    () async {
      final file = File('${temp.path}/config.toml')
        ..writeAsStringSync('[tools]\nnode = "24.0.0"\n');
      final document = ConfigDocumentData(
        id: 'global',
        title: 'global',
        path: file.path,
        content: file.readAsStringSync(),
        description: '',
        commandPreview: '',
        exists: true,
      );
      await TrackedConfigService(
        const LiveConfigService(),
        center,
      ).saveDocument(
        document: document,
        nextContent: '[env]\nTOKEN = "private-fixture"',
      );
      expect(file.readAsStringSync(), '[env]\nTOKEN = "private-fixture"\n');
      expect(center.state.tasks.first.status, TaskStatus.succeeded);
      expect(
        center.state.tasks.first.output,
        isNot(contains('private-fixture')),
      );
      await expectLater(
        TrackedConfigService(
          const LiveConfigService(),
          center,
        ).saveDocument(document: document, nextContent: 'stale'),
        throwsStateError,
      );
      expect(center.state.tasks.first.status, TaskStatus.failed);
      expect(file.readAsStringSync(), contains('private-fixture'));
    },
  );
  TrackedMiseActionService service(FixtureProcess process) {
    final policy = ClassifiedToolchainService(process, layout);
    return TrackedMiseActionService(
      LocalMiseActionService(process, policy: policy),
      center,
      policy,
    );
  }

  test(
    'mise operation records command exit and verifies the selected scope',
    () async {
      final result = await service(
        FixtureProcess(layout),
      ).runScript('mise use --global node@99.1.2');
      expect(result.isSuccess, isTrue);
      final task = center.state.tasks.first;
      expect(task.status, TaskStatus.succeeded);
      expect(
        task.steps.every((s) => s.status == TaskStepStatus.succeeded),
        isTrue,
      );
      expect(task.output, isNot(contains('private-test-value')));
      expect(task.verification, contains('作用域选择通过'));
    },
  );
  test(
    'zero exit does not hide a failed version selection verification',
    () async {
      final result = await service(
        FixtureProcess(layout)..active = false,
      ).runScript('mise use --global node@99.1.2');
      expect(result.exitCode, 0);
      expect(result.isSuccess, isFalse);
      expect(center.state.tasks.first.status, TaskStatus.failed);
      expect(center.state.tasks.first.verification, contains('选择验证失败'));
    },
  );
  test(
    'nonzero command skips postcondition checks and records the failure',
    () async {
      final result = await service(
        FixtureProcess(layout)..commandExit = 7,
      ).runScript('mise use --global node@99.1.2');
      expect(result.isSuccess, isFalse);
      expect(center.state.tasks.first.steps[1].exitCode, 7);
      expect(
        center.state.tasks.first.steps.last.status,
        TaskStepStatus.skipped,
      );
    },
  );
  test(
    'concurrent mise mutation is rejected until running task finishes',
    () async {
      final process = FixtureProcess(layout)..gate = Completer<void>();
      final runner = service(process);
      final first = runner.runScript('mise use --global node@99.1.2');
      await expectLater(
        runner.runScript('mise use --global node@99.1.2'),
        throwsStateError,
      );
      process.gate!.complete();
      await first;
      expect(center.managerBusy('mise'), isFalse);
    },
  );
}
