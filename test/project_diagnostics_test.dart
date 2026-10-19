import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_java_metadata.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_runtime_inspector.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'project_environment_test.dart' show ProjectQuery, localTool, scopedTool;

class DiagnosticQuery extends ProjectQuery {
  final executables = <String, String>{};
  final moduleRows = <String, List<MiseInstalledToolVersionRef>>{};
  @override
  Future<MiseResolvedExecutableRef> fetchExecutable(
    String subject, {
    String? workingDirectory,
  }) async => MiseResolvedExecutableRef(
    subject: subject,
    command: 'which',
    exitCode: executables.containsKey(subject) ? 0 : 1,
    stdout: executables[subject] ?? '',
    stderr: '',
  );
  @override
  Future<Map<String, List<MiseInstalledToolVersionRef>>> fetchInstalledTools({
    String? workingDirectory,
  }) async => moduleRows.containsKey(workingDirectory)
      ? {'java': moduleRows[workingDirectory]!}
      : super.fetchInstalledTools(workingDirectory: workingDirectory);
}

class DiagnosticProcess implements LocalToolProcess {
  final calls = <(String, List<String>, Map<String, String>)>[];
  final versions = <String, String>{};
  bool fail = false;
  @override
  Future<LocalCommandResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String> environment = const {},
    String? workingDirectory,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    calls.add((executable, arguments, environment));
    return LocalCommandResult(
      fail ? 1 : 0,
      versions[executable] ?? '',
      'sensitive stderr must not appear',
    );
  }
}

