import 'dart:io';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_scan_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Extra acceptance checks outside the normal suite. Exit 1 means a reproduced
/// defect, not a failed local installation. All filesystem changes are isolated.
Future<void> main() async {
  var failures = 0;
  void check(String name, Object? expected, Object? actual) {
    final passed = expected == actual;
    if (!passed) failures++;
    stdout.writeln(
      '${passed ? 'PASS' : 'FAIL'} $name: expected=$expected, actual=$actual',
    );
  }

  for (final (tool, actual, minimum, expected) in [
    ('rust', '1.85.0', '1.90', false),
    ('rust', '1.99.0', '1.85', true),
    ('go', '1.27.2', '1.8', true),
    ('java', 'oracle-8.0.503', '1.8', true),
  ]) {
    check(
      '$tool $actual >= $minimum',
      expected,
      ProjectEnvironmentService.satisfies(
        actual,
        ProjectRequirement(
          tool,
          minimum,
          'audit',
          kind: ProjectRequirementKind.minimum,
        ),
      ),
    );
  }

  final query = _NoCommandQuery();
  final environment =
      ProjectEnvironmentService(const ProjectProfileService(), query).compare(
        const ProjectProfile(
          path: '/audit/project',
          name: 'audit',
          toolIds: ['uv'],
        ),
        LocalToolSnapshot(
          scannedAt: DateTime.now(),
          tools: const [
            LocalTool(
              id: 'uv',
              name: 'uv',
              category: LocalToolCategory.build,
              description: '',
              status: LocalToolStatus.unavailable,
              manager: 'fixture',
              source: 'fixture',
            ),
          ],
        ),
        {},
      );
  check(
    'failed probe is unverified, not proven missing',
    ProjectToolState.review,
    environment.checks.single.state,
  );

  final created = await Directory.systemTemp.createTemp('devworkbench-audit-');
  final temp = Directory(await created.resolveSymbolicLinks());
  final original = ToolchainLayout.current;
  try {
    final layout = ToolchainLayout(home: temp.path);
    ToolchainLayout.current = layout;
    final global = File(layout.globalConfigPath);
    await global.parent.create(recursive: true);
    await global.writeAsString('[tools]\nnode = "24.21.0"\n');
    final project = Directory('${temp.path}/project');
    await project.create();
    await File(
      '${project.path}/mise.toml',
    ).writeAsString('[tools]\nnode = "24.21.0" # project comment\n');
    final records = await LiveProjectScanService(
      queryService: query,
    ).fetchProjects([ScanDirectoryRecord(path: project.path)]);
    final binding = records.single.bindings.single;
    check(
      'TOML inline comment excluded from version',
      '24.21.0',
      binding.projectVersion,
    );
    check(
      'identical version does not override global',
      false,
      binding.overridesGlobal,
    );

    final root = Directory('${temp.path}/bounded');
    await root.create();
    for (var i = 0; i < 3; i++) {
      final child = Directory('${root.path}/project-$i');
      await child.create();
      await File('${child.path}/package.json').writeAsString('{}');
    }
    final limited = await LiveProjectScanService(
      queryService: query,
      maxProjectsPerRoot: 1,
    ).scan([ScanDirectoryRecord(path: root.path)]);
    check('bounded scan reports incomplete', false, limited.complete);
    check('bounded scan preserves one project', 1, limited.projects.length);
    check(
      'project limit reason is available',
      true,
      limited.roots.single.issues.any((reason) => reason.contains('项目上限')),
    );
  } finally {
    ToolchainLayout.current = original;
    await temp.delete(recursive: true);
  }
  stdout.writeln(
    '$failures failed assertions; no user configuration or SDK modified.',
  );
  exitCode = failures == 0 ? 0 : 1;
}

class _NoCommandQuery implements MiseQueryService {
  @override
  Future<Map<String, List<MiseInstalledToolVersionRef>>> fetchInstalledTools({
    String? workingDirectory,
  }) async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('No external command allowed in this audit.');
}
