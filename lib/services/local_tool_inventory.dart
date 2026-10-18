import 'dart:convert';
import 'dart:io';

import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/local_tool_process.dart';
import 'package:mise_gui/services/local_tool_profiles.dart';
import 'package:mise_gui/services/local_tool_registry.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

abstract interface class LocalToolInventory {
  Future<LocalToolSnapshot> scan();
}

/// Bounded, local-only discovery. The catalog describes what to check, never
/// substitutes sample versions for real command output or installed metadata.
class SystemLocalToolInventory implements LocalToolInventory {
  SystemLocalToolInventory({
    required this.layout,
    required this.process,
    required this.loadVersions,
    this.applications = '/Applications',
    this.fallbackBins = const ['/opt/homebrew/bin', '/usr/bin', '/bin'],
    this.registry,
  });
  final ToolchainLayout layout;
  final LocalToolProcess process;
  final Future<List<ClassifiedVersion>> Function() loadVersions;
  final String applications;
  final List<String> fallbackBins;
  final LocalToolRegistry? registry;

  Map<String, String> get _environment => {
    ...layout.environment,
    'HOME': layout.home,
    'MISE_OFFLINE': '1',
    'MISE_AUTO_INSTALL': '0',
    'MISE_NOT_FOUND_AUTO_INSTALL': '0',
    'HOMEBREW_NO_AUTO_UPDATE': '1',
    'HOMEBREW_NO_ANALYTICS': '1',
    'COCOAPODS_DISABLE_STATS': 'true',
    'RUSTUP_AUTO_INSTALL': '0',
  };

