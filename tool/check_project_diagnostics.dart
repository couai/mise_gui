import 'dart:io';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_runtime_inspector.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Real, offline commands against disposable fixtures. No trust, dependency
/// installation, wrapper execution, user settings or task-history writes.
Future<void> main() async {
  const mise = LocalMiseProcessService(
    environmentOverrides: {
      'MISE_OFFLINE': '1',
      'MISE_AUTO_INSTALL': '0',
      'MISE_NOT_FOUND_AUTO_INSTALL': '0',
    },
  );
  const query = CliMiseQueryService(mise);
  const process = SystemLocalToolProcess();
  final shell = await mise.inspectShellEnvironment();
  final dir = await Directory.systemTemp.createTemp(
    'devworkbench-diagnostic-live-',
  );
  final root = await dir.resolveSymbolicLinks();
  var failures = 0;
  void check(String name, bool passed) {
    stdout.writeln('${passed ? 'PASS' : 'FAIL'} $name');
    if (!passed) failures++;
  }

  void write(String path, String content) {
    final file = File('$root/$path');
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  try {
    final layout = ToolchainLayout(
      home: Platform.environment['HOME']!,
      environment: {
        ...Platform.environment,
        ...?shell.environment,
        'VIRTUAL_ENV': '$root/web/.venv',
      },
    );
    final snapshot = LocalToolSnapshot(
      tools: const [],
      scannedAt: DateTime.now(),
    );
    final service = ProjectEnvironmentService(
      const ProjectProfileService(),
      query,
      runtimeInspector: ProjectRuntimeInspector(process, layout),
    );
    write(
      'web/package.json',
      '{"engines":{"npm":">=1.0.0"},"packageManager":"pnpm@12.11.2","scripts":{"postinstall":"touch NEVER_RUN"}}',
    );
    write(
      'web/pyproject.toml',
      '[project]\nname="diagnostic"\nrequires-python=">=3.14,<4"',
    );
    final installed = await query.fetchInstalledTools();
    final python = installed['python']!.firstWhere(
      (v) => v.active && v.installed,
    );
    final created = await process.run('${python.installPath}/bin/python3', [
      '-I',
      '-m',
      'venv',
      '--without-pip',
      '$root/web/.venv',
    ], workingDirectory: root);
    check('temporary venv created without dependencies', created.exitCode == 0);
    final web = await service.inspect('$root/web', snapshot);
    for (final id in ['npm', 'pnpm']) {
      final tool = web.checks.firstWhere((c) => c.tool == id);
      stdout.writeln(
        '$id: ${tool.effective ?? 'unverified'} · ${tool.state.label}',
      );
      if (tool.effective == null) stdout.writeln(tool.detail);
      check(
        'actual project $id resolved offline',
        tool.effective != null && tool.state == ProjectToolState.satisfied,
      );
    }
    check(
      'actual venv interpreter verified',
      web.pythonEnvironments.single.issue == null &&
          web.pythonEnvironments.single.selected &&
          web.pythonEnvironments.single.version == python.version,
    );
    check(
      'venv Python takes project precedence',
      web.checks
          .firstWhere((c) => c.tool == 'python')
          .source!
          .contains('VIRTUAL_ENV'),
    );
    check(
      'uv-compatible venv may omit pip',
      web.pythonEnvironments.single.pipVersion == null,
    );
    check(
      'no package script or node_modules created',
      !File('$root/web/NEVER_RUN').existsSync() &&
          !Directory('$root/web/node_modules').existsSync(),
    );
    write(
      'maven/pom.xml',
      r'<project><groupId>demo</groupId><artifactId>parent</artifactId><version>1</version><properties><jdk>17</jdk><maven.compiler.release>${jdk}</maven.compiler.release></properties><modules><module>api</module></modules></project>',
    );
    write(
      'maven/api/pom.xml',
      '<project><parent><groupId>demo</groupId><artifactId>parent</artifactId><version>1</version></parent></project>',
    );
    final maven = await service.inspect('$root/maven', snapshot);
    check(
      'actual Java covers inherited Maven modules',
      maven.modules.length == 2 &&
          maven.modules.every(
            (m) =>
                m.state == ProjectToolState.satisfied &&
                m.module.requirements.single.value == '17',
          ),
    );
    write(
      'gradle/settings.gradle.kts',
      'include(":app", ":lib")\nproject(":lib").projectDir = file("modules/lib")',
    );
    write(
      'gradle/build.gradle.kts',
      'subprojects { java { toolchain { languageVersion = JavaLanguageVersion.of(17) } } }',
    );
    write(
      'gradle/app/build.gradle.kts',
      'java { sourceCompatibility = JavaVersion.VERSION_21 }',
    );
    write('gradle/modules/lib/build.gradle', '// shared toolchain');
    write(
      'gradle/gradle/wrapper/gradle-wrapper.properties',
      r'distributionUrl=https\://services.gradle.org/distributions/gradle-8.14.3-bin.zip',
    );
    write('gradle/gradlew', '#!/bin/sh\ntouch NEVER_RUN');
    final gradle = await service.inspect('$root/gradle', snapshot);
    check(
      'Gradle module remap and wrapper version',
      gradle.modules.length == 3 &&
          gradle.modules.last.module.path.endsWith('/modules/lib') &&
          gradle.modules.last.module.wrapperVersion == '8.14.3',
    );
    check(
      'Gradle toolchain kept separate from build JVM',
      gradle.modules.last.module.requirements.single.value == '17' &&
          gradle.modules.last.state == ProjectToolState.review &&
          gradle.modules.last.javaVersion!.startsWith('oracle-21'),
    );
    check('wrapper not executed', !File('$root/gradle/NEVER_RUN').existsSync());
    stdout.writeln('$failures failures; temporary fixtures removed in finally');
  } finally {
    await dir.delete(recursive: true);
  }
  if (failures > 0) exitCode = 1;
}
