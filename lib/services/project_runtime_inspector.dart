import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_java_metadata.dart';
import 'package:mise_gui/services/project_profile_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class ProjectRuntimeEvidence {
  const ProjectRuntimeEvidence(this.tools, this.pythonEnvironments);
  final Map<String, ProjectToolObservation> tools;
  final List<ProjectPythonEnvironment> pythonEnvironments;
}

/// Resolves fixed commands in project scope, then probes trusted installations.
/// Project binaries, activation scripts and Python sitecustomize are not run.
class ProjectRuntimeInspector {
  const ProjectRuntimeInspector(
    this.process,
    this.layout, {
    this.trustedRoots = const ['/opt/homebrew', '/usr/bin', '/bin'],
    this.timeout = const Duration(seconds: 5),
  });
  final LocalToolProcess process;
  final ToolchainLayout layout;
  final List<String> trustedRoots;
  final Duration timeout;

  Future<String?> _trusted(String candidate, String project) async {
    try {
      if (!File(candidate).isAbsolute || !await File(candidate).exists()) {
        return null;
      }
      final path = await File(candidate).resolveSymbolicLinks();
      if (path == project || path.startsWith('$project/')) return null;
      for (final root in [layout.root, ...trustedRoots]) {
        try {
          final actual = await Directory(root).resolveSymbolicLinks();
          if (path.startsWith('$actual/')) return path;
        } on FileSystemException {
          continue;
        }
      }
    } catch (_) {
      /* Unknown or broken executable remains unverified. */
    }
    return null;
  }