  @override
  Future<LocalToolSnapshot> scan() async {
    final warnings = <String>[];
    var versions = <ClassifiedVersion>[];
    try {
      versions = await loadVersions();
    } catch (_) {
      warnings.add('mise 版本清单暂不可用；其他工具继续按本地程序和元数据识别。');
    }
    final specs = _catalog();
    final tools = List<LocalTool?>.filled(specs.length, null);
    final runtimeBins = [
      for (final v in versions.where((v) => v.active))
        '${v.rustSdkPath ?? v.actualPath}/bin',
    ];
    var next = 0;
    // Four workers cap filesystem/process pressure; each command has a deadline.
    Future<void> worker() async {
      while (next < specs.length) {
        final index = next++;
        final spec = specs[index];
        try {
          tools[index] = await LocalToolProfiles(
            layout,
          ).enrich(await _inspect(spec, versions, runtimeBins));
        } catch (_) {
          tools[index] = _tool(
            spec,
            status: LocalToolStatus.unavailable,
            notes: ['本地检查失败，请重新扫描或检查目录权限。'],
          );
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    final imported = <LocalTool>[];
    try {
      imported.addAll(await registry?.scan() ?? []);
    } catch (_) {
      warnings.add('手动导入清单读取失败；内置工具继续显示，原清单未被覆盖。');
    }
    return LocalToolSnapshot(
      tools: [...tools.whereType<LocalTool>(), ...imported],
      scannedAt: DateTime.now(),
      warnings: warnings,
    );
  }

  Future<LocalTool> _inspect(
    _ToolSpec spec,
    List<ClassifiedVersion> all,
    List<String> runtimeBins,
  ) async {
    final locations = <ToolLocation>[];
    final notes = <String>[];
    String? version, executable, iconPath;
    var manager = '本地安装';
    var source = '本地程序（来源未核验）';
    var installed = false;
    var issue = false;
    final registered = all.where((v) => v.tool == spec.miseTool).toList();
    final sdkVersions = <LocalToolVersion>[];
    for (final entry in registered) {
      final path = entry.rustSdkPath ?? entry.actualPath;
      final exists = await Directory(path).exists();
      installed |= exists;
      final command = spec.commands.firstOrNull;
      final hasCommand =
          command == null || await File('$path/bin/$command').exists();
      issue |= !exists || !entry.classified || !hasCommand;
      if (exists && !hasCommand) {
        notes.add('${entry.version} 的 SDK 缺少 $command 命令。');
      }
      sdkVersions.add(
        LocalToolVersion(entry.version, path, active: entry.active),
      );
      if (!exists) notes.add('${entry.version} 的注册目录已不存在。');
      if (!entry.classified) notes.add('${entry.version} 位于现有分类目录之外。');
    }
    if (registered.isNotEmpty) {
      manager = 'mise';
      source = spec.id == 'java'
          ? (registered.every((v) => v.version.startsWith('oracle-'))
                ? 'Oracle JDK（本地 SDK）'
                : '本地 JDK；发行商见版本目录')
          : spec.id == 'rust'
          ? 'rustup 工具链'
          : '本地 SDK / mise 注册';
      final active = registered.where((v) => v.active).firstOrNull;
      if (active != null) {
        version = active.version;
        final home = active.rustSdkPath ?? active.actualPath;
        executable = await _findExecutable(spec.commands, extra: ['$home/bin']);
      } else {
        notes.add('已安装版本，但未选择全局默认；项目可使用自己的 mise 配置。');
      }
      if (spec.id == 'flutter') {
        notes.add('Dart 随 Flutter SDK 配套切换。');
      }
    }
    if (spec.id == 'dart') {
      final flutter = all.where((v) => v.tool == 'flutter').toList();
      for (final f in flutter) {
        final path = '${f.actualPath}/bin/cache/dart-sdk';
        if (!await File('$path/bin/dart').exists()) continue;
        installed = true;
        final dv = f.dartVersion ?? await _readText('$path/version');
        sdkVersions.add(LocalToolVersion(dv ?? '版本未知', path, active: f.active));
        if (f.active) {
          version = dv;
          executable = '$path/bin/dart';
        }
      }
      if (installed) {
        manager = 'mise / Flutter';
        source = 'Flutter 配套 Dart SDK';
        notes.add('版本在 Flutter / Dart 工具链中管理，不能独立切换。');
      }
    }
    for (final appName in spec.apps) {
      final path = '$applications/$appName.app';
      if (!await Directory(path).exists() ||
          !await File('$path/Contents/Info.plist').exists()) {
        continue;
      }
      installed = true;
      locations.add(
        ToolLocation(label: '应用', path: path, exists: true, application: true),
      );
      final info = await _appInfo(path);
      version ??= info['CFBundleShortVersionString'] as String?;
      final bundle = info['CFBundleIdentifier'] as String?;
      source = bundle == null ? '本地应用包' : '应用包 · $bundle';
      manager = 'macOS 应用';
    }
    if (spec.id == 'android-sdk') {
      final sdk =
          layout.environment['ANDROID_HOME'] ?? '${layout.root}/android/sdk';
      final platforms = <String>[];
      for (final name in await _childNames('$sdk/platforms')) {
        if (name.startsWith('android-') &&
            await File('$sdk/platforms/$name/android.jar').exists()) {
          platforms.add(name);
        }
      }
      final sdkManager = await File(
        '$sdk/cmdline-tools/latest/bin/sdkmanager',
      ).exists();
      if (platforms.isNotEmpty ||
          sdkManager ||
          await File('$sdk/platform-tools/adb').exists()) {
        installed = true;
        manager = 'Android SDK Manager';
        source = 'Android SDK 本地元数据';
        version = platforms.isEmpty ? null : platforms.join(' / ');
        if (platforms.isEmpty) notes.add('尚未检测到已安装的 SDK 平台。');
        notes.add('SDK 平台按项目版本并存；本页仅识别，不改动 SDK。');
      }
    }
    if (spec.id == 'android-ndk' || spec.id == 'cmake') {
      final sdk =
          layout.environment['ANDROID_HOME'] ?? '${layout.root}/android/sdk';
      final sub = spec.id == 'cmake' ? 'cmake' : 'ndk';
      for (final name in await _childNames('$sdk/$sub')) {
        final path = '$sdk/$sub/$name';
        // source.properties proves an installed SDK package, not an empty folder.
        final properties = await _readText('$path/source.properties');
        if (properties == null) continue;
        final revision =
            RegExp(
              r'^Pkg.Revision\s*=\s*(.+)$',
              multiLine: true,
            ).firstMatch(properties)?.group(1)?.trim() ??
            name;
        sdkVersions.add(LocalToolVersion(revision, path));
      }
      if (sdkVersions.isNotEmpty) {
        installed = true;
        version = sdkVersions.map((v) => v.version).join(' / ');
        manager = 'Android SDK Manager';
        source = 'Android SDK 包元数据';
      }
    }
    if (spec.id == 'gradle') {
      final dists =
          '${layout.environment['GRADLE_USER_HOME'] ?? '${layout.root}/gradle/user-home'}/wrapper/dists';
      for (final distribution in await _childNames(dists)) {
        for (final hash in await _childNames('$dists/$distribution')) {
          for (final name in await _childNames('$dists/$distribution/$hash')) {
            final path = '$dists/$distribution/$hash/$name';
            if (name.startsWith('gradle-') &&
                await File('$path/bin/gradle').exists()) {
              sdkVersions.add(LocalToolVersion(name.substring(7), path));
            }
          }
        }
      }
      if (sdkVersions.isNotEmpty) {
        installed = true;
        version = sdkVersions.map((v) => v.version).join(' / ');
        manager = 'Gradle Wrapper';
        source = '已下载的 Wrapper 分发包';
        notes.add('构建时由各项目的 gradle-wrapper.properties 决定版本。');
      }
    }
    if (registered.isEmpty && spec.id != 'dart' && spec.id != 'flutter') {
      executable = await _findExecutable(
        spec.commands,
        extra: [...spec.bins, ...runtimeBins],
      );
      if (executable != null) {
        final canonical = await File(executable).resolveSymbolicLinks();
        // A mise shim alone is not proof that a runtime is installed. Never
        // execute an unresolved shim and risk an implicit runtime installation.
        if (canonical.contains('/shims/') ||
            (spec.id != 'mise' && canonical.endsWith('/mise'))) {
          if (!installed) notes.add('发现 mise shim，尚未确认实际安装。');
          executable = null;
        } else {
          LocalCommandResult result;
          try {
            result = await process.run(
              executable,
              spec.args,
              environment: _environment,
              workingDirectory: layout.home,
            );
          } catch (_) {
            result = const LocalCommandResult(-1, '', '');
          }
          final output = '${result.stdout}\n${result.stderr}';
          if (result.exitCode == 0) {
            installed = true;
            final commandVersion = _version(output);
            if (version == null || version == '0.0.0') version = commandVersion;
            if (spec.apps.isNotEmpty && commandVersion != null) {
              notes.add('CLI 版本：$commandVersion');
            }
            if (spec.id == 'homebrew') {
              manager = 'Homebrew';
              source = 'Homebrew 本地程序';
            }
            if (spec.id == 'cargo') {
              manager = 'mise / rustup';
              source = 'Rust 配套 Cargo';
            }
            if (spec.id == 'rustup') {
              manager = 'rustup';
              source = '本地 rustup 程序';
            }
            if (canonical.contains('/Cellar/') ||
                canonical.contains('/Caskroom/')) {
              manager = 'Homebrew';
              source = 'Homebrew 本地安装路径';
            } else if (spec.apps.isEmpty &&
                spec.miseTool == null &&
                manager == '本地安装') {
              manager = '本地 CLI';
            }
          } else if (!installed) {
            installed = true;
            issue = true;
            notes.add('程序存在，但版本命令返回失败；未读取业务配置。');
          } else {
            issue = true;
            notes.add('CLI 版本检查失败，GUI 应用仍可打开。');
          }
        }
      }
    }
    for (final entry in spec.paths.entries) {
      final type = await FileSystemEntity.type(entry.value);
      locations.add(
        ToolLocation(
          label: entry.key,
          path: entry.value,
          exists: type != FileSystemEntityType.notFound,
        ),
      );
    }
    if (executable != null) {
      locations.insert(
        0,
        ToolLocation(
          label: '命令',
          path: executable,
          exists: await File(executable).exists(),
        ),
      );
    }
    for (final sdk in sdkVersions) {
      locations.add(
        ToolLocation(
          label: 'SDK ${sdk.version}',
          path: sdk.path,
          exists: await Directory(sdk.path).exists(),
        ),
      );
    }
    if (installed && version == null && sdkVersions.isEmpty) {
      notes.add('已检测到程序，暂未取得版本号。');
    }
    return _tool(
      spec,
      status: installed
          ? (issue ? LocalToolStatus.attention : LocalToolStatus.ready)
          : registered.isNotEmpty
          ? LocalToolStatus.unavailable
          : LocalToolStatus.missing,
      version: version,
      manager: manager,
      source: source,
      executable: executable,
      versions: sdkVersions,
      locations: locations,
      notes: notes,
      iconPath: iconPath,
    );
  }

  LocalTool _tool(
    _ToolSpec spec, {
    required LocalToolStatus status,
    String? version,
    String manager = '待识别',
    String source = '未检测到安装',
    String? executable,
    List<LocalToolVersion> versions = const [],
    List<ToolLocation> locations = const [],
    List<String> notes = const [],
    String? iconPath,
  }) => LocalTool(
    id: spec.id,
    name: spec.name,
    category: spec.category,
    description: spec.description,
    status: status,
    version: version,
    manager: manager,
    source: source,
    executable: executable,
    versions: versions,
    locations: locations,
    notes: notes,
    miseTool: spec.id == 'dart' ? 'flutter' : spec.miseTool,
    iconPath: iconPath,
  );

  Future<String?> _findExecutable(
    List<String> names, {
    List<String> extra = const [],
  }) async {
    final directories = [
      ...extra,
      ...?layout.environment['PATH']?.split(
        Platform.pathSeparator == '/' ? ':' : ';',
      ),
      ...fallbackBins,
    ];
    for (final dir in directories.where((d) => d.startsWith('/'))) {
      for (final name in names) {
        final file = File('$dir/$name');
        if (!await file.exists() || ((await file.stat()).mode & 0x49) == 0) {
          continue;
        }
        final actual = await file.resolveSymbolicLinks();
        if (actual.contains('/shims/') ||
            (name != 'mise' && actual.endsWith('/mise'))) {
          continue;
        }
        return file.path;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _appInfo(String app) async {
    try {
      final result = await process.run('/usr/bin/plutil', [
        '-convert',
        'json',
        '-o',
        '-',
        '$app/Contents/Info.plist',
      ]);
      if (result.exitCode != 0) return {};
      final value = jsonDecode(result.stdout);
      return value is Map<String, dynamic> ? value : {};
    } catch (_) {
      return {};
    }
  }

  Future<List<String>> _childNames(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return [];
    final names = <String>[];
    await for (final entry in directory.list(followLinks: false)) {
      if (await FileSystemEntity.isDirectory(entry.path)) {
        names.add(entry.uri.pathSegments.where((p) => p.isNotEmpty).last);
      }
    }
    names.sort();
    return names;
  }

  Future<String?> _readText(String path) async {
    final file = File(path);
    if (!await file.exists() || await file.length() > 64 * 1024) return null;
    return (await file.readAsString()).trim();
  }

  String? _version(String output) => RegExp(
    r'(?:^|[^A-Za-z0-9])v?(\d+(?:\.\d+){1,3}(?:[+_-][\w.]+)?)',
  ).firstMatch(output)?.group(1);

  List<_ToolSpec> _catalog() {
    final r = layout.root;
    final android = layout.environment['ANDROID_HOME'] ?? '$r/android/sdk';
    _ToolSpec cli(
      String id,
      String name,
      LocalToolCategory category,
      String description, {
      String? command,
      String? folder,
      List<String> args = const ['--version'],
      Map<String, String> paths = const {},
    }) => _ToolSpec(
      id,
      name,
      category,
      description,
      commands: [command ?? id],
      args: args,
      bins: [
        if (folder != null) '$r/$folder/bin',
        if (folder != null) '$r/$folder',
      ],
      paths: paths,
    );
    _ToolSpec app(
      String id,
      String name,
      LocalToolCategory category,
      String description, {
      String? bundle,
      String? folder,
      List<String> commands = const [],
    }) => _ToolSpec(
      id,
      name,
      category,
      description,
      apps: [bundle ?? name],
      commands: commands,
      bins: [if (folder != null) '$r/$folder/bin'],
      paths: {
        if (folder != null)
          '配置 / 数据':
              '$r/$folder/${folder == 'xcode' ? 'derived-data' : 'data'}',
        if (folder == 'xcode') '归档': '$r/xcode/archives',
        if (folder == 'xcode') '编译缓存': '$r/xcode/compilation-cache',
        if (folder == 'reqable') 'MCP 入口': '$r/reqable/bin',
        if (folder == 'mitmproxy') 'CLI / mitmweb': '$r/mitmproxy/bin',
        if (folder == 'bruno') 'CLI': '$r/bruno/bin',
        if (folder == 'reqable' || folder == 'mitmproxy')
          '业务配置': '$r/$folder/config',
        if (folder != null && folder != 'xcode') '缓存': '$r/$folder/cache',
        if (folder != null && folder != 'xcode') '日志': '$r/$folder/logs',
      },
    );
    return [
      for (final (id, name, description) in [
        ('java', 'Java', 'JVM 运行时与编译器；支持多个 JDK。'),
        ('node', 'Node.js', 'JavaScript / TypeScript 服务端运行时。'),
        ('python', 'Python', 'Python 解释器；项目依赖保留在虚拟环境。'),
        ('go', 'Go', 'Go SDK；gopls、Delve 使用现有工具目录。'),
        ('rust', 'Rust', 'Rust 工具链由 rustup 安装、mise 选择。'),
        ('flutter', 'Flutter', '跨平台应用 SDK，配套提供 Dart。'),
      ])
        _ToolSpec(
          id,
          name,
          LocalToolCategory.runtime,
          description,
          miseTool: id,
          commands: [
            id == 'java'
                ? 'java'
                : id == 'rust'
                ? 'rustc'
                : id,
          ],
          args: id == 'java' ? ['-version'] : ['--version'],
          paths: {
            '安装目录': layout.categoryRoot(id),
            if (id == 'rust') 'rustup': layout.rustupHome,
            if (id == 'rust') 'Cargo / 依赖': layout.cargoHome,
            if (id == 'go') '模块缓存': '$r/go/gopath/pkg/mod',
            if (id == 'go') '工具命令': '$r/go/bin',
            if (id == 'flutter') '配置': '$r/flutter/config',
          },
        ),
      _ToolSpec(
        'dart',
        'Dart',
        LocalToolCategory.runtime,
        '随 Flutter 配套安装和切换。',
        paths: {'Pub 缓存': '$r/dart/pub-cache', '用户状态': '$r/dart/config'},
      ),
      cli(
        'npm',
        'npm',
        LocalToolCategory.build,
        'Node.js 包管理器。',
        paths: {'缓存': '$r/npm/cache', '全局包': '$r/npm/global'},
      ),
      cli(
        'pnpm',
        'pnpm',
        LocalToolCategory.build,
        '高效的 JavaScript 包管理器。',
        folder: 'pnpm',
        paths: {'数据 / 缓存': '$r/pnpm'},
      ),
      cli(
        'pip',
        'pip',
        LocalToolCategory.build,
        'Python 包管理器。',
        command: 'pip3',
        paths: {'缓存': '$r/pip/cache'},
      ),
      cli(
        'uv',
        'uv',
        LocalToolCategory.build,
        'Python 环境和依赖管理。',
        folder: 'uv',
        paths: {'缓存': '$r/uv/cache'},
      ),
      cli(
        'maven',
        'Maven',
        LocalToolCategory.build,
        'Java 构建与依赖管理。',
        command: 'mvn',
        folder: 'maven/current',
        args: ['-v'],
        paths: {
          '安装目录': '$r/maven',
          '仓库': '$r/.m2/repository',
          '配置': '$r/.m2/settings.xml',
        },
      ),
      _ToolSpec(
        'gradle',
        'Gradle',
        LocalToolCategory.build,
        '项目 Wrapper 构建工具与共享依赖缓存。',
        paths: {
          '用户目录':
              layout.environment['GRADLE_USER_HOME'] ?? '$r/gradle/user-home',
        },
      ),
      cli(
        'cargo',
        'Cargo',
        LocalToolCategory.build,
        'Rust 构建与包管理；随 Rust 切换。',
        folder: 'rust/cargo',
        paths: {'依赖 / 工具': layout.cargoHome},
      ),
      cli(
        'rustup',
        'rustup',
        LocalToolCategory.build,
        'Rust 工具链安装器。',
        folder: 'rust/cargo',
        paths: {'工具链': layout.rustupHome},
      ),
      cli(
        'cocoapods',
        'CocoaPods',
        LocalToolCategory.build,
        'Apple 平台依赖管理。',
        command: 'pod',
        paths: {'数据': '$r/cocoapods/home', '缓存': '$r/cocoapods/cache'},
      ),
      cli(
        'homebrew',
        'Homebrew',
        LocalToolCategory.build,
        '系统级 CLI 和应用包管理器。',
        command: 'brew',
        paths: {'安装目录': '/opt/homebrew'},
      ),
      _ToolSpec(
        'android-sdk',
        'Android SDK',
        LocalToolCategory.mobile,
        '平台、构建工具和模拟器镜像。',
        paths: {
          'SDK': android,
          'AVD': '$r/android/avd',
          '用户配置': '$r/android/user',
        },
      ),
      _ToolSpec(
        'android-ndk',
        'Android NDK',
        LocalToolCategory.mobile,
        'Android C / C++ 原生工具链。',
        paths: {'安装目录': '$android/ndk'},
      ),
      _ToolSpec(
        'cmake',
        'CMake',
        LocalToolCategory.mobile,
        'Android 原生构建工具。',
        paths: {'安装目录': '$android/cmake'},
      ),
      cli(
        'adb',
        'ADB',
        LocalToolCategory.mobile,
        'Android 设备调试桥。',
        folder: 'android/sdk/platform-tools',
        args: ['version'],
      ),
      app(
        'android-studio',
        'Android Studio',
        LocalToolCategory.mobile,
        'Android IDE、SDK 和模拟器管理入口。',
      ),
      app(
        'xcode',
        'Xcode',
        LocalToolCategory.mobile,
        'Apple 平台 IDE 和设备开发工具。',
        folder: 'xcode',
      ),
      const _ToolSpec(
        'simulator',
        'Simulator',
        LocalToolCategory.mobile,
        '使用 Xcode 自带的 Apple 设备模拟器。',
        apps: [
          'Xcode.app/Contents/Applications/Simulator',
          'Xcode.app/Contents/Developer/Applications/Simulator',
        ],
      ),
      const _ToolSpec(
        'devicehub',
        'Device Hub',
        LocalToolCategory.mobile,
        'Xcode 的真实设备与模拟器管理入口。',
        apps: ['Xcode.app/Contents/Applications/DeviceHub'],
      ),
      app(
        'bruno',
        'Bruno',
        LocalToolCategory.network,
        'API 集合、GUI 和 bru CLI 使用项目中的同一集合。',
        folder: 'bruno',
        commands: ['bru'],
      ),
      app(
        'reqable',
        'Reqable',
        LocalToolCategory.network,
        'HTTP 调试、API 测试与官方 MCP。',
        folder: 'reqable',
      ),
      app(
        'mitmproxy',
        'mitmproxy',
        LocalToolCategory.network,
        'CLI 抓包代理；mitmweb 提供浏览器界面。',
        folder: 'mitmproxy',
        commands: ['mitmproxy'],
      ),
      cli(
        'toolbox',
        'MCP Toolbox',
        LocalToolCategory.network,
        '数据库 MCP 服务；连接配置保持原样。',
        folder: 'mcp-toolbox',
        paths: {
          '程序': '$r/mcp-toolbox/bin',
          '连接配置': '$r/mcp-toolbox/config',
          '说明': '$r/mcp-toolbox/README.md',
        },
      ),
      app(
        'idea',
        'IntelliJ IDEA',
        LocalToolCategory.editor,
        'Java / Kotlin 与全栈 IDE。',
      ),
      app('datagrip', 'DataGrip', LocalToolCategory.editor, '数据库开发与管理。'),
      app(
        'vscode',
        'Visual Studio Code',
        LocalToolCategory.editor,
        '代码编辑器；使用已配置的语言插件。',
      ),
      app('cursor', 'Cursor', LocalToolCategory.editor, 'AI 代码编辑器。'),
      app(
        'hbuilderx',
        'HBuilderX',
        LocalToolCategory.editor,
        'uni-app 与 Web 开发。',
        folder: 'hbuilderx',
      ),
      app(
        'jetbrains-toolbox',
        'JetBrains Toolbox',
        LocalToolCategory.editor,
        'JetBrains IDE 管理入口。',
      ),
      app(
        'navicat',
        'Navicat Premium',
        LocalToolCategory.editor,
        '数据库可视化管理工具。',
      ),
      cli(
        'gopls',
        'gopls',
        LocalToolCategory.utility,
        'Go 语言服务。',
        folder: 'go',
        args: ['version'],
      ),
      cli(
        'dlv',
        'Delve',
        LocalToolCategory.utility,
        'Go 调试器。',
        folder: 'go',
        args: ['version'],
      ),
      cli(
        'rustfmt',
        'rustfmt',
        LocalToolCategory.utility,
        'Rust 代码格式化。',
        folder: 'rust/cargo',
      ),
      cli(
        'clippy',
        'Clippy',
        LocalToolCategory.utility,
        'Rust 代码检查。',
        command: 'cargo-clippy',
        folder: 'rust/cargo',
      ),
      cli(
        'rust-analyzer',
        'rust-analyzer',
        LocalToolCategory.utility,
        'Rust 语言服务。',
        folder: 'rust/cargo',
      ),
      cli('git', 'Git', LocalToolCategory.utility, '版本控制；保留现有用户与认证配置。'),
      cli('git-lfs', 'Git LFS', LocalToolCategory.utility, '大文件版本管理。'),
      cli(
        'gh',
        'GitHub CLI',
        LocalToolCategory.utility,
        'GitHub 命令行；复用本机已登录账号。',
      ),
      cli('wget', 'wget', LocalToolCategory.utility, '命令行下载工具。'),
      cli(
        'mise',
        'mise',
        LocalToolCategory.utility,
        '运行时版本选择与项目环境。',
        paths: {
          '配置': layout.configDir,
          '数据': layout.dataDir,
          '缓存': layout.cacheDir,
        },
      ),
    ];
  }
}

class _ToolSpec {
  const _ToolSpec(
    this.id,
    this.name,
    this.category,
    this.description, {
    this.commands = const [],
    this.args = const ['--version'],
    this.apps = const [],
    this.paths = const {},
    this.bins = const [],
    this.miseTool,
  });
  final String id, name, description;
  final LocalToolCategory category;
  final List<String> commands, args, apps, bins;
  final Map<String, String> paths;
  final String? miseTool;
}
