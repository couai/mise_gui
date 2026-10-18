import 'dart:convert';
import 'dart:io';

import 'package:mise_gui/services/mise_process_service.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class ClassifiedVersion {
  const ClassifiedVersion({
    required this.tool,
    required this.version,
    required this.active,
    required this.registeredPath,
    required this.actualPath,
    required this.classified,
    this.sourcePath,
    this.rustSdkPath,
    this.dartVersion,
  });
  final String tool, version, registeredPath, actualPath;
  final String? sourcePath;
  final String? rustSdkPath;
  final String? dartVersion;
  final bool active, classified;
}

class ClassifiedToolchainService {
  ClassifiedToolchainService(this.process, this.layout);
  final MiseProcessService process;
  final ToolchainLayout layout;

  Future<List<ClassifiedVersion>> inventory() async {
    // Use HOME so the desktop process/project cwd cannot override global state.
    final result = await process.run(
      MiseCommandRequest(
        arguments: const ['ls', '--json'],
        timeout: const Duration(seconds: 10),
        workingDirectory: layout.home,
      ),
    );
    final json = jsonDecode(result.stdout) as Map<String, dynamic>;
    final versions = <ClassifiedVersion>[];
    for (final tool in ToolchainLayout.categories.keys) {
      for (final row in (json[tool] as List? ?? const [])) {
        if (row['installed'] != true) continue;
        final registered = row['install_path'] as String? ?? '';
        var actual = registered;
        try {
          actual = await Directory(registered).resolveSymbolicLinks();
        } on FileSystemException {
          /* Display the broken path as a warning. */
        }
        versions.add(
          ClassifiedVersion(
            tool: tool,
            version: row['version'] as String,
            active: row['active'] == true,
            registeredPath: registered,
            actualPath: actual,
            classified: await layout.isClassified(tool, registered),
            sourcePath: (row['source'] as Map?)?['path'] as String?,
            rustSdkPath: tool == 'rust'
                ? await _rustSdkPath(row['version'] as String)
                : null,
            dartVersion: tool == 'flutter' ? await _dartVersion(actual) : null,
          ),
        );
      }
    }
    return versions;
  }

  Future<String?> _rustSdkPath(String version) async {
    final directory = Directory('${layout.rustupHome}/toolchains');
    if (!await directory.exists()) return null;
    final matches = await directory
        .list()
        .where(
          (entry) =>
              entry is Directory &&
              entry.uri.pathSegments
                  .where((p) => p.isNotEmpty)
                  .last
                  .startsWith('$version-'),
        )
        .toList();
    return matches.length == 1 ? matches.single.path : null;
  }

  Future<String?> _dartVersion(String sdk) async {
    try {
      return (await File(
        '$sdk/bin/cache/dart-sdk/version',
      ).readAsString()).trim();
    } on FileSystemException {
      return null;
    }
  }

  Future<String> installPlan(String tool, String version) async {
    ToolchainLayout.validateVersion(version);
    layout.categoryRoot(tool);
    final installed = await inventory();
    if (installed.any((v) => v.tool == tool && v.version == version)) {
      throw StateError('该版本已安装，请选择切换。');
    }
    await layout.checkNewTarget(tool, version);
    final spec = '$tool@$version';
    if (tool == 'rust') {
      // rustup owns the SDKs; every mise Rust version shares its proxy binaries.
      return 'mise exec -- rustup toolchain install $version --profile default\n'
          'mise link $spec ${quoteArgument(layout.installTarget(tool, version))}\n'
          'mise reshim';
    }
    final target = quoteArgument(layout.installTarget(tool, version));
    return 'mise install-into $spec $target\nmise link $spec $target\nmise reshim';
  }

  Future<String> switchPlan(
    String tool,
    String version, {
    String? projectPath,
  }) async {
    ToolchainLayout.validateVersion(version);
    if (!(await inventory()).any(
      (v) => v.tool == tool && v.version == version,
    )) {
      throw StateError('该版本未安装，请先在分类目录安装。');
    }
    if (projectPath != null) {
      if (!projectPath.startsWith('/') ||
          !await Directory(projectPath).exists()) {
        throw ArgumentError('请选择存在的项目绝对路径。');
      }
      return 'mise use --path ${quoteArgument('$projectPath/mise.toml')} $tool@$version';
    }
    return 'mise use --global $tool@$version';
  }