  Future<ProjectRuntimeEvidence> inspect(
    ProjectProfile profile,
    Map<String, List<MiseInstalledToolVersionRef>> scoped,
    MiseQueryService query, {
    bool queryAvailable = true,
  }) async {
    final tools = <String, ProjectToolObservation>{};
    final environments = <ProjectPythonEnvironment>[];
    final node = scoped['node']
        ?.where((v) => v.active && v.installed)
        .firstOrNull;
    String? nodeBin;
    if (node?.installPath != null) {
      final nodePath = await _trusted(
        '${node!.installPath}/bin/node',
        profile.path,
      );
      if (nodePath != null) nodeBin = File(nodePath).parent.path;
    }
    final offline = <String, String>{
      'PATH': [
        if (nodeBin != null) nodeBin,
        ...?layout.environment['PATH']
            ?.split(':')
            .where((p) => p.startsWith('/')),
        ...trustedRoots.map((p) => p.endsWith('/bin') ? p : '$p/bin'),
      ].join(':'),
      'NODE_OPTIONS': '',
      'NODE_PATH': '',
      'BUN_OPTIONS': '',
      'MISE_OFFLINE': '1',
      'MISE_AUTO_INSTALL': '0',
      'MISE_NOT_FOUND_AUTO_INSTALL': '0',
      'COREPACK_ENABLE_NETWORK': '0',
      'COREPACK_ENABLE_AUTO_PIN': '0',
      'COREPACK_ENABLE_DOWNLOAD_PROMPT': '0',
      'COREPACK_DEFAULT_TO_LATEST': '0',
      'COREPACK_ENV_FILE': '0',
      'COREPACK_ENABLE_UNSAFE_CUSTOM_URLS': '0',
      'COREPACK_ENABLE_PROJECT_SPEC': '1',
      'CI': '1',
      for (final name in ['COREPACK_HOME', 'PNPM_HOME', 'XDG_CACHE_HOME'])
        if (layout.environment[name] != null) name: layout.environment[name]!,
      'npm_config_update_notifier': 'false',
      'npm_config_audit': 'false',
      'npm_config_manage_package_manager_versions': 'false',
      'PNPM_MANAGE_PACKAGE_MANAGER_VERSIONS': 'false',
    };
    // Corepack accepts packageManager URLs; do not dispatch project-selected code.
    var safeManager = true;
    var ownManager = false;
    try {
      final metadata = await ProjectProfileService.readMetadata(
        profile.path,
        'package.json',
      );
      if (metadata != null) {
        final data = jsonDecode(metadata) as Map;
        final pm = data['packageManager'];
        final dev = data['devEngines'];
        final manager = dev is Map ? dev['packageManager'] : null;
        ownManager = pm != null || manager != null;
        safeManager =
            (pm == null ||
                pm is String &&
                    RegExp(
                      r'^(npm|pnpm|yarn)@\d+\.\d+\.\d+(?:[-+][\w.+-]+)?$',
                    ).hasMatch(pm)) &&
            (manager == null ||
                manager is Map &&
                    ['npm', 'pnpm', 'yarn'].contains(manager['name']) &&
                    (manager['version'] == null ||
                        manager['version'] is String &&
                            RegExp(
                              r'^[\d.^~<>= |+-]+$',
                            ).hasMatch(manager['version'])));
      }
    } catch (_) {
      safeManager = false;
    }
    for (final id in ['npm', 'pnpm']) {
      if (!profile.toolIds.contains(id)) continue;
      ProjectToolObservation failed(String message) =>
          ProjectToolObservation(source: '项目命令解析', issue: message);
      if (!queryAvailable || !safeManager) {
        tools[id] = failed(
          !safeManager
              ? '包管理器声明为动态值或自定义来源；未执行或下载。'
              : '项目 mise 环境不可用，未以全局版本代替项目版本。',
        );
        continue;
      }
      try {
        final resolved = await query.fetchExecutable(
          id,
          workingDirectory: profile.path,
        );
        String? path = resolved.isResolved ? resolved.resolvedPath : null;
        // `mise which` resolves mise-owned binaries only. Standalone pnpm can
        // instead be provided by the configured PATH; preserve its lookup order.
        if (path == null) {
          for (final directory in offline['PATH']!.split(':')) {
            final candidate = '$directory/$id';
            if (await File(candidate).exists()) {
              path = candidate;
              break;
            }
          }
        }
        final trusted = path == null
            ? null
            : await _trusted(path, profile.path);
        if (trusted != null && trusted.contains('/corepack/') && !ownManager) {
          tools[id] = failed('项目未声明包管理器，Corepack 可能读取父目录配置；未自动选择或下载。');
          continue;
        }
        if (trusted == null || nodeBin == null) {
          tools[id] = failed('未解析到可信安装目录中的 $id 或项目 Node.js；未执行项目内程序。');
          continue;
        }
        final result = await process.run(
          trusted,
          ['--version'],
          workingDirectory: profile.path,
          environment: offline,
          timeout: timeout,
        );
        final version = result.stdout.trim().split('\n').last.trim();
        tools[id] =
            result.exitCode == 0 &&
                RegExp(r'^\d+\.\d+\.\d+(?:-[\w.-]+)?$').hasMatch(version)
            ? ProjectToolObservation(
                version: version,
                path: trusted,
                source: '项目目录解析 · $trusted',
              )
            : failed('$id 离线版本检查未完成，可能缺少 Corepack 缓存或与项目配置冲突；未自动安装。');
      } catch (_) {
        tools[id] = failed('$id 项目版本检查失败或超时；未自动安装。');
      }
    }
    if (profile.toolIds.contains('python')) {
      String? selected = profile.pythonVenvPath;
      var selection = 'mise 项目虚拟环境声明';
      if (selected == null &&
          layout.environment['VIRTUAL_ENV']?.isNotEmpty == true) {
        final active = layout.environment['VIRTUAL_ENV']!;
        if (active.startsWith('${profile.path}/')) {
          selected = active;
          selection = '当前环境 VIRTUAL_ENV';
        }
      }
      final candidates = <String>{
        '.venv',
        'venv',
        if (selected != null) selected,
      };
      final visited = <String>{};
      for (final candidate in candidates) {
        final absolute = candidate.startsWith('/')
            ? candidate
            : '${profile.path}/$candidate';
        final path = ProjectJavaMetadata.inside(
          profile.path,
          profile.path,
          candidate.startsWith('/')
              ? candidate.startsWith('${profile.path}/')
                    ? candidate.substring(profile.path.length + 1)
                    : '../'
              : candidate,
        );
        final selectedPath = selected == null
            ? null
            : (selected.startsWith('/')
                  ? selected
                  : '${profile.path}/$selected');
        final chosen =
            Directory(absolute).absolute.uri.normalizePath() ==
            (selectedPath == null
                ? null
                : Directory(selectedPath).absolute.uri.normalizePath());
        if (candidate.startsWith('/') &&
                !candidate.startsWith('${profile.path}/') ||
            path == null) {
          if (chosen) {
            environments.add(
              ProjectPythonEnvironment(
                path: absolute,
                selected: true,
                selection: selection,
                issue: '虚拟环境位于项目外或路径无法确认；未读取或运行。',
              ),
            );
          }
          if (chosen) {
            tools['python'] = const ProjectToolObservation(
              source: '项目虚拟环境声明',
              issue: '项目虚拟环境路径位于项目外，未确认其可用性。',
            );
          }
          continue;
        }
        if (!visited.add(path)) continue;
        final exists =
            await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.notFound;
        if (!exists && !chosen) continue;
        String? version, interpreter, pip, issue;
        if (chosen && profile.pythonVenvPath != null && !queryAvailable) {
          environments.add(
            ProjectPythonEnvironment(
              path: path,
              selected: false,
              selection: 'mise 虚拟环境声明未确认',
              issue: '项目 mise 查询失败，未据此选择虚拟环境。',
            ),
          );
          continue;
        }
        try {
          final cfg = await ProjectProfileService.readMetadata(
            profile.path,
            '${path.substring(profile.path.length + 1)}/pyvenv.cfg',
          );
          if (cfg == null) throw const FormatException('missing cfg');
          final fields = <String, String>{
            for (final line in cfg.split('\n'))
              if (line.contains('='))
                line.split('=').first.trim(): line
                    .substring(line.indexOf('=') + 1)
                    .trim(),
          };
          version = fields['version'] ?? fields['version_info'];
          if (version != null) {
            version = RegExp(r'^\d+\.\d+\.\d+').firstMatch(version)?.group(0);
          }
          final entry = '$path/bin/python';
          interpreter = await _trusted(entry, profile.path);
          if (interpreter == null) {
            issue = '虚拟环境解释器缺失、链接失效或不属于可信工具安装；仅显示配置版本。';
          } else {
            // Run the trusted base interpreter directly. -I/-S prevents project
            // imports, activation and site hooks; the venv entry is never run.
            final result = await process.run(
              interpreter,
              [
                '-I',
                '-S',
                '-c',
                'import sys; print("%d.%d.%d" % sys.version_info[:3])',
              ],
              workingDirectory: layout.home,
              environment: {
                'PYTHONPATH': '',
                'PYTHONHOME': '',
                'PYTHONSTARTUP': '',
              },
              timeout: timeout,
            );
            final actual = result.stdout.trim();
            if (result.exitCode != 0 ||
                !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(actual)) {
              issue = '虚拟环境基础解释器无法验证。';
            } else {
              if (version != null && version != actual) {
                issue = 'pyvenv.cfg 与基础解释器版本不一致，环境可能已失效。';
              }
              version = actual;
            }
          }
          if (version != null) {
            final minor = version.split('.').take(2).join('.');
            final site = Directory('$path/lib/python$minor/site-packages');
            if (await site.exists()) {
              if (await site.resolveSymbolicLinks() != site.path) {
                throw const FormatException('linked site');
              }
              final entries = await site
                  .list(followLinks: false)
                  .take(513)
                  .toList();
              if (entries.length > 512) {
                issue ??= 'site-packages 扫描达到上限，pip 状态待核对。';
              }
              final metadata = entries
                  .whereType<Directory>()
                  .where(
                    (d) =>
                        RegExp(r'/pip-[\w.+-]+\.dist-info$').hasMatch(d.path),
                  )
                  .take(2)
                  .toList();
              if (metadata.length > 1) {
                issue ??= '虚拟环境存在多个 pip 安装记录。';
              }
              if (metadata.length == 1) {
                final info = await ProjectProfileService.readMetadata(
                  profile.path,
                  '${metadata.single.path.substring(profile.path.length + 1)}/METADATA',
                );
                pip = RegExp(
                  r'^Version:\s*([^\r\n]+)',
                  multiLine: true,
                ).firstMatch(info ?? '')?[1]?.trim();
              }
            }
          }
        } catch (_) {
          issue ??= '虚拟环境元数据缺失、超限或路径不安全，环境未确认。';
        }
        environments.add(
          ProjectPythonEnvironment(
            path: path,
            selected: chosen,
            selection: chosen ? selection : '项目候选环境 · 未确认终端已激活',
            version: version,
            interpreter: interpreter,
            pipVersion: pip,
            issue: issue,
          ),
        );
        if (chosen) {
          tools['python'] = ProjectToolObservation(
            version: issue == null ? version : null,
            path: interpreter,
            source: '$selection · $path',
            issue: issue,
          );
          if (pip != null) {
            tools['pip'] = ProjectToolObservation(
              version: issue == null ? pip : null,
              path: path,
              source: '项目虚拟环境 pip 安装元数据',
              issue: issue,
            );
          }
        }
      }
    }
    return ProjectRuntimeEvidence(tools, environments);
  }
}
