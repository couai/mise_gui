import 'dart:io';

import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Directory roles and conditional tool relationships, shared by every view.
/// These describe locations, not permission to read their contents or clean them.
class LocalToolProfiles {
  const LocalToolProfiles(this.layout);
  final ToolchainLayout layout;

  Future<LocalTool> enrich(LocalTool tool) async {
    final r = layout.root;
    final h = layout.home;
    final e = layout.environment;
    final android = e['ANDROID_HOME'] ?? '$r/android/sdk';
    final gradle = e['GRADLE_USER_HOME'] ?? '$r/gradle/user-home';
    final paths = <ToolLocation>[];
    Future<void> add(ToolLocationKind kind, String label, String path) async {
      paths.add(
        ToolLocation(
          label: label,
          path: path,
          kind: kind,
          exists:
              await FileSystemEntity.type(path) !=
              FileSystemEntityType.notFound,
        ),
      );
    }

    Future<void> config(String label, String path) =>
        add(ToolLocationKind.configuration, label, path);
    Future<void> cache(String label, String path) =>
        add(ToolLocationKind.cache, label, path);
    Future<void> logs(String path) => add(ToolLocationKind.logs, '日志', path);
    Future<void> install(String label, String path) =>
        add(ToolLocationKind.installation, label, path);

    if (tool.miseTool != null) {
      await config('mise 全局配置', layout.globalConfigPath);
      if (tool.id == 'java') await config('JDK 来源与切换说明', '$r/jdk/README.md');
    }
    switch (tool.id) {
      case 'node':
        await config(
          'npm 用户配置',
          e['NPM_CONFIG_USERCONFIG'] ??
              e['npm_config_userconfig'] ??
              '$r/npm/npmrc',
        );
        await cache('npm 缓存', '$r/npm/cache');
        await logs('$r/npm/cache/_logs');
      case 'python':
        await config('用户包目录', e['PYTHONUSERBASE'] ?? '$r/python/user');
        await cache('pip 缓存', e['PIP_CACHE_DIR'] ?? '$r/pip/cache');
      case 'go':
        await config('Go 配置', '$r/go/config');
        await cache('模块缓存', '${e['GOPATH'] ?? '$r/go/gopath'}/pkg/mod');
        await cache('编译缓存', e['GOCACHE'] ?? '$r/go/cache');
      case 'rust':
        await config('Cargo 配置', '${layout.cargoHome}/config.toml');
        await cache('Cargo 注册表', '${layout.cargoHome}/registry');
        await cache('Cargo Git 缓存', '${layout.cargoHome}/git');
      case 'flutter':
        await config('Flutter 配置', '$r/flutter/config');
        await cache('共享引擎缓存', '$r/flutter/cache');
        await logs('$r/flutter/logs');
      case 'dart':
        await config('Dart 用户状态', '$r/dart/config/dart-tool');
        await cache('Pub 缓存', e['PUB_CACHE'] ?? '$r/dart/pub-cache');
        await cache('分析数据', '$r/dart/analysis');
      case 'npm':
        await config(
          '用户配置',
          e['NPM_CONFIG_USERCONFIG'] ??
              e['npm_config_userconfig'] ??
              '$r/npm/npmrc',
        );
        await install('全局包', '$r/npm/global');
        await cache('缓存', '$r/npm/cache');
        await logs('$r/npm/cache/_logs');
      case 'pnpm':
        await install('命令目录', e['PNPM_HOME'] ?? '$r/pnpm/bin');
        await config('配置', '$r/pnpm/config');
        await cache('Store', '$r/pnpm/store');
        await cache('缓存', '$r/pnpm/cache');
      case 'pip':
        await config('pip 配置', e['PIP_CONFIG_FILE'] ?? '$r/pip/pip.conf');
        await cache('缓存', e['PIP_CACHE_DIR'] ?? '$r/pip/cache');
      case 'uv':
        await config('配置', '$r/uv/config');
        await install('全局工具', e['UV_TOOL_DIR'] ?? '$r/uv/tools');
        await cache('缓存', e['UV_CACHE_DIR'] ?? '$r/uv/cache');
      case 'maven':
        await config('配置', '$r/.m2/settings.xml');
        await cache('本地仓库', '$r/.m2/repository');
      case 'gradle':
        await config('用户配置', '$gradle/gradle.properties');
        await cache('依赖缓存', '$gradle/caches');
        await cache('Wrapper 分发包', '$gradle/wrapper/dists');
        await logs('$gradle/daemon');
      case 'cargo':
        await config('Cargo 配置', '${layout.cargoHome}/config.toml');
        await cache('注册表', '${layout.cargoHome}/registry');
        await cache('Git 缓存', '${layout.cargoHome}/git');
      case 'rustup':
        await config('rustup 配置', '${layout.rustupHome}/settings.toml');
        await cache('下载缓存', '${layout.rustupHome}/downloads');
      case 'homebrew':
        await cache('缓存', e['HOMEBREW_CACHE'] ?? '$r/homebrew/cache');
        await logs(e['HOMEBREW_LOGS'] ?? '$r/homebrew/logs');
      case 'cocoapods':
        await config('用户数据', '$r/cocoapods/home');
        await cache('缓存', '$r/cocoapods/cache');
      case 'android-sdk':
        await install('SDK', android);
        await config('用户配置', e['ANDROID_USER_HOME'] ?? '$r/android/user');
        await config('模拟器数据', e['ANDROID_AVD_HOME'] ?? '$r/android/avd');
      case 'android-studio':
        await install('Android SDK', android);
        await config('用户配置', '$h/Library/Application Support/Google');
        await cache('IDE 缓存', '$h/Library/Caches/Google');
        await logs('$h/Library/Logs/Google');
      case 'adb':
        await install('Platform Tools', '$android/platform-tools');
        await config(
          'Android 用户配置',
          e['ANDROID_USER_HOME'] ?? '$r/android/user',
        );
      case 'xcode':
        await cache('DerivedData', '$r/xcode/derived-data');
        await config('Archives', '$r/xcode/archives');
        await cache('编译缓存', '$r/xcode/compilation-cache');
      case 'simulator' || 'devicehub':
        await config('模拟器设备数据', '$h/Library/Developer/CoreSimulator/Devices');
        await install('模拟器运行时', '/Library/Developer/CoreSimulator/Volumes');
      case 'bruno' || 'reqable' || 'mitmproxy' || 'hbuilderx':
        final folder = tool.id;
        await config(
          '应用数据',
          '$r/$folder/${folder == 'mitmproxy' ? 'config' : 'data'}',
        );
        if (folder == 'bruno' || folder == 'reqable') {
          await config('配置', '$r/$folder/config');
        }
        await cache('缓存', '$r/$folder/cache');
        await logs('$r/$folder/logs');
      case 'toolbox':
        await config('连接配置', '$r/mcp-toolbox/config');
      case 'gopls':
        await cache('分析缓存', '$r/go/gopls/cache');
      case 'dlv':
        await config('调试器配置', '$r/go/delve/config');
      case 'git':
        await config('用户配置', '$h/.gitconfig');
      case 'gh':
        await config('配置目录', '$h/.config/gh');
      case 'mise':
        await config('配置', layout.configDir);
        await config('状态', layout.stateDir);
        await cache('缓存', layout.cacheDir);
      case 'idea' || 'datagrip':
        final prefixes = tool.id == 'idea'
            ? ['IntelliJIdea', 'IdeaIC']
            : ['DataGrip'];
        for (final (kind, label, parent) in [
          (
            ToolLocationKind.configuration,
            'IDE 配置',
            '$h/Library/Application Support/JetBrains',
          ),
          (ToolLocationKind.cache, 'IDE 缓存', '$h/Library/Caches/JetBrains'),
          (ToolLocationKind.logs, 'IDE 日志', '$h/Library/Logs/JetBrains'),
        ]) {
          final dir = Directory(parent);
          if (!await dir.exists()) continue;
          final names = <String>[];
          await for (final entry in dir.list(followLinks: false)) {
            final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
            if (prefixes.any(
                  (prefix) => RegExp('^$prefix[0-9]').hasMatch(name),
                ) &&
                await Directory(entry.path).exists()) {
              names.add(name);
            }
          }
          names.sort();
          for (final name in names) {
            await add(kind, '$label · $name', '$parent/$name');
          }
        }
      case 'jetbrains-toolbox':
        await config('配置', '$h/Library/Application Support/JetBrains/Toolbox');
        await cache('缓存', '$h/Library/Caches/JetBrains/Toolbox');
        await logs('$h/Library/Logs/JetBrains/Toolbox');
      case 'vscode' || 'cursor':
        final folder = tool.id == 'vscode' ? 'Code' : 'Cursor';
        await config('用户配置', '$h/Library/Application Support/$folder/User');
        await cache('缓存', '$h/Library/Application Support/$folder/Cache');
        await logs('$h/Library/Application Support/$folder/logs');
      default:
        break;
    }
    if (tool.executable != null && await File(tool.executable!).exists()) {
      final actual = await File(tool.executable!).resolveSymbolicLinks();
      if (actual != tool.executable) await install('实际程序位置', actual);
    }
    // Explicit roles replace old ambiguous locations with the same path.
    final byPath = {for (final p in paths) p.path: p};
    final locations = <ToolLocation>[
      for (final p in tool.locations)
        byPath.remove(p.path) ??
            ToolLocation(
              label: p.label,
              path: p.path,
              exists: p.exists,
              application: p.application,
              kind:
                  p.application ||
                      p.label == '命令' ||
                      p.label.startsWith('SDK ') ||
                      p.label == '安装目录' ||
                      p.label == '程序' ||
                      p.label == '工具命令'
                  ? ToolLocationKind.installation
                  : p.kind,
            ),
      ...byPath.values,
    ];
    return tool.withProfile(
      locations: locations,
      relations: relations[tool.id] ?? const [],
    );
  }

