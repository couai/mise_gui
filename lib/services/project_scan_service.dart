import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:mise_gui/services/toolchain_layout.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:toml/toml.dart';

import 'package:mise_gui/models/app_models.dart';
import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/mise_query_service.dart';

abstract class ProjectScanService {
  const ProjectScanService();
  Future<List<ProjectRecord>> fetchProjects(
    List<ScanDirectoryRecord> directories,
  );
  Future<ProjectScanResult> scan(List<ScanDirectoryRecord> directories) async =>
      ProjectScanResult(projects: await fetchProjects(directories));
}

class _DiscoveredProjectConfig {
  const _DiscoveredProjectConfig({
    required this.directoryPath,
    required this.primaryPath,
    required this.paths,
  });

  final String directoryPath;
  final String primaryPath;
  final List<String> paths;
}

class LiveProjectScanService extends ProjectScanService {
  const LiveProjectScanService({
    required MiseQueryService queryService,
    this.maxDepth = 3,
    this.maxDirectoriesPerRoot = 240,
    this.maxProjectsPerRoot = 80,
    this.listDirectory,
  }) : _queryService = queryService;

  final MiseQueryService _queryService;
  final int maxDepth;
  final int maxDirectoriesPerRoot;
  final int maxProjectsPerRoot;
  final Stream<FileSystemEntity> Function(Directory)? listDirectory;

  static const List<String> _workspaceConfigNames = <String>[
    'mise.toml',
    '.mise.toml',
    '.mise.local.toml',
    'mise.local.toml',
  ];

  static const String _toolVersionsFileName = '.tool-versions';

  static const Map<String, String> _singleToolVersionFiles = <String, String>{
    '.node-version': 'node',
    '.nvmrc': 'node',
    '.python-version': 'python',
    '.ruby-version': 'ruby',
    '.java-version': 'java',
    '.go-version': 'go',
    'rust-toolchain.toml': 'rust',
    'rust-toolchain': 'rust',
    '.terraform-version': 'terraform',
  };

  static const Set<String> _ignoredDirectories = <String>{
    '.git',
    '.dart_tool',
    '.idea',
    '.vscode',
    'build',
    'dist',
    'node_modules',
    'target',
    'venv',
    '.venv',
  };

  @override
  Future<List<ProjectRecord>> fetchProjects(
    List<ScanDirectoryRecord> directories,
  ) async => (await scan(directories)).projects;

