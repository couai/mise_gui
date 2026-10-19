import 'dart:io';
import 'package:pub_semver/pub_semver.dart';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/project_environment.dart';
import 'package:mise_gui/services/mise_query_service.dart';
import 'package:mise_gui/services/project_profile_service.dart';

class ProjectEnvironmentService {
  const ProjectEnvironmentService(this.profiles, this.query);
  final ProjectProfileService profiles;
  final MiseQueryService query;

  Future<ProjectEnvironment> inspect(
    String path,
    LocalToolSnapshot local,
  ) async {
    final profile = await profiles.inspect(path);
    Map<String, List<MiseInstalledToolVersionRef>> scoped = {};
    String? issue;
    try {
      scoped = await query.fetchInstalledTools(workingDirectory: profile.path);
    } catch (_) {
      issue = 'mise 未能解析项目环境（可能未信任、不可用或配置有误）。保留静态声明；未自动 trust 或安装。';
    }
    String? dart;
    final flutter = scoped['flutter']
        ?.where((v) => v.active && v.installed)
        .firstOrNull;
    if (flutter?.installPath != null) {
      try {
        final root = await Directory(
          flutter!.installPath!,
        ).resolveSymbolicLinks();
        dart = (await ProjectProfileService.readMetadata(
          root,
          'bin/cache/dart-sdk/version',
        ))?.trim();
      } catch (_) {
        /* A missing Dart version stays unverified. */
      }
    }
    return compare(
      profile,
      local,
      scoped,
      dartVersion: dart,
      queryIssue: issue,
    );
  }

  ProjectEnvironment compare(
    ProjectProfile profile,
    LocalToolSnapshot local,
    Map<String, List<MiseInstalledToolVersionRef>> scoped, {
    String? dartVersion,
    String? queryIssue,
  }) {
    final checks = <ProjectToolCheck>[];
    const runtimes = {
      'java',
      'node',
      'python',
      'go',
      'rust',
      'flutter',
      'dart',
    };
    const catalogTools = {
      'npm',
      'pnpm',
      'pip',
      'uv',
      'maven',
      'gradle',
      'android-sdk',
    };
    for (final id in profile.toolIds) {
      final tool = local.tool(id);
      final rows = scoped[id] ?? const <MiseInstalledToolVersionRef>[];
      final active = rows.where((v) => v.active && v.installed).firstOrNull;
      final installed = <String>{
        ...rows.where((v) => v.installed).map((v) => v.version),
        ...?tool?.versions.map((v) => v.version),
        if (tool?.installed == true && tool?.version != null) tool!.version!,
      }.toList();
      final effective = id == 'dart'
          ? dartVersion
          : runtimes.contains(id)
          ? active?.version
          : tool?.installed == true
          ? tool?.version
          : null;
      final reqs = profile.requirements.where((r) => r.tool == id).toList();
      ProjectToolState state;
      var detail = '';
      if (profile.providedTools.contains(id)) {
        state = ProjectToolState.projectProvided;
        detail = '检测到项目 Wrapper；未运行或下载，版本与构建可用性待项目验证。';
      } else if (effective == null) {
        state =
            installed.isEmpty &&
                tool?.installed != true &&
                queryIssue == null &&
                (runtimes.contains(id) || catalogTools.contains(id))
            ? ProjectToolState.missing
            : ProjectToolState.review;
        detail = installed.isNotEmpty ? '本地存在版本，但未确认项目实际生效版本。' : '未确认可用的项目工具。';
        if (!runtimes.contains(id) && !catalogTools.contains(id)) {
          detail = '该工具尚未纳入自动识别目录，请手动核对。';
        }
      } else if (reqs.isEmpty) {
        state = ProjectToolState.available;
        detail = '项目未声明版本约束。';
      } else {
        final results = reqs.map((r) => satisfies(effective, r)).toList();
        state = results.contains(false)
            ? ProjectToolState.mismatch
            : results.contains(null)
            ? ProjectToolState.review
            : ProjectToolState.satisfied;
        if (!runtimes.contains(id)) {
          // Native probes reflect the desktop environment, not Corepack/venv.
          state = ProjectToolState.review;
          detail = '显示本机工具版本；项目专用 Corepack、虚拟环境或 Wrapper 需另行核对。';
        } else if (state == ProjectToolState.review) {
          detail = '别名、动态值或复杂约束未自动判定。';
        }
      }
      checks.add(
        ProjectToolCheck(
          tool: id,
          requirements: reqs,
          installed: installed,
          effective: effective,
          source: id == 'dart' && dartVersion != null
              ? '项目 Flutter SDK 配套 Dart'
              : runtimes.contains(id)
              ? active?.source?.path
              : '本机工具探测',
          state: state,
          detail: detail,
        ),
      );
    }
    return ProjectEnvironment(
      profile,
      checks,
      DateTime.now(),
      queryIssue: queryIssue,
    );
  }

  /// Returns null for syntax whose semantics are not implemented. Never guess.
  static bool? satisfies(String actual, ProjectRequirement requirement) {
    String normalize(String v) {
      v = v.replaceFirst(
        RegExp(r'^(oracle-|temurin-|zulu-|openjdk-|v|go)'),
        '',
      );
      if (v.startsWith('1.8')) v = v.replaceFirst('1.8', '8');
      return v;
    }

    final current = normalize(actual), wanted = normalize(requirement.value);
    List<int>? numbers(String value) => RegExp(r'^\d+(\.\d+)*$').hasMatch(value)
        ? value.split('.').map(int.parse).toList()
        : null;
    final a = numbers(current), b = numbers(wanted);
    if (a == null) return null;
    if (b != null) {
      if (requirement.kind == ProjectRequirementKind.minimum) {
        for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
          final diff = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
          if (diff != 0) return diff > 0;
        }
        return true;
      }
      if (requirement.kind == ProjectRequirementKind.exact ||
          requirement.kind == ProjectRequirementKind.constraint &&
              b.length == 3) {
        return current == wanted;
      }
      return a.length >= b.length &&
          List.generate(b.length, (i) => a[i] == b[i]).every((v) => v);
    }
    if (requirement.kind != ProjectRequirementKind.constraint || a.length > 3) {
      return null;
    }
    // npm-style disjunction supported only when every branch is understood.
    final results = <bool>[];
    for (var branch in wanted.split('||')) {
      branch = branch.trim();
      // Python comma intersections and common shortened numeric bounds.
      branch = branch.replaceAll(',', ' ');
      branch = branch.replaceAllMapped(
        RegExp(r'(>=|<=|>|<)\s*(\d+(?:\.\d+)?)(?![\d.])'),
        (m) {
          final parts = m[2]!.split('.');
          return '${m[1]}${[...parts, ...List.filled(3 - parts.length, '0')].join('.')}';
        },
      );
      if (!RegExp(
        r'^(?:[<>]=?|\^|~)?\d+\.\d+\.\d+(?:\s+(?:[<>]=?)\d+\.\d+\.\d+)*$',
      ).hasMatch(branch)) {
        return null;
      }
      if (branch.startsWith('~')) {
        final base = Version.parse(branch.substring(1));
        branch = '>=$base <${base.major}.${base.minor + 1}.0';
      }
      try {
        results.add(
          VersionConstraint.parse(branch).allows(
            Version.parse(
              '${a[0]}.${a.length > 1 ? a[1] : 0}.${a.length > 2 ? a[2] : 0}',
            ),
          ),
        );
      } catch (_) {
        return null;
      }
    }
    return results.any((v) => v);
  }
}