  static const relations = <String, List<LocalToolRelation>>{
    'npm': [LocalToolRelation('node', '随 Node.js 提供并依赖 Node.js 执行')],
    'pnpm': [LocalToolRelation('node', '执行 pnpm 和项目脚本时使用 Node.js')],
    'pip': [LocalToolRelation('python', '管理对应 Python 环境中的依赖')],
    'uv': [LocalToolRelation('python', '创建项目环境时选择 Python 解释器')],
    'maven': [LocalToolRelation('java', '通过 JAVA_HOME 使用所选 JDK')],
    'gradle': [LocalToolRelation('java', '构建所需 JDK 由项目 Gradle 版本决定')],
    'cargo': [
      LocalToolRelation('rust', '随 Rust 工具链切换'),
      LocalToolRelation('rustup', '提供对应工具链和代理'),
    ],
    'rust': [LocalToolRelation('rustup', '安装和维护真实 Rust 工具链')],
    'rustfmt': [LocalToolRelation('rust', 'Rust 格式化组件')],
    'clippy': [LocalToolRelation('rust', 'Rust 代码检查组件')],
    'rust-analyzer': [LocalToolRelation('rust', 'Rust 语言服务组件')],
    'gopls': [LocalToolRelation('go', 'Go 语言服务')],
    'dlv': [LocalToolRelation('go', 'Go 程序调试')],
    'dart': [LocalToolRelation('flutter', '使用此 Flutter SDK 配套的 Dart，不独立切换')],
    'flutter': [
      LocalToolRelation('dart', 'SDK 自带配套 Dart'),
      LocalToolRelation('java', 'Android 构建使用 JDK'),
      LocalToolRelation('android-sdk', '构建 Android 应用时使用'),
      LocalToolRelation('xcode', '构建 Apple 平台应用时使用'),
    ],
    'android-studio': [
      LocalToolRelation('android-sdk', 'Android 平台和构建工具'),
      LocalToolRelation('java', '项目构建 JDK 单独选择'),
    ],
    'android-ndk': [
      LocalToolRelation('android-sdk', '由 SDK Manager 安装并可多版本并存'),
    ],
    'cmake': [LocalToolRelation('android-sdk', 'Android 原生项目按需使用')],
    'adb': [LocalToolRelation('android-sdk', '属于 Platform Tools')],
    'devicehub': [LocalToolRelation('xcode', 'Xcode 内置设备管理入口')],
    'simulator': [LocalToolRelation('xcode', '兼容旧版模拟器应用入口')],
    'cocoapods': [LocalToolRelation('xcode', 'Apple 项目编译使用 Xcode')],
    'bruno': [
      LocalToolRelation('node', 'bru CLI 通过 mise Node.js 执行；GUI 可独立打开'),
    ],
    'git-lfs': [LocalToolRelation('git', '扩展 Git 大文件存储')],
    'gh': [LocalToolRelation('git', '克隆等仓库操作使用 Git')],
  };
}
