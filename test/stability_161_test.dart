import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/project_environment_service.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/project_scan_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/scan_directory_service.dart';
import 'package:mise_gui/repositories/projects_repository.dart';
import 'project_environment_test.dart' show ProjectQuery;

void main() {
  for (final (tool, actual, wanted, expected) in [
    ('rust', '1.85.0', '1.90', false),
    ('rust', '1.99.0', '1.85', true),
    ('go', '1.27.2', '1.8', true),
    ('go', 'go1.8.1', '1.8', true),
    ('python', '1.85.0', '1.90', false),
    ('java', 'oracle-8.0.503', '1.8', true),
    ('java', 'oracle-17.0.20', '1.8', true),
    ('node', 'v24.21.0', '24.0', true),
  ]) {
    test('$tool version numbers stay language scoped: $actual >= $wanted', () {
      expect(
        ProjectEnvironmentService.satisfies(
          actual,
          ProjectRequirement(
            tool,
            wanted,
            'fixture',
            kind: ProjectRequirementKind.minimum,
          ),
        ),
        expected,
      );
    });
  }

  for (final (status, expected) in [
    (LocalToolStatus.unavailable, ProjectToolState.review),
    (LocalToolStatus.attention, ProjectToolState.review),
    (LocalToolStatus.missing, ProjectToolState.missing),
    (LocalToolStatus.ready, ProjectToolState.review),
  ]) {
    test(
      'propagates $status without converting unknown evidence to missing',
      () {
        final result =
            ProjectEnvironmentService(
              const ProjectProfileService(),
              ProjectQuery(),
            ).compare(
              const ProjectProfile(
                path: '/fixture',
                name: 'fixture',
                toolIds: ['uv'],
              ),
              LocalToolSnapshot(
                scannedAt: DateTime.now(),
                tools: [
                  LocalTool(
                    id: 'uv',
                    name: 'uv',
                    category: LocalToolCategory.build,
                    description: '',
                    status: status,
                    manager: 'fixture',
                    source: 'fixture',
                  ),
                ],
              ),
              {},
            );
        expect(result.checks.single.state, expected);
      },
    );
  }

  late Directory temp;
  late ToolchainLayout original;
  setUp(() async {
    original = ToolchainLayout.current;
    final created = await Directory.systemTemp.createTemp('devworkbench-161-');
    temp = Directory(await created.resolveSymbolicLinks());
    ToolchainLayout.current = ToolchainLayout(home: temp.path);
    final global = File(ToolchainLayout.current.globalConfigPath);
    await global.parent.create(recursive: true);
    await global.writeAsString('[tools]\nnode = "24.21.0"\n');
  });
  tearDown(() async {
    ToolchainLayout.current = original;
    await temp.delete(recursive: true);
  });

  for (final content in [
    '[tools]\nnode = "24.21.0" # comment\n',
    "[tools]\nnode = '24.21.0'\n",
    '[tools]\nnode = { version = "24.21.0", other = "kept" }\n',
    '[tools.node]\nversion = "24.21.0" # comment\n',
  ]) {
    test('coverage and profile agree on TOML values: $content', () async {
      final project = Directory('${temp.path}/project');
      await project.create();
      await File('${project.path}/mise.toml').writeAsString(content);
      final rows = await LiveProjectScanService(
        queryService: ProjectQuery(),
      ).fetchProjects([ScanDirectoryRecord(path: project.path)]);
      expect(rows.single.bindings.single.projectVersion, '24.21.0');
      expect(rows.single.hasOverrideRisk, isFalse);
      final profile = await const ProjectProfileService().inspect(project.path);
      expect(
        profile.requirements.single.value,
        rows.single.bindings.single.projectVersion,
      );
    });
  }

  Future<Directory> fixture(String name, {String? metadata}) async {
    final dir = Directory('${temp.path}/$name');
    await dir.create(recursive: true);
    await File('${dir.path}/package.json').writeAsString(metadata ?? '{}');
    return dir;
  }

  test(
    'project cap reports partial discovery through repository snapshot',
    () async {
      for (var i = 0; i < 3; i++) {
        await fixture('bounded/project-$i');
      }
      final roots = [ScanDirectoryRecord(path: '${temp.path}/bounded')];
      final service = LiveProjectScanService(
        queryService: ProjectQuery(),
        maxProjectsPerRoot: 1,
      );
      final snapshot = await ProjectsRepository(
        service,
        _ScanDirectories(roots),
      ).loadCoverageSnapshot();
      expect(snapshot.projects, hasLength(1));
      expect(snapshot.scanComplete, isFalse);
      expect(snapshot.scanRoots.single.issues.join(), contains('项目上限 1'));
    },
  );

  test('directory cap and depth boundary retain explicit reasons', () async {
    for (var i = 0; i < 3; i++) {
      await fixture('bounded/project-$i');
    }
    final roots = [ScanDirectoryRecord(path: '${temp.path}/bounded')];
    final limited = await LiveProjectScanService(
      queryService: ProjectQuery(),
      maxDirectoriesPerRoot: 2,
    ).scan(roots);
    expect(limited.complete, isFalse);
    expect(limited.roots.single.visitedDirectories, 2);
    expect(limited.roots.single.issues.join(), contains('目录上限 2'));
    final shallow = await LiveProjectScanService(
      queryService: ProjectQuery(),
      maxDepth: 0,
    ).scan(roots);
    expect(shallow.complete, isFalse);
    expect(shallow.projects, isEmpty);
    expect(shallow.roots.single.issues.join(), contains('最大深度 0'));
  });

  test(
    'exact project cap at a leaf and ignored dependency directories are complete',
    () async {
      final project = await fixture('project');
      await fixture('project/node_modules/vendor');
      await fixture('project/target/generated');
      final result = await LiveProjectScanService(
        queryService: ProjectQuery(),
        maxProjectsPerRoot: 1,
        maxDepth: 0,
      ).scan([ScanDirectoryRecord(path: project.path)]);
      expect(result.projects, hasLength(1));
      expect(result.complete, isTrue);
    },
  );

  test(
    'missing root retains good roots and reports a read failure instead of empty success',
    () async {
      final project = await fixture('good');
      final result = await LiveProjectScanService(queryService: ProjectQuery())
          .scan([
            ScanDirectoryRecord(path: project.path),
            ScanDirectoryRecord(path: '${temp.path}/missing'),
          ]);
      expect(result.projects.map((p) => p.name), ['good']);
      expect(result.complete, isFalse);
      expect(
        result.roots.firstWhere((r) => r.path.endsWith('/missing')).label,
        '读取失败',
      );
      expect(
        result.roots.firstWhere((r) => r.path.endsWith('/good')).complete,
        isTrue,
      );
    },
  );

  test(
    'directory stream failure does not hide valid sibling projects',
    () async {
      final good = await fixture('good'),
          denied = Directory('${temp.path}/denied');
      await denied.create();
      final result = await LiveProjectScanService(
        queryService: ProjectQuery(),
        listDirectory: (dir) => dir.path == denied.path
            ? Stream<FileSystemEntity>.error(
                FileSystemException('permission denied', dir.path),
              )
            : dir.list(followLinks: false),
      ).scan([ScanDirectoryRecord(path: temp.path)]);
      expect(result.projects.map((p) => p.name), contains('good'));
      expect(result.complete, isFalse);
      expect(
        result.roots.single.issues.join(),
        contains('目录读取失败：${denied.path}'),
      );
      expect(good.existsSync(), isTrue);
    },
  );

  test(
    'malformed TOML is kept as a project warning instead of dropping the project',
    () async {
      final dir = Directory('${temp.path}/broken');
      await dir.create();
      await File(
        '${dir.path}/mise.toml',
      ).writeAsString('[tools\nnode = "24.21.0"');
      final result = await LiveProjectScanService(
        queryService: ProjectQuery(),
      ).scan([ScanDirectoryRecord(path: dir.path)]);
      expect(result.projects, hasLength(1));
      expect(result.projects.single.level, HealthLevel.warning);
      expect(result.projects.single.notes, contains('解析失败'));
    },
  );

  test(
    'invalid global TOML marks comparison incomplete without hiding projects',
    () async {
      await File(
        ToolchainLayout.current.globalConfigPath,
      ).writeAsString('[tools\nnode = "24.21.0"');
      final dir = await fixture('project');
      final result = await LiveProjectScanService(
        queryService: ProjectQuery(),
      ).scan([ScanDirectoryRecord(path: dir.path)]);
      expect(result.projects, hasLength(1));
      expect(result.complete, isFalse);
      expect(result.warnings.single, contains('全局 mise 配置'));
    },
  );

  test(
    'classified global source and overlapping scan root ownership are preserved',
    () async {
      final dir = await fixture('project');
      await File('${dir.path}/.python-version').writeAsString('3.14.8');
      final query = ProjectQuery()
        ..rows = {
          'node': [
            MiseInstalledToolVersionRef(
              tool: 'node',
              version: '24.21.0',
              installed: true,
              active: true,
              source: MiseSourceRef(
                type: 'mise.toml',
                path: ToolchainLayout.current.globalConfigPath,
              ),
            ),
          ],
        };
      final result = await LiveProjectScanService(queryService: query).scan([
        ScanDirectoryRecord(path: temp.path),
        ScanDirectoryRecord(path: dir.path),
      ]);
      expect(result.roots, hasLength(1));
      expect(
        result.projects.single.bindings
            .firstWhere((b) => b.name == 'node')
            .source,
        '全局',
      );
      final snapshot = ProjectCoverageSnapshot(
        scanDirectories: [],
        projects: result.projects,
        scanRoots: result.roots,
      );
      expect(snapshot.scanReportFor(dir.path), same(result.roots.single));
    },
  );

  test(
    'disabled and genuinely empty roots have complete empty results',
    () async {
      final empty = Directory('${temp.path}/empty');
      await empty.create();
      final result = await LiveProjectScanService(queryService: ProjectQuery())
          .scan([
            ScanDirectoryRecord(path: empty.path),
            ScanDirectoryRecord(path: '${temp.path}/missing', enabled: false),
          ]);
      expect(result.complete, isTrue);
      expect(result.projects, isEmpty);
      expect(result.roots, hasLength(1));
    },
  );
}

class _ScanDirectories implements ScanDirectoryService {
  _ScanDirectories(this.roots);
  final List<ScanDirectoryRecord> roots;
  @override
  Future<List<ScanDirectoryRecord>> fetchDirectories() async => roots;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('read-only fixture');
}