void main() {
  late Directory temp;
  late String root;
  late ToolchainLayout layout;
  late DiagnosticQuery query;
  late DiagnosticProcess process;
  const profiles = ProjectProfileService();
  LocalToolSnapshot local() => LocalToolSnapshot(
    tools: [localTool('npm', '99.0.0'), localTool('pnpm', '99.0.0')],
    scannedAt: DateTime.now(),
  );
  void write(String relative, String content) {
    final file = File('$root/$relative');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  String installed(String name, String version) {
    final file = File('${layout.root}/fixtures/$name');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('fixture');
    process.versions[file.path] = version;
    return file.path;
  }

  ProjectEnvironmentService service() => ProjectEnvironmentService(
    profiles,
    query,
    runtimeInspector: ProjectRuntimeInspector(
      process,
      layout,
      trustedRoots: [],
    ),
  );
  Future<void> venv({
    String name = '.venv',
    String cfg = '3.14.8',
    bool broken = false,
  }) async {
    write('$name/pyvenv.cfg', 'home = /unused\nversion = $cfg\n');
    final target = installed('python', '3.14.8');
    Directory('$root/$name/bin').createSync(recursive: true);
    Link(
      '$root/$name/bin/python',
    ).createSync(broken ? '$target-missing' : target);
    write(
      '$name/lib/python3.14/site-packages/pip-26.2.1.dist-info/METADATA',
      'Name: pip\nVersion: 26.2.1\n',
    );
  }

  setUp(() async {
    final created = await Directory.systemTemp.createTemp(
      'devworkbench-diagnostics-',
    );
    temp = Directory(await created.resolveSymbolicLinks());
    root = '${temp.path}/project';
    Directory(root).createSync();
    layout = ToolchainLayout(home: '${temp.path}/home');
    query = DiagnosticQuery();
    process = DiagnosticProcess();
    final node = File('${layout.root}/nodejs/versions/24.21.0/bin/node');
    node.parent.createSync(recursive: true);
    node.writeAsStringSync('fixture');
    query.rows = {
      'node': [
        MiseInstalledToolVersionRef(
          tool: 'node',
          version: '24.21.0',
          installed: true,
          active: true,
          installPath: node.parent.parent.path,
        ),
      ],
      'python': [scopedTool('python', '3.14.8')],
      'java': [scopedTool('java', 'oracle-21.0.12.1')],
    };
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'project npm and pnpm use resolved commands rather than desktop versions',
    () async {
      write(
        'package.json',
        '{"engines":{"npm":">=11.0.0"},"packageManager":"pnpm@12.11.2"}',
      );
      query.executables.addAll({
        'npm': installed('npm', '11.19.0'),
        'pnpm': installed('pnpm', '12.11.2'),
      });
      final result = await service().inspect(root, local());
      expect(
        result.checks.firstWhere((c) => c.tool == 'npm').state,
        ProjectToolState.satisfied,
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'pnpm').effective,
        '12.11.2',
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'pnpm').state,
        ProjectToolState.satisfied,
      );
      for (final call in process.calls) {
        expect(call.$2, ['--version']);
        expect(call.$3['COREPACK_ENABLE_NETWORK'], '0');
        expect(call.$3['COREPACK_ENABLE_AUTO_PIN'], '0');
        expect(call.$3['npm_config_manage_package_manager_versions'], 'false');
        expect(
          call.$3['PATH'],
          startsWith('${layout.root}/nodejs/versions/24.21.0/bin'),
        );
      }
    },
  );
  test(
    'actual package manager mismatch is visible, failed probes never leak stderr',
    () async {
      write('package.json', '{"packageManager":"pnpm@10.0.0"}');
      query.executables['pnpm'] = installed('pnpm', '12.11.2');
      expect(
        (await service().inspect(
          root,
          local(),
        )).checks.firstWhere((c) => c.tool == 'pnpm').state,
        ProjectToolState.mismatch,
      );
      process.fail = true;
      final check = (await service().inspect(
        root,
        local(),
      )).checks.firstWhere((c) => c.tool == 'pnpm');
      expect(check.state, ProjectToolState.review);
      expect(check.effective, isNull);
      expect(check.detail, isNot(contains('sensitive')));
    },
  );
  test(
    'project executables and custom Corepack sources are not executed',
    () async {
      write('package.json', '{"packageManager":"pnpm@12.11.2"}');
      write('bin/pnpm', 'untrusted');
      query.executables['pnpm'] = '$root/bin/pnpm';
      expect(
        (await service().inspect(
          root,
          local(),
        )).checks.firstWhere((c) => c.tool == 'pnpm').state,
        ProjectToolState.review,
      );
      expect(process.calls, isEmpty);
      write(
        'package.json',
        '{"packageManager":"pnpm@https://example.test/tool.js"}',
      );
      query.executables['pnpm'] = installed('pnpm', '12.11.2');
      await service().inspect(root, local());
      expect(process.calls, isEmpty);
    },
  );
  test(
    'untrusted mise scope does not fall back to global package managers',
    () async {
      write('package.json', '{"packageManager":"pnpm@12.11.2"}');
      query.fail = true;
      query.executables['pnpm'] = installed('pnpm', '12.11.2');
      final result = await service().inspect(root, local());
      expect(result.queryIssue, isNotNull);
      expect(process.calls, isEmpty);
      expect(
        result.checks.firstWhere((c) => c.tool == 'pnpm').effective,
        isNull,
      );
    },
  );
  test(
    'mise-selected venv verifies trusted base interpreter and reads project pip metadata',
    () async {
      write('pyproject.toml', '[project]\nrequires-python=">=3.14,<4"');
      write(
        'mise.toml',
        '[env._.python]\nvenv = { path = "./.venv", create = false }',
      );
      await venv();
      final result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.selected, isTrue);
      expect(result.pythonEnvironments.single.pipVersion, '26.2.1');
      expect(
        result.checks.firstWhere((c) => c.tool == 'python').state,
        ProjectToolState.satisfied,
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'pip').effective,
        '26.2.1',
      );
      expect(process.calls.single.$1, '${layout.root}/fixtures/python');
      expect(process.calls.single.$2.take(2), ['-I', '-S']);
    },
  );
  test(
    'unselected venv remains a candidate and does not override mise Python',
    () async {
      write('pyproject.toml', '[project]\nrequires-python=">=3.14"');
      await venv();
      final result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.selected, isFalse);
      expect(
        result.checks.firstWhere((c) => c.tool == 'python').source,
        '/project/mise.toml',
      );
      expect(result.checks.any((c) => c.tool == 'pip'), isFalse);
    },
  );
  test(
    'broken or inconsistent selected virtual environment remains unverified',
    () async {
      write('pyproject.toml', '[project]\nrequires-python=">=3.12"');
      write('mise.toml', '[env._.python]\nvenv=".venv"');
      await venv(broken: true);
      var result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.issue, isNotNull);
      expect(process.calls, isEmpty);
      expect(
        result.checks.firstWhere((c) => c.tool == 'python').effective,
        isNull,
      );
      Link('$root/.venv/bin/python').deleteSync();
      Link(
        '$root/.venv/bin/python',
      ).createSync('${layout.root}/fixtures/python');
      write('.venv/pyvenv.cfg', 'version = 3.12.0');
      result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.issue, contains('不一致'));
      expect(
        result.checks.firstWhere((c) => c.tool == 'python').state,
        ProjectToolState.review,
      );
    },
  );
  test(
    'external venv and project-owned Python binaries are never executed',
    () async {
      write('pyproject.toml', '[project]\nname="app"');
      write('mise.toml', '[env._.python]\nvenv="../outside"');
      var result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.issue, isNotNull);
      expect(process.calls, isEmpty);
      write('mise.toml', '[env._.python]\nvenv=".venv"');
      await venv();
      Link('$root/.venv/bin/python').deleteSync();
      write('.venv/bin/python', 'copied project executable');
      result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.interpreter, isNull);
      expect(process.calls, isEmpty);
    },
  );
  test(
    'Maven modules inherit matching local parent properties and retain independent targets',
    () async {
      write(
        'pom.xml',
        r'<project><groupId>demo</groupId><artifactId>root</artifactId><version>1</version><properties><jdk>17</jdk><maven.compiler.release>${jdk}</maven.compiler.release></properties><modules><module>api</module><module>worker</module></modules></project>',
      );
      write(
        'api/pom.xml',
        '<project><parent><groupId>demo</groupId><artifactId>root</artifactId><version>1</version></parent></project>',
      );
      write(
        'worker/pom.xml',
        '<project><properties><maven.compiler.release>21</maven.compiler.release></properties></project>',
      );
      final result = await service().inspect(root, local());
      expect(result.modules.map((m) => m.module.name), ['.', 'api', 'worker']);
      expect(result.modules.map((m) => m.module.requirements.single.value), [
        '17',
        '17',
        '21',
      ]);
      expect(
        result.modules.every((m) => m.state == ProjectToolState.satisfied),
        isTrue,
      );
      expect(
        result.checks.firstWhere((c) => c.tool == 'java').state,
        ProjectToolState.satisfied,
      );
    },
  );
  test(
    'Maven aggregation is not parent inheritance and missing modules remain visible',
    () async {
      write(
        'pom.xml',
        '<project><properties><java.version>21</java.version></properties><modules><module>api</module><module>missing</module></modules></project>',
      );
      write('api/pom.xml', '<project/>');
      final profile = await profiles.inspect(root);
      expect(
        profile.modules.firstWhere((m) => m.name == 'api').requirements,
        isEmpty,
      );
      expect(profile.modules.last.warnings, isNotEmpty);
    },
  );
  test(
    'Gradle Kotlin modules, projectDir override, root toolchain and wrapper are identified',
    () async {
      write(
        'settings.gradle.kts',
        'include(":app", ":feature:core")\nproject(":feature:core").projectDir = file("modules/core")',
      );
      write(
        'build.gradle.kts',
        'java { toolchain { languageVersion = JavaLanguageVersion.of(jdkVersion) } }\nsubprojects { java { toolchain { languageVersion = JavaLanguageVersion.of(jdkVersion) } } }',
      );
      write(
        'gradle.properties',
        'jdkVersion=17\nprivate.secret=do-not-surface',
      );
      write(
        'gradle/wrapper/gradle-wrapper.properties',
        r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.3-bin.zip',
      );
      write(
        'app/build.gradle.kts',
        'java { toolchain { languageVersion = JavaLanguageVersion.of(21) } }',
      );
      write('modules/core/build.gradle', '// inherits root declaration');
      write('gradlew', 'do not run');
      final result = await service().inspect(root, local());
      expect(result.modules.map((m) => m.module.name), [
        '.',
        'app',
        'modules/core',
      ]);
      expect(result.modules.first.module.wrapperVersion, '8.14.3');
      expect(result.modules.map((m) => m.module.requirements.single.value), [
        '17',
        '21',
        '17',
      ]);
      expect(result.modules.first.state, ProjectToolState.review);
      expect(result.modules[1].state, ProjectToolState.review);
      expect(
        result.checks.firstWhere((c) => c.tool == 'gradle').detail,
        contains('8.14.3'),
      );
      expect(process.calls, isEmpty);
    },
  );
  test(
    'child mise Java selection is queried separately for module comparison',
    () async {
      write(
        'pom.xml',
        '<project><modules><module>api</module></modules></project>',
      );
      write(
        'api/pom.xml',
        '<project><properties><java.version>21</java.version></properties></project>',
      );
      write('api/.java-version', '17');
      query.moduleRows['$root/api'] = [scopedTool('java', 'oracle-17.0.20')];
      final result = await service().inspect(root, local());
      expect(result.modules.last.javaVersion, 'oracle-17.0.20');
      expect(result.modules.last.state, ProjectToolState.mismatch);
    },
  );
  test(
    'dynamic, escaping and symlinked module metadata cannot yield a complete graph',
    () async {
      write(
        'settings.gradle',
        'include ":ok"\ninclude(findProperty("modules"))\nincludeBuild("other")\nproject(":ok").projectDir = file("../outside")',
      );
      var profile = await profiles.inspect(root);
      expect(profile.modules.single.warnings, isNotEmpty);
      expect(profile.warnings, isNotEmpty);
      write('settings.gradle', 'include ":ok"');
      final outside = Directory('${temp.path}/outside')..createSync();
      File(
        '${outside.path}/build.gradle',
      ).writeAsStringSync('JavaLanguageVersion.of(8)');
      Link('$root/ok').createSync(outside.path);
      profile = await profiles.inspect(root);
      expect(profile.warnings, contains(contains('无法安全读取')));
      expect(profile.modules.last.requirements, isEmpty);
      expect(profile.evidence, isNot(contains('ok/build.gradle')));
    },
  );
  test(
    'module count cap preserves partial results and reports truncation',
    () async {
      write(
        'settings.gradle',
        'include ${List.generate(45, (i) => '":m$i"').join(',')}',
      );
      for (var i = 0; i < 45; i++) {
        write('m$i/build.gradle', 'java { sourceCompatibility = 17 }');
      }
      final profile = await profiles.inspect(root);
      expect(
        profile.modules.length,
        lessThanOrEqualTo(ProjectJavaMetadata.maxModules),
      );
      expect(profile.warnings, contains(contains('上限')));
    },
  );
  test(
    'standalone pnpm resolves from configured PATH when mise does not own it',
    () async {
      write('package.json', '{"packageManager":"pnpm@12.11.2"}');
      final binary = installed('standalone/pnpm', '12.11.2');
      layout = ToolchainLayout(
        home: layout.home,
        environment: {'PATH': File(binary).parent.path},
      );
      final result = await service().inspect(root, local());
      expect(
        result.checks.firstWhere((c) => c.tool == 'pnpm').state,
        ProjectToolState.satisfied,
      );
      expect(process.calls.single.$1, binary);
    },
  );
  test(
    'project PATH shadowing is reported instead of falling back to a global binary',
    () async {
      write('package.json', '{"packageManager":"pnpm@12.11.2"}');
      write('bin/pnpm', 'project binary');
      final binary = installed('standalone/pnpm', '12.11.2');
      layout = ToolchainLayout(
        home: layout.home,
        environment: {'PATH': '$root/bin:${File(binary).parent.path}'},
      );
      final result = await service().inspect(root, local());
      expect(
        result.checks.firstWhere((c) => c.tool == 'pnpm').state,
        ProjectToolState.review,
      );
      expect(process.calls, isEmpty);
    },
  );
  test(
    'Corepack does not inherit unknown package manager sources from parent directories',
    () async {
      write('package.json', '{}');
      query.executables['npm'] = installed('corepack/npm', '11.19.0');
      final result = await service().inspect(root, local());
      expect(
        result.checks.firstWhere((c) => c.tool == 'npm').state,
        ProjectToolState.review,
      );
      expect(process.calls, isEmpty);
    },
  );
  test(
    'devEngines-only package manager declarations select the proper tool',
    () async {
      write(
        'package.json',
        '{"devEngines":{"packageManager":{"name":"pnpm","version":">=12.0.0"}}}',
      );
      query.executables['pnpm'] = installed('pnpm', '12.11.2');
      final result = await service().inspect(root, local());
      expect(
        result.checks.firstWhere((c) => c.tool == 'pnpm').state,
        ProjectToolState.satisfied,
      );
      expect(result.profile.toolIds, isNot(contains('npm')));
      expect(process.calls.single.$3['COREPACK_ENV_FILE'], '0');
    },
  );
  test(
    'requirements-only Python projects expose local candidate environments',
    () async {
      write('requirements.txt', 'fastapi>=0.100');
      await venv();
      final result = await service().inspect(root, local());
      expect(result.profile.stacks, contains('Python'));
      expect(result.pythonEnvironments.single.version, '3.14.8');
    },
  );
  test(
    'failed mise trust does not activate a declared Python environment',
    () async {
      write('pyproject.toml', '[project]\nname="app"');
      write('mise.toml', '[env._.python]\nvenv=".venv"');
      await venv();
      query.fail = true;
      final result = await service().inspect(root, local());
      expect(result.pythonEnvironments.single.selected, isFalse);
      expect(result.pythonEnvironments.single.issue, contains('查询失败'));
      expect(process.calls, isEmpty);
    },
  );
  test(
    'Gradle root Java plugin does not imply subproject inheritance',
    () async {
      write('settings.gradle', 'include ":api"');
      write(
        'build.gradle',
        'java { toolchain { languageVersion = JavaLanguageVersion.of(17) } }',
      );
      write('api/build.gradle', 'plugins { id "java" }');
      final profile = await profiles.inspect(root);
      expect(profile.modules.first.requirements.single.value, '17');
      expect(profile.modules.last.requirements, isEmpty);
      expect(profile.modules.last.warnings, isNotEmpty);
    },
  );
  test(
    'Maven compiler plugin inheritance excludes inactive profile declarations',
    () async {
      write(
        'pom.xml',
        '<project><groupId>demo</groupId><artifactId>root</artifactId><version>1</version><build><plugins><plugin><artifactId>maven-compiler-plugin</artifactId><configuration><release>17</release></configuration></plugin></plugins></build><modules><module>api</module></modules><profiles><profile><build><plugins><plugin><artifactId>maven-compiler-plugin</artifactId><configuration><release>99</release></configuration></plugin></plugins></build></profile></profiles></project>',
      );
      write(
        'api/pom.xml',
        '<project><parent><groupId>demo</groupId><artifactId>root</artifactId><version>1</version></parent></project>',
      );
      final profile = await profiles.inspect(root);
      expect(profile.modules.map((m) => m.requirements.single.value), [
        '17',
        '17',
      ]);
    },
  );
  test(
    'module ancestor version overrides are queried in module scope',
    () async {
      write(
        'settings.gradle',
        'include ":api"\nproject(":api").projectDir = file("modules/api")',
      );
      write('modules/.java-version', '17');
      write('modules/api/build.gradle', 'java { sourceCompatibility = 21 }');
      query.moduleRows['$root/modules/api'] = [
        scopedTool('java', 'oracle-17.0.20'),
      ];
      final result = await service().inspect(root, local());
      expect(result.modules.last.javaVersion, 'oracle-17.0.20');
      expect(result.modules.last.state, ProjectToolState.mismatch);
    },
  );
  test(
    'Gradle compiler toolchain is compared with both source and target, independently of mise JVM',
    () async {
      write('settings.gradle', 'include ":api"');
      write(
        'build.gradle',
        'subprojects { java { toolchain { languageVersion = JavaLanguageVersion.of(21) } } }',
      );
      write(
        'api/build.gradle',
        'java { sourceCompatibility = 17; targetCompatibility = 21 }',
      );
      query.rows['java'] = [scopedTool('java', 'oracle-17.0.20')];
      var result = await service().inspect(root, local());
      expect(result.modules.last.module.requirements, hasLength(3));
      expect(result.modules.last.state, ProjectToolState.review);
      write(
        'build.gradle',
        'subprojects { java { toolchain { languageVersion = JavaLanguageVersion.of(17) } } }',
      );
      result = await service().inspect(root, local());
      expect(result.modules.last.state, ProjectToolState.mismatch);
      expect(result.modules.last.detail, contains('编译工具链低于'));
    },
  );
  test(
    'Gradle repeated setters retain final literal declarations and options.release',
    () async {
      write(
        'build.gradle.kts',
        'java { sourceCompatibility = 17; sourceCompatibility = 21 }\noptions.release.set(21)',
      );
      final profile = await profiles.inspect(root);
      expect(profile.modules.single.requirements.map((r) => r.value), [
        '21',
        '21',
      ]);
    },
  );
}