  @override
  Future<ProjectScanResult> scan(List<ScanDirectoryRecord> directories) async {
    final roots = _collapseOverlappingRoots(
      directories.where((d) => d.enabled).toList(),
    );
    if (roots.isEmpty) return const ProjectScanResult(projects: []);
    final warnings = <String>[];
    var globalAssignments = <String, String>{};
    try {
      globalAssignments = _parseToolAssignments(
        await _readFileIfExists(_globalConfigPath()) ?? '',
      );
    } catch (_) {
      warnings.add('全局 mise 配置无法读取或解析，版本覆盖结果尚未完整核对。');
    }
    final reports = <ProjectScanRootReport>[];
    final projects = <String, ProjectRecord>{};
    for (final root in roots) {
      final discovered = await _discoverWorkspaceConfigs(root.path);
      final issues = [...discovered.report.issues];
      var count = 0;
      for (final config in discovered.configs) {
        try {
          final project = await _buildProjectRecord(
            config: config,
            scanRootPath: root.path,
            globalAssignments: globalAssignments,
          );
          if (project != null) {
            projects[project.path] = project;
            count++;
          } else {
            issues.add('无法读取项目：${config.directoryPath}');
          }
        } catch (_) {
          issues.add('无法读取项目：${config.directoryPath}');
        }
      }
      reports.add(
        ProjectScanRootReport(
          path: root.path,
          visitedDirectories: discovered.report.visitedDirectories,
          projectCount: count,
          issues: List.unmodifiable(issues),
        ),
      );
    }
    final ordered = projects.values.toList()
      ..sort((a, b) {
        final byOverride = b.overrideCount.compareTo(a.overrideCount);
        return byOverride != 0
            ? byOverride
            : a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
    return ProjectScanResult(
      projects: List.unmodifiable(ordered),
      roots: List.unmodifiable(reports),
      warnings: warnings,
    );
  }

  Future<
    ({List<_DiscoveredProjectConfig> configs, ProjectScanRootReport report})
  >
  _discoverWorkspaceConfigs(String rootPath) async {
    final issues = <String>{};
    final discovered = <_DiscoveredProjectConfig>[];
    final visited = <String>{};
    final queue = Queue<({Directory directory, int depth})>();
    try {
      final root = Directory(rootPath);
      if (!await root.exists()) {
        issues.add('目录不存在或不可访问：$rootPath');
      } else {
        queue.add((directory: root, depth: 0));
      }
    } catch (_) {
      issues.add('目录无法访问：$rootPath');
    }
    while (queue.isNotEmpty && visited.length < maxDirectoriesPerRoot) {
      final item = queue.removeFirst();
      if (!visited.add(item.directory.path)) continue;
      try {
        final config = await _discoverProjectConfig(item.directory.path);
        if (config != null) discovered.add(config);
      } catch (_) {
        issues.add('项目文件无法检查：${item.directory.path}');
      }
      final children = <Directory>[];
      try {
        final stream =
            listDirectory?.call(item.directory) ??
            item.directory.list(followLinks: false);
        await for (final entity in stream) {
          if (entity is! Directory) continue;
          final name = _basename(entity.path);
          if (name.startsWith('.') || _ignoredDirectories.contains(name)) {
            continue;
          }
          children.add(entity);
          // Bound wide-directory enumeration as well as traversal. A sentinel
          // child is enough to prove the requested scan cannot be exhaustive.
          if (children.length > maxDirectoriesPerRoot) {
            issues.add('达到目录上限 $maxDirectoriesPerRoot，部分路径未扫描。');
            break;
          }
        }
      } catch (_) {
        issues.add('目录读取失败：${item.directory.path}');
      }
      children.sort(
        (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
      );
      if (item.depth >= maxDepth) {
        if (children.isNotEmpty) issues.add('达到最大深度 $maxDepth，部分子目录未扫描。');
      } else {
        for (final child in children) {
          queue.add((directory: child, depth: item.depth + 1));
        }
      }
      if (discovered.length >= maxProjectsPerRoot && queue.isNotEmpty) {
        issues.add('达到项目上限 $maxProjectsPerRoot，部分路径未扫描。');
        break;
      }
    }
    if (queue.isNotEmpty && visited.length >= maxDirectoriesPerRoot) {
      issues.add('达到目录上限 $maxDirectoriesPerRoot，部分路径未扫描。');
    }
    return (
      configs: discovered,
      report: ProjectScanRootReport(
        path: rootPath,
        visitedDirectories: visited.length,
        projectCount: discovered.length,
        issues: issues.toList(),
      ),
    );
  }

  List<ScanDirectoryRecord> _collapseOverlappingRoots(
    List<ScanDirectoryRecord> directories,
  ) {
    final sorted = directories.toList()
      ..sort((a, b) {
        final depthCompare = _pathDepth(a.path).compareTo(_pathDepth(b.path));
        if (depthCompare != 0) {
          return depthCompare;
        }
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });

    final kept = <ScanDirectoryRecord>[];
    for (final directory in sorted) {
      final covered = kept.any(
        (existing) => _containsPath(existing.path, directory.path),
      );
      if (!covered) {
        kept.add(directory);
      }
    }
    return kept;
  }

  Future<_DiscoveredProjectConfig?> _discoverProjectConfig(
    String directoryPath,
  ) async {
    final paths = <String>[];

    for (final fileName in _workspaceConfigNames) {
      final candidate = File(
        '$directoryPath${Platform.pathSeparator}$fileName',
      );
      if (await candidate.exists()) {
        paths.add(candidate.path);
      }
    }

    final toolVersions = File(
      '$directoryPath${Platform.pathSeparator}$_toolVersionsFileName',
    );
    if (await toolVersions.exists()) {
      paths.add(toolVersions.path);
    }

    for (final fileName in _singleToolVersionFiles.keys) {
      final candidate = File(
        '$directoryPath${Platform.pathSeparator}$fileName',
      );
      if (await candidate.exists()) {
        paths.add(candidate.path);
      }
    }

    for (final name in ProjectProfileService.manifestNames) {
      final candidate = File('$directoryPath/$name');
      if (await candidate.exists()) paths.add(candidate.path);
    }
    if (paths.isEmpty) {
      return null;
    }

    return _DiscoveredProjectConfig(
      directoryPath: directoryPath,
      primaryPath: paths.first,
      paths: List.unmodifiable(paths),
    );
  }

  Future<ProjectRecord?> _buildProjectRecord({
    required _DiscoveredProjectConfig config,
    required String scanRootPath,
    required Map<String, String> globalAssignments,
  }) async {
    final workspacePath = config.directoryPath;
    final projectContents = <String, String>{};
    for (final path in config.paths) {
      String? content;
      try {
        content = await _readFileIfExists(path);
      } catch (_) {
        /* Profile reports unreadable metadata. */
      }
      if (content != null) {
        projectContents[path] = content;
      }
    }
    final profile = await const ProjectProfileService().inspect(workspacePath);

    final projectAssignments = _parseProjectAssignments(projectContents);
    final projectSources = _parseProjectAssignmentSources(projectContents);
    final commandPreview = [
      'mise current',
      'mise ls --json',
      for (final path in config.paths) 'cat $path',
    ].join('\n');

    var installedTools = <String, List<MiseInstalledToolVersionRef>>{};
    String? scanIssue;
    try {
      if (config.paths.any(
        (p) => !ProjectProfileService.manifestNames.contains(_basename(p)),
      )) {
        installedTools = await _queryService.fetchInstalledTools(
          workingDirectory: workspacePath,
        );
      }
    } on MiseProcessException catch (error) {
      scanIssue = _describeScanIssue(error);
    } catch (_) {
      scanIssue = '暂时无法解析 mise 的生效版本，已按项目文件里的声明继续展示。';
    }

    final activeVersions = <String, MiseInstalledToolVersionRef>{};
    for (final entry in installedTools.entries) {
      for (final version in entry.value) {
        if (version.active) {
          activeVersions[entry.key] = version;
          break;
        }
      }
    }

    final bindings = <ProjectToolBinding>[];
    final toolNames = <String>{
      ...projectAssignments.keys,
      ...activeVersions.keys,
    }.toList()..sort();

    for (final toolName in toolNames) {
      final active = activeVersions[toolName];
      final declaredInProject = projectAssignments.containsKey(toolName);
      final declaredInGlobal = globalAssignments.containsKey(toolName);
      final projectVersion =
          projectAssignments[toolName] ??
          active?.requestedVersion ??
          active?.version ??
          '未设置';
      final globalVersion = globalAssignments[toolName] ?? '未设置';
      final source = declaredInProject
          ? _formatProjectSource(projectSources[toolName])
          : _formatSource(active?.source?.path, config.primaryPath);

      bindings.add(
        ProjectToolBinding(
          name: toolName,
          projectVersion: projectVersion,
          globalVersion: globalVersion,
          source: source,
          declaredInProject: declaredInProject,
          declaredInGlobal: declaredInGlobal,
        ),
      );
    }

    bindings.sort((a, b) => a.name.compareTo(b.name));

    final environment = profile.stacks.isEmpty
        ? _resolveEnvironment(projectAssignments.keys)
        : profile.stacks.join(' · ');
    final declaredTools = bindings
        .where((binding) => binding.declaredInProject)
        .length;
    final overrides = bindings
        .where((binding) => binding.overridesGlobal)
        .length;
    final projectOnlyTools = bindings
        .where(
          (binding) => binding.declaredInProject && !binding.declaredInGlobal,
        )
        .length;

    return ProjectRecord(
      name: _basename(workspacePath),
      path: workspacePath,
      scanRootPath: scanRootPath,
      configPath: config.primaryPath,
      configPaths: config.paths,
      environment: environment,
      lastScan: await _formatLastScan(config.paths),
      commandPreview: commandPreview,
      bindings: bindings,
      level: scanIssue != null || overrides > 0 || profile.warnings.isNotEmpty
          ? HealthLevel.warning
          : HealthLevel.healthy,
      notes:
          '${_buildNotes(declaredTools: declaredTools, overrides: overrides, projectOnlyTools: projectOnlyTools, scanIssue: scanIssue)} ${profile.warnings.join(' ')}'
              .trim(),
    );
  }

  String _buildNotes({
    required int declaredTools,
    required int overrides,
    required int projectOnlyTools,
    String? scanIssue,
  }) {
    final base = switch ((overrides, projectOnlyTools, declaredTools)) {
      (> 0, _, _) => '当前项目有 $overrides 个工具版本不同于全局配置。',
      (0, > 0, _) => '当前项目有 $projectOnlyTools 个工具只在项目中声明。',
      (0, 0, 0) => '当前项目没有项目级工具声明。',
      _ => '当前项目有 $declaredTools 个工具声明，与全局默认值保持一致。',
    };

    if (scanIssue == null || scanIssue.isEmpty) {
      return base;
    }
    return '$base $scanIssue';
  }

  String _describeScanIssue(MiseProcessException error) {
    final stderr = error.result.stderr.toLowerCase();
    if (stderr.contains('not trusted')) {
      return '这个项目的配置文件还没有被 mise trust，当前按文件声明展示版本。';
    }
    return '暂时无法解析 mise 的生效版本，已按项目文件里的声明继续展示。';
  }

  String _globalConfigPath() {
    return ToolchainLayout.current.globalConfigPath;
  }

  Future<String?> _readFileIfExists(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return null;
    }
    final root = await file.parent.resolveSymbolicLinks();
    return ProjectProfileService.readMetadata(root, _basename(path));
  }

  Future<String> _formatLastScan(List<String> paths) async {
    try {
      final modifiedTimes = <DateTime>[];
      for (final path in paths) {
        modifiedTimes.add(await File(path).lastModified());
      }
      modifiedTimes.sort((a, b) => b.compareTo(a));
      final modifiedAt = modifiedTimes.first;
      final elapsed = DateTime.now().difference(modifiedAt);
      if (elapsed.inMinutes < 1) {
        return '刚刚';
      }
      if (elapsed.inHours < 1) {
        return '${elapsed.inMinutes} 分钟前';
      }
      return '${elapsed.inHours} 小时前';
    } catch (_) {
      return '最近';
    }
  }

  Map<String, String> _parseToolAssignments(String content) {
    if (content.trim().isEmpty) return {};
    final values = ProjectProfileService.miseVersions(content);
    return {
      for (final entry in values.entries)
        if (entry.value is String) entry.key: (entry.value as String).trim(),
    };
  }

  Map<String, String> _parseProjectAssignments(Map<String, String> contents) {
    final assignments = <String, String>{};
    for (final entry in contents.entries) {
      Map<String, String> parsed;
      try {
        parsed = _parseAssignmentsForPath(entry.key, entry.value);
      } catch (_) {
        continue;
      }
      for (final item in parsed.entries) {
        assignments.putIfAbsent(item.key, () => item.value);
      }
    }
    return assignments;
  }

  Map<String, String> _parseProjectAssignmentSources(
    Map<String, String> contents,
  ) {
    final sources = <String, String>{};
    for (final entry in contents.entries) {
      Map<String, String> parsed;
      try {
        parsed = _parseAssignmentsForPath(entry.key, entry.value);
      } catch (_) {
        continue;
      }
      for (final item in parsed.entries) {
        sources.putIfAbsent(item.key, () => entry.key);
      }
    }
    return sources;
  }

  Map<String, String> _parseAssignmentsForPath(String path, String content) {
    final fileName = _basename(path);
    if (_workspaceConfigNames.contains(fileName)) {
      return _parseToolAssignments(content);
    }
    if (fileName == _toolVersionsFileName) {
      return _parseToolVersions(content);
    }
    if (fileName == 'rust-toolchain.toml') {
      final table = TomlDocument.parse(content).toMap()['toolchain'];
      final channel = table is Map ? table['channel'] : null;
      return channel is String ? {'rust': channel.trim()} : {};
    }
    final tool = _singleToolVersionFiles[fileName];
    if (tool != null) {
      final version = _parseSingleVersionFile(content, tool: tool);
      if (version == null) {
        return const <String, String>{};
      }
      return <String, String>{tool: version};
    }
    return const <String, String>{};
  }

  Map<String, String> _parseToolVersions(String content) {
    final result = <String, String>{};
    for (final line in content.split('\n')) {
      final trimmed = _stripInlineComment(line).trim();
      if (trimmed.isEmpty) {
        continue;
      }

      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 2) {
        continue;
      }

      final tool = _normalizeToolName(parts.first);
      final version = _normalizeVersionForTool(tool, parts[1]);
      if (tool.isEmpty || version.isEmpty) {
        continue;
      }
      result.putIfAbsent(tool, () => version);
    }
    return result;
  }

  String? _parseSingleVersionFile(String content, {required String tool}) {
    for (final line in content.split('\n')) {
      final version = _stripInlineComment(line).trim();
      if (version.isEmpty) {
        continue;
      }
      return _normalizeVersionForTool(tool, version);
    }
    return null;
  }

  String _stripInlineComment(String line) {
    final index = line.indexOf('#');
    if (index == -1) {
      return line;
    }
    return line.substring(0, index);
  }

  String _formatSource(String? sourcePath, String workspaceConfigPath) {
    if (sourcePath == null || sourcePath.isEmpty) {
      return '继承';
    }
    if (sourcePath == workspaceConfigPath) {
      return '项目';
    }
    if (sourcePath == _globalConfigPath() ||
        sourcePath.contains('/.config/mise/')) {
      return '全局';
    }
    return '解析结果';
  }

  String _formatProjectSource(String? sourcePath) {
    if (sourcePath == null || sourcePath.isEmpty) {
      return '项目';
    }
    final fileName = _basename(sourcePath);
    if (fileName == 'mise.toml') {
      return '项目';
    }
    return '项目 $fileName';
  }

  String _normalizeToolName(String tool) {
    return switch (tool.trim().toLowerCase()) {
      'nodejs' => 'node',
      'golang' => 'go',
      _ => tool.trim().toLowerCase(),
    };
  }

  String _normalizeVersionForTool(String tool, String version) {
    final trimmed = version.trim();
    if (tool == 'node' && RegExp(r'^v\d').hasMatch(trimmed)) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  String _resolveEnvironment(Iterable<String> tools) {
    final toolSet = tools.toSet();
    if (toolSet.contains('flutter')) {
      return 'Flutter 桌面环境';
    }
    if (toolSet.contains('node')) {
      return 'Node 工作区';
    }
    if (toolSet.contains('python') && toolSet.contains('go')) {
      return 'Python 与 Go';
    }
    if (toolSet.contains('python')) {
      return 'Python';
    }
    if (toolSet.contains('java')) {
      return 'Java';
    }
    return 'mise 工作区';
  }

  String _basename(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  bool _containsPath(String parent, String child) {
    final normalizedParent = _normalizeComparablePath(parent);
    final normalizedChild = _normalizeComparablePath(child);
    return normalizedChild == normalizedParent ||
        normalizedChild.startsWith('$normalizedParent/');
  }

  String _normalizeComparablePath(String path) {
    var normalized = path.replaceAll('\\', '/');
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    return normalized;
  }

  int _pathDepth(String path) {
    return _normalizeComparablePath(
      path,
    ).split('/').where((segment) => segment.isNotEmpty).length;
  }
}

class MockProjectScanService extends ProjectScanService {
  const MockProjectScanService();

  @override
  Future<List<ProjectRecord>> fetchProjects(
    List<ScanDirectoryRecord> directories,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));

    return const [
      ProjectRecord(
        name: 'frontend-app',
        path: '~/Workspaces/frontend-app',
        scanRootPath: '~/Workspaces',
        configPath: '~/Workspaces/frontend-app/mise.toml',
        environment: 'Node 工作区',
        lastScan: '2 分钟前',
        commandPreview: 'mise current\nmise ls --json',
        level: HealthLevel.warning,
        notes: '当前项目有 1 个工具版本不同于全局配置。',
        bindings: [
          ProjectToolBinding(
            name: 'node',
            projectVersion: '20.16.0',
            globalVersion: '22.4.1',
            source: '项目',
            declaredInProject: true,
            declaredInGlobal: true,
          ),
        ],
      ),
      ProjectRecord(
        name: 'mise_gui',
        path: '~/Documents/FlutterProject/mise_gui',
        scanRootPath: '~/Documents/FlutterProject',
        configPath: '~/Documents/FlutterProject/mise_gui/mise.toml',
        environment: 'Flutter 桌面环境',
        lastScan: '4 小时前',
        commandPreview: 'mise current\nmise ls --json',
        level: HealthLevel.healthy,
        notes: '当前项目有 1 个工具声明，与全局默认值保持一致。',
        bindings: [
          ProjectToolBinding(
            name: 'flutter',
            projectVersion: '3.41.4',
            globalVersion: '3.41.4',
            source: '项目',
            declaredInProject: true,
            declaredInGlobal: true,
          ),
        ],
      ),
      ProjectRecord(
        name: 'api-gateway',
        path: '~/Workspaces/api-gateway',
        scanRootPath: '~/Workspaces',
        configPath: '~/Workspaces/api-gateway/mise.toml',
        environment: 'Python',
        lastScan: '1 小时前',
        commandPreview: 'mise current\nmise ls --json',
        level: HealthLevel.warning,
        notes: '当前项目有 1 个工具版本不同于全局配置。',
        bindings: [
          ProjectToolBinding(
            name: 'python',
            projectVersion: '3.11',
            globalVersion: '3',
            source: '项目',
            declaredInProject: true,
            declaredInGlobal: true,
          ),
        ],
      ),
    ];
  }
}
