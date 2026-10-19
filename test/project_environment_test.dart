import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_action_service.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_environment_tasks.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_launcher.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_scan_service.dart';
import 'package:mise_gui/services/project_version_service.dart';
import 'package:mise_gui/services/task_center.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/tracked_mise_action_service.dart';
import 'package:mise_gui/services/workbench_json_store.dart';
import 'classified_toolchain_service_test.dart' show IsolatedMiseProcess;
import 'tools_version_scope_test.dart' show ScopeProcess;

class ProjectQuery implements MiseQueryService {
  Map<String, List<MiseInstalledToolVersionRef>> rows = {};
  bool fail = false;
  final paths = <String?>[];
  @override
  Future<Map<String, List<MiseInstalledToolVersionRef>>> fetchInstalledTools({
    String? workingDirectory,
  }) async {
    paths.add(workingDirectory);
    if (fail) throw StateError('not trusted');
    return rows;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected query: ${invocation.memberName}');
}

LocalTool localTool(String id, String version) => LocalTool(
  id: id,
  name: id,
  category: LocalToolCategory.runtime,
  description: '',
  status: LocalToolStatus.ready,
  manager: 'fixture',
  source: 'fixture',
  version: version,
);
MiseInstalledToolVersionRef scopedTool(
  String tool,
  String version, {
  bool active = true,
}) => MiseInstalledToolVersionRef(
  tool: tool,
  version: version,
  installed: true,
  active: active,
  source: const MiseSourceRef(type: 'mise.toml', path: '/project/mise.toml'),
);

void main() {
  const profiles = ProjectProfileService();
  late Directory temp;
  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'devworkbench-project-',
    );
    temp = Directory(await created.resolveSymbolicLinks());
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'manifest-only projects are discovered without mise queries or script execution',
    () async {
      final app = Directory('${temp.path}/frontend')..createSync();
      File('${app.path}/package.json').writeAsStringSync(
        '{"dependencies":{"vue":"3","typescript":"5"},"scripts":{"postinstall":"touch SHOULD_NOT_EXIST"}}',
      );
      final ignored = Directory('${app.path}/node_modules/vendor')
        ..createSync(recursive: true);
      File('${ignored.path}/package.json').writeAsStringSync('{}');
      final query = ProjectQuery();
      final result = await LiveProjectScanService(
        queryService: query,
      ).fetchProjects([ScanDirectoryRecord(path: temp.path)]);
      expect(result.map((p) => p.name), ['frontend']);
      expect(result.single.environment, contains('Vue'));
      expect(result.single.environment, contains('TypeScript'));
      expect(query.paths, isEmpty);
      expect(File('${app.path}/SHOULD_NOT_EXIST').existsSync(), isFalse);
    },
  );

  test(
    'parses mixed Java, Python, Go, Rust and Flutter requirements with evidence',
    () {
      final p = profiles.parse(
        temp.path,
        {
          'pom.xml':
              '<project><properties><maven.compiler.release>17</maven.compiler.release></properties></project>',
          'pyproject.toml':
              '[project]\nrequires-python = ">=3.12,<4"\ndependencies = ["fastapi>=0.100"]',
          'go.mod': 'module example.test/app\ngo 1.27\ntoolchain go1.27.2\n',
          'Cargo.toml': '[package]\nname="app"\nrust-version="1.99"\n',
          'pubspec.yaml':
              'name: app\nenvironment:\n  sdk: ">=3.13.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\n',
          '.mise.toml': '[tools]\nnode="24"\n',
        },
        present: {'mvnw', 'uv.lock', 'api/bruno/bruno.json'},
      );
      expect(
        p.stacks,
        containsAll([
          'Java / Maven',
          'Python',
          'FastAPI',
          'Go',
          'Rust',
          'Flutter',
        ]),
      );
      expect(p.requirements.firstWhere((r) => r.tool == 'java').value, '17');
      expect(p.requirements.where((r) => r.tool == 'go'), hasLength(2));
      expect(p.providedTools, ['maven']);
      expect(p.toolIds, containsAll(['java', 'uv', 'dart', 'node']));
      expect(p.brunoPath, '${temp.path}/api/bruno');
    },
  );

  test('node manager selection and shell quoting use saved scripts only', () {
    final p = profiles.parse(
      "${temp.path}/a'b \$(safe)",
      {
        'package.json':
            '{"packageManager":"pnpm@12.11.2+sha512.hash","scripts":{"dev":"vite --host","test:unit":"vitest"}}',
      },
      present: {'pnpm-lock.yaml', 'package-lock.json'},
    );
    expect(p.scripts, hasLength(2));
    expect(p.scripts.first.command, contains('pnpm run'));
    expect(parseCommandArguments(p.scripts.first.command).take(2), [
      'cd',
      p.path,
    ]);
    expect(p.scripts.first.command, isNot(contains('vite --host')));
    expect(p.warnings, contains(contains('多个 Node 锁文件')));
    expect(p.requirements.single.value, '12.11.2');
  });

  test('malformed metadata remains visible as a warning', () async {
    File('${temp.path}/package.json').writeAsStringSync('{broken');
    File('${temp.path}/pyproject.toml').writeAsStringSync('[project');
    final p = await profiles.inspect(temp.path);
    expect(p.evidence, containsAll(['package.json', 'pyproject.toml']));
    expect(p.warnings, hasLength(2));
  });

  test('metadata reader refuses symlinked files and oversized input', () async {
    final outside = File('${temp.path}/outside')..writeAsStringSync('private');
    final project = Directory('${temp.path}/project')..createSync();
    Link('${project.path}/package.json').createSync(outside.path);
    File(
      '${project.path}/pyproject.toml',
    ).writeAsStringSync('a' * (ProjectProfileService.maxBytes + 1));
    final p = await profiles.inspect(project.path);
    expect(p.evidence, isEmpty);
    expect(p.warnings, hasLength(2));
    expect(p.warnings.join(), isNot(contains('private')));
  });

  test(
    'Oracle Java, minimum Go and common version bounds compare conservatively',
    () {
      bool? matches(
        String actual,
        String wanted, [
        ProjectRequirementKind kind = ProjectRequirementKind.prefix,
      ]) => ProjectEnvironmentService.satisfies(
        actual,
        ProjectRequirement('java', wanted, 'fixture', kind: kind),
      );
      expect(matches('oracle-17.0.20', '17'), isTrue);
      expect(matches('oracle-8.0.503', '1.8'), isTrue);
      expect(matches('1.27.2', '1.27', ProjectRequirementKind.minimum), isTrue);
      expect(
        matches('1.26.9', '1.27', ProjectRequirementKind.minimum),
        isFalse,
      );
      expect(
        matches('3.14.8', '>=3.12,<4', ProjectRequirementKind.constraint),
        isTrue,
      );
      expect(
        matches(
          '24.21.0',
          '^24.0.0 || ^26.0.0',
          ProjectRequirementKind.constraint,
        ),
        isTrue,
      );
      expect(
        matches(
          '25.0.0',
          '^24.0.0 || ^26.0.0',
          ProjectRequirementKind.constraint,
        ),
        isFalse,
      );
      expect(matches('24.21.0', 'lts/*'), isNull);
      expect(
        matches('24.21.0', '>=22 || custom', ProjectRequirementKind.constraint),
        isNull,
      );
    },
  );

  test(
    'installed SDK is never presented as project effective after query failure',
    () async {
      File('${temp.path}/mise.toml').writeAsStringSync('[tools]\nnode="22"');
      final query = ProjectQuery()..fail = true;
      final result = await ProjectEnvironmentService(profiles, query).inspect(
        temp.path,
        LocalToolSnapshot(
          tools: [localTool('node', '24.21.0')],
          scannedAt: DateTime.now(),
        ),
      );
      expect(result.checks.single.state, ProjectToolState.review);
      expect(result.checks.single.effective, isNull);
      expect(result.queryIssue, isNotNull);
      expect(query.paths, [temp.path]);
    },
  );

  test(
    'mismatched project runtime and missing tools are explicit; wrappers stay unverified',
    () {
      final p = profiles.parse(
        temp.path,
        {
          'package.json': '{"engines":{"node":">=26.0.0"}}',
          'pom.xml': '<project/>',
        },
        present: {'mvnw'},
      );
      final query = ProjectQuery();
      final result = ProjectEnvironmentService(profiles, query).compare(
        p,
        LocalToolSnapshot(
          tools: [localTool('node', '24.21.0')],
          scannedAt: DateTime.now(),
        ),
        {
          'node': [scopedTool('node', '24.21.0')],
        },
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'node').state,
        ProjectToolState.mismatch,
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'java').state,
        ProjectToolState.missing,
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'maven').state,
        ProjectToolState.projectProvided,
      );
    },
  );

  test(
    'explicit environment checks record warning and failed task outcomes',
    () async {
      File(
        '${temp.path}/package.json',
      ).writeAsStringSync('{"engines":{"node":">=26.0.0"}}');
      final center = TaskCenter(WorkbenchJsonStore(null));
      addTearDown(center.dispose);
      final service = ProjectEnvironmentService(profiles, ProjectQuery());
      await checkProjectEnvironment(
        service,
        center,
        temp.path,
        Future.value(LocalToolSnapshot(tools: [], scannedAt: DateTime.now())),
      );
      expect(center.state.tasks.first.status, TaskStatus.warning);
      await expectLater(
        checkProjectEnvironment(
          service,
          center,
          '${temp.path}/missing',
          Future.value(LocalToolSnapshot(tools: [], scannedAt: DateTime.now())),
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(center.state.tasks.first.status, TaskStatus.failed);
    },
  );

  Future<(ProjectVersionService, ScopeProcess, Directory)>
  versionFixture() async {
    final layout = ToolchainLayout(home: temp.path);
    for (final version in ['99.1.1', '99.1.2']) {
      final bin = Directory('${layout.installTarget('node', version)}/bin')
        ..createSync(recursive: true);
      File('${bin.path}/node').writeAsStringSync('fixture');
    }
    final process = ScopeProcess(layout),
        policy = ClassifiedToolchainService(ScopeProcess(layout), layout);
    final actionsPolicy = ClassifiedToolchainService(process, layout);
    final center = TaskCenter(WorkbenchJsonStore(null));
    addTearDown(center.dispose);
    final actions = TrackedMiseActionService(
      LocalMiseActionService(process, policy: actionsPolicy),
      center,
      actionsPolicy,
    );
    final project = Directory("${temp.path}/project's space")..createSync();
    return (ProjectVersionService(policy, actions), process, project);
  }

  test(
    'project preview and apply select installed exact version and preserve global scope',
    () async {
      final (service, process, project) = await versionFixture();
      final plan = await service.preview(project.path, 'node', '99.1.2');
      expect(process.calls, isEmpty);
      expect((await service.apply(plan)).isSuccess, isTrue);
      expect(File(plan.configPath).readAsStringSync(), contains('99.1.2'));
      expect(process.selected, '99.1.1');
      expect(process.calls.where((c) => c.first == 'use').single[1], '--path');
      expect(process.calls.where((c) => c.first == 'install-into'), isEmpty);
    },
  );

  test(
    'stale preview, symlink replacement and missing SDK refuse project writes',
    () async {
      final (service, process, project) = await versionFixture();
      final plan = await service.preview(project.path, 'node', '99.1.2');
      final config = File(plan.configPath)
        ..writeAsStringSync('[tools]\nnode="99.1.1"');
      await expectLater(service.apply(plan), throwsStateError);
      expect(process.calls.where((c) => c.first == 'use'), isEmpty);
      config.deleteSync();
      Link(config.path).createSync('${temp.path}/external.toml');
      await expectLater(service.apply(plan), throwsFormatException);
      await expectLater(
        service.preview(project.path, 'node', '99.9.9'),
        throwsFormatException,
      );
    },
  );

  test(
    'real mise project pin preserves TOML sections and user defaults in isolation',
    () async {
      if (!File('/opt/homebrew/bin/mise').existsSync()) return;
      final layout = ToolchainLayout(home: temp.path),
          process = IsolatedMiseProcess(ToolchainLayout(home: temp.path));
      final policy = ClassifiedToolchainService(process, layout);
      for (final version in ['24.21.0', '22.20.0']) {
        final path = layout.installTarget('node', version);
        Directory('$path/bin').createSync(recursive: true);
        File('$path/bin/node').writeAsStringSync('isolated SDK');
        await process.run(
          MiseCommandRequest(arguments: ['link', 'node@$version', path]),
        );
      }
      final global = File(layout.globalConfigPath)
        ..parent.createSync(recursive: true);
      global.writeAsStringSync('[tools]\nnode="24.21.0"\n');
      final before = global.readAsStringSync();
      final project = Directory('${temp.path}/project')..createSync();
      final config = File('${project.path}/mise.toml')
        ..writeAsStringSync(
          '# keep comment\n[env]\nKEEP="unchanged"\n[tools]\nnode="24.21.0"\n',
        );
      final center = TaskCenter(WorkbenchJsonStore(null));
      addTearDown(center.dispose);
      final actions = TrackedMiseActionService(
        LocalMiseActionService(process, policy: policy),
        center,
        policy,
      );
      final service = ProjectVersionService(policy, actions);
      final plan = await service.preview(project.path, 'node', '22.20.0');
      expect((await service.apply(plan)).isSuccess, isTrue);
      expect(config.readAsStringSync(), contains('KEEP="unchanged"'));
      expect(config.readAsStringSync(), contains('# keep comment'));
      expect(global.readAsStringSync(), before);
    },
  );

  test(
    'project launch uses literal arguments and rejects missing paths',
    () async {
      final process = OpenProcess(), launcher = ProjectLauncher(OpenProcess());
      final project = Directory("${temp.path}/a'b \$(touch unsafe)")
        ..createSync();
      final app = Directory('${temp.path}/Editor.app')..createSync();
      await ProjectLauncher(
        process,
      ).open(project.path, applicationPath: app.path);
      expect(process.arguments, ['-a', app.path, project.path]);
      expect(process.executable, '/usr/bin/open');
      await expectLater(
        launcher.open('${temp.path}/missing'),
        throwsStateError,
      );
      expect(File('${temp.path}/unsafe').existsSync(), isFalse);
    },
  );
  test('Dart follows the project-selected Flutter SDK', () async {
    File('${temp.path}/pubspec.yaml').writeAsStringSync(
      'environment:\n  sdk: ">=3.13.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\n',
    );
    final sdk = Directory('${temp.path}/sdk/bin/cache/dart-sdk')
      ..createSync(recursive: true);
    File('${sdk.path}/version').writeAsStringSync('3.13.5\n');
    final query = ProjectQuery()
      ..rows = {
        'flutter': [
          MiseInstalledToolVersionRef(
            tool: 'flutter',
            version: '3.47.7',
            installed: true,
            active: true,
            installPath: '${temp.path}/sdk',
          ),
        ],
      };
    final result = await ProjectEnvironmentService(profiles, query).inspect(
      temp.path,
      LocalToolSnapshot(
        tools: [localTool('dart', '3.10.0')],
        scannedAt: DateTime.now(),
      ),
    );
    final dart = result.checks.firstWhere((c) => c.tool == 'dart');
    expect(dart.effective, '3.13.5');
    expect(dart.state, ProjectToolState.satisfied);
  });

  test(
    'Gradle static declarations and wrappers are recognized without execution',
    () {
      final p = profiles.parse(
        temp.path,
        {
          'build.gradle.kts':
              'plugins { id("com.android.application") } java { toolchain { languageVersion.set(JavaLanguageVersion.of(17)) } } exec { commandLine("touch", "unsafe") }',
        },
        present: {'gradlew'},
      );
      expect(p.toolIds, containsAll(['java', 'gradle', 'android-sdk']));
      expect(p.requirements.single.value, '17');
      expect(p.providedTools, ['gradle']);
      expect(p.warnings, contains(contains('仅识别静态声明')));
      expect(File('${temp.path}/unsafe').existsSync(), isFalse);
    },
  );

  test(
    'project pin rejects uninstalled versions and HOME before mutation',
    () async {
      final (service, process, project) = await versionFixture();
      await expectLater(
        service.preview(project.path, 'node', '99.9.9'),
        throwsStateError,
      );
      await expectLater(
        service.preview(temp.path, 'node', '99.1.1'),
        throwsStateError,
      );
      expect(process.calls, isEmpty);
    },
  );
}

class OpenProcess implements LocalToolProcess {
  List<String>? arguments;
  String? executable;
  @override
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    this.executable = executable;
    this.arguments = arguments;
    return const LocalCommandResult(0, '', '');
  }
}