  /// Convert upstream action previews to the same classified installation policy.
  /// Re-running this for an already prepared plan validates it without rewriting.
  Future<String> prepare(String script) async {
    final output = <String>[];
    final available = (await inventory())
        .map((v) => '${v.tool}@${v.version}')
        .toSet();
    final plannedTargets = <String, String>{};
    final rustInstalls = <String>{};
    for (final line in const LineSplitter().convert(script)) {
      if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
      final args = parseCommandArguments(line);
      if (args.length < 2 || args.first != 'mise') {
        throw ArgumentError('仅支持 mise 操作。');
      }
      final op = args[1];
      if (op == 'install') {
        if (args.length != 3) throw ArgumentError('每次请选择一个精确工具版本。');
        final (tool, version) = _spec(args[2]);
        if (!available.contains(args[2])) {
          output.add(await installPlan(tool, version));
          available.add(args[2]);
        }
      } else if (op == 'install-into') {
        if (args.length != 4) throw ArgumentError('安装参数不完整。');
        final (tool, version) = _spec(args[2]);
        if (tool == 'rust' || args[3] != layout.installTarget(tool, version)) {
          throw ArgumentError('安装目标不符合分类目录规则。');
        }
        await layout.checkNewTarget(tool, version);
        plannedTargets[args[2]] = args[3];
        output.add(line);
      } else if (op == 'exec') {
        if (args.length != 9 ||
            args.sublist(2, 6).join(' ') != '-- rustup toolchain install' ||
            args[7] != '--profile' ||
            args[8] != 'default') {
          throw ArgumentError('仅支持受控的 rustup 工具链安装。');
        }
        ToolchainLayout.validateVersion(args[6]);
        rustInstalls.add('rust@${args[6]}');
        output.add(line);
      } else if (op == 'link') {
        if (args.length != 4) throw ArgumentError('注册参数不完整。');
        final (tool, version) = _spec(args[2]);
        final expected = layout.installTarget(tool, version);
        if (args[3] != expected ||
            (tool == 'rust'
                ? !rustInstalls.contains(args[2])
                : plannedTargets[args[2]] != expected)) {
          throw ArgumentError('仅注册本次计划安装的分类 SDK。');
        }
        available.add(args[2]);
        output.add(line);
      } else if (op == 'use') {
        final spec = args.last;
        _spec(spec);
        if (!available.contains(spec)) {
          throw StateError('版本尚未安装，禁止通过切换隐式下载：$spec');
        }
        if (args.length == 3) {
          output.add('mise use --global $spec');
        } else if (args.length == 4 && args[2] == '--global') {
          output.add(line);
        } else if (args.length == 5 && args[2] == '--path') {
          final file = File(args[3]);
          if (!file.isAbsolute ||
              !await file.parent.exists() ||
              !args[3].endsWith('/mise.toml')) {
            throw ArgumentError('项目配置必须是现有目录内的 mise.toml。');
          }
          output.add(line);
        } else {
          throw ArgumentError('请选择全局或明确的项目作用域。');
        }
      } else if (op == 'reshim' && args.length == 2) {
        output.add(line);
      } else {
        throw UnsupportedError('首期支持分类安装和版本切换；卸载、批量升级等操作暂未开放。');
      }
    }
    if (output.isEmpty) throw StateError('所选版本已安装，没有需要执行的操作。');
    return output.join('\n');
  }

  (String, String) _spec(String spec) {
    final index = spec.indexOf('@');
    if (index < 1) throw ArgumentError('缺少精确工具版本。');
    final tool = spec.substring(0, index), version = spec.substring(index + 1);
    layout.categoryRoot(tool);
    ToolchainLayout.validateVersion(version);
    return (tool, version);
  }
}
