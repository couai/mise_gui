import 'dart:async';
import 'dart:io';
import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

/// Local metadata + bounded native disk usage. No payload reads or mutations.
class DirectoryStorageService {
  const DirectoryStorageService({
    required this.layout,
    required this.reader,
    this.applications = '/Applications',
    this.homebrew = '/opt/homebrew',
  });
  final ToolchainLayout layout;
  final DirectoryUsageReader reader;
  final String applications, homebrew;

  Stream<StorageSnapshot> scan(
    LocalToolSnapshot inventory,
    DirectoryScanCancellation cancellation,
  ) async* {
    final warnings = [...inventory.warnings];
    final candidates = <String, List<StorageOwner>>{};
    void add(String path, StorageOwner owner) {
      if (!File(path).isAbsolute) return;
      final key = normalizeStoragePath(path);
      final owners = candidates.putIfAbsent(key, () => []);
      if (!owners.any(
        (o) =>
            o.id == owner.id && o.label == owner.label && o.kind == owner.kind,
      )) {
        owners.add(owner);
      }
    }

    for (final tool in inventory.tools) {
      for (final location in tool.locations) {
        add(
          location.path,
          StorageOwner(
            tool.id,
            tool.name,
            location.label,
            location.kind,
            imported: tool.imported,
          ),
        );
      }
    }
    final r = layout.root;
    add(
      r,
      const StorageOwner('shared', '共享工具目录', '分类根目录', ToolLocationKind.other),
    );
    add(
      layout.appDir,
      const StorageOwner(
        'devworkbench',
        'DevWorkbench',
        '配置 / 状态',
        ToolLocationKind.configuration,
      ),
    );
    for (final (folder, id, name) in classifiedFolders) {
      final path = '$r/$folder';
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        add(path, StorageOwner(id, name, '分类目录', ToolLocationKind.other));
      }
    }
    try {
      if (await Directory(r).exists()) {
        await for (final entry in Directory(r).list(followLinks: false)) {
          final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
          if (const ['.DS_Store', '.localized'].contains(name)) continue;
          if (!classifiedFolders.any((f) => f.$1 == name)) {
            final known = const [
              'env.zsh',
              'env.bash',
              'README.md',
            ].contains(name);
            final registered = candidates.entries
                .where((c) => storageContains(entry.path, c.key))
                .expand((c) => c.value)
                .where((o) => o.imported)
                .toList();
            if (!known && registered.isNotEmpty) {
              for (final owner in registered) {
                add(
                  entry.path,
                  StorageOwner(
                    owner.id,
                    owner.name,
                    '包含已登记工具',
                    ToolLocationKind.other,
                    imported: true,
                  ),
                );
              }
            } else {
              add(
                entry.path,
                StorageOwner(
                  known ? 'shared' : 'unassigned',
                  known ? '共享环境' : '未关联工具',
                  name,
                  ToolLocationKind.configuration,
                ),
              );
            }
          }
        }
      }
    } catch (_) {
      warnings.add('分类根目录的部分条目不可访问。');
    }
    add(
      '$r/typescript/cache',
      const StorageOwner(
        'typescript',
        'TypeScript',
        '缓存',
        ToolLocationKind.cache,
      ),
    );
    final aliases = _aliases();
    for (final alias in aliases) {
      add(alias.$1, StorageOwner(alias.$3, alias.$4, '兼容路径', alias.$5));
    }
    final root = await _canonical(r);
    final native = (
      home: await _canonical(layout.home),
      applications: await _canonical(applications),
      homebrew: await _canonical(homebrew),
    );
    final entries = <StorageEntry>[];
    final started = DateTime.now();
    for (final batch in _batches(candidates.entries.toList(), 16)) {
      if (cancellation.cancelled) break;
      entries.addAll(
        await Future.wait(
          batch.map(
            (c) => _inspect(c.key, c.value, aliases, root, native).timeout(
              const Duration(seconds: 5),
              onTimeout: () => StorageEntry(
                path: c.key,
                owners: c.value,
                linkState: StorageLinkState.unavailable,
                compliance: StorageCompliance.classified,
                policyNote: '元数据检查超时，请核对路径可访问性。',
                usage: const StorageUsage(
                  StorageUsageState.skipped,
                  note: '元数据检查超时，未计入。',
                ),
              ),
            ),
          ),
        ),
      );
    }
    final targets = entries
        .where((e) => e.exists && e.usage.state != StorageUsageState.skipped)
        .map((e) => e.canonicalPath!)
        .toSet()
        .toList();
    final aggregateTargets = storageRoots(
      entries.where(
        (e) => e.exists && e.usage.state != StorageUsageState.skipped,
      ),
    ).map((e) => e.canonicalPath).toSet();
    targets.sort(
      (a, b) => (aggregateTargets.contains(a) ? 0 : 1).compareTo(
        aggregateTargets.contains(b) ? 0 : 1,
      ),
    );
    final sizes = <String, StorageUsage>{};
    StorageSnapshot snapshot({required bool scanning, int completed = 0}) {
      final measured = entries
          .map(
            (e) => e.measured(
              sizes[e.canonicalPath] ??
                  (cancellation.cancelled &&
                          e.usage.state == StorageUsageState.pending
                      ? const StorageUsage(StorageUsageState.cancelled)
                      : e.usage),
            ),
          )
          .toList();
      final roots = storageRoots(
        measured.where(
          (e) => e.exists && e.usage.state != StorageUsageState.skipped,
        ),
      );
      return StorageSnapshot(
        entries: [
          for (final e in measured)
            e.measured(
              e.usage,
              coveredBy: roots
                  .where(
                    (p) =>
                        p.path != e.path &&
                        storageContains(
                          p.canonicalPath!,
                          e.canonicalPath ?? '\u0000',
                        ),
                  )
                  .firstOrNull
                  ?.path,
            ),
        ],
        scannedAt: started,
        scanning: scanning,
        cancelled: cancellation.cancelled,
        completed: completed,
        total: targets.length,
        warnings: warnings,
      );
    }

    yield snapshot(scanning: !cancellation.cancelled);
    var completed = 0;
    for (final batch in _batches(targets, 2)) {
      if (cancellation.cancelled) break;
      final values = await Future.wait(
        batch.map((path) async {
          try {
            return await reader.measure(path, cancellation);
          } catch (_) {
            return const StorageUsage(
              StorageUsageState.failed,
              note: '磁盘占用检查失败。',
            );
          }
        }),
      );
      for (var i = 0; i < batch.length; i++) {
        sizes[batch[i]] = values[i];
      }
      completed += batch.length;
      yield snapshot(
        scanning: !cancellation.cancelled && completed < targets.length,
        completed: completed,
      );
    }
    yield snapshot(scanning: false, completed: completed);
  }

  Future<StorageEntry> _inspect(
    String path,
    List<StorageOwner> owners,
    List<(String, String, String, String, ToolLocationKind)> aliases,
    String root,
    ({String home, String applications, String homebrew}) native,
  ) async {
    final resolved = await _resolve(path);
    final actual = resolved.$1;
    var compliance = StorageCompliance.classified;
    var note = '实际路径位于分类目录。';
    final alias = aliases.where((a) => a.$1 == path).firstOrNull;
    if (actual == null) {
      note = alias == null ? '路径尚未创建、已移除或不可访问。' : '预期目标：${alias.$2}';
    } else if (alias != null && actual != await _canonical(alias.$2)) {
      compliance = StorageCompliance.wrongAlias;
      note = '预期指向 ${alias.$2}；当前实际路径不同。';
    } else if (owners.any((o) => o.id == 'unassigned')) {
      compliance = StorageCompliance.unassigned;
      note = '分类根目录中的条目尚未关联到已声明工具分类。';
    } else if (storageContains(root, actual)) {
      final allFolders = owners
          .expand((o) => allowedFolders[o.id] ?? const <String>[])
          .toSet();
      if (allFolders.isNotEmpty &&
          !allFolders.any((f) => storageContains('$root/$f', actual))) {
        compliance = StorageCompliance.misplaced;
        note =
            '归属工具的预期分类：${allFolders.map((f) => '${layout.root}/$f').join('、')}';
      }
    } else if (_nativeException(path, actual, owners, native)
        case final String reason) {
      compliance = StorageCompliance.exception;
      note = reason;
    } else {
      compliance = StorageCompliance.outside;
      note = owners.any((o) => o.imported)
          ? '手动登记位置；实际路径在分类目录外。'
          : path.endsWith('.app')
          ? '应用应位于 $applications。'
          : '实际路径不在 ${layout.root}，可核对后另行整理。';
    }
    final skip = actual == null ? null : _skipReason(actual, native.home);
    return StorageEntry(
      path: path,
      owners: owners,
      canonicalPath: actual,
      linkState: resolved.$2,
      links: resolved.$3,
      compliance: compliance,
      policyNote: note,
      usage: skip != null
          ? StorageUsage(StorageUsageState.skipped, note: skip)
          : actual == null
          ? const StorageUsage(StorageUsageState.skipped, note: '没有可测量的有效路径。')
          : const StorageUsage(StorageUsageState.pending),
    );
  }

  String? _nativeException(
    String path,
    String actual,
    List<StorageOwner> owners,
    ({String home, String applications, String homebrew}) native,
  ) {
    if (storageContains(native.applications, actual)) {
      return 'GUI 应用和应用内置工具保留在默认安装位置。';
    }
    if (storageContains(native.homebrew, actual)) {
      return 'Homebrew 管理的程序保留在 $homebrew。';
    }
    if (const [
      '/usr/bin',
      '/bin',
      '/usr/sbin',
      '/sbin',
    ].any((r) => storageContains(r, actual))) {
      return 'macOS 自带程序保留系统位置。';
    }
    if (storageContains(
          '${native.home}/Library/Developer/CoreSimulator',
          actual,
        ) ||
        storageContains('/Library/Developer/CoreSimulator', actual)) {
      return 'Apple 管理的模拟器目录保留原生位置。';
    }
    if (path == '${layout.home}/.gitconfig' ||
        path == '${layout.home}/.config/gh' &&
            owners.any((o) => o.id == 'gh')) {
      return 'Git / GitHub 账号配置保留标准用户目录。';
    }
    if (storageContains('${native.home}/Library/Preferences', actual)) {
      return 'macOS 原生偏好设置保留系统管理位置。';
    }
    return null;
  }

  String? _skipReason(String path, String home) {
    if ([
      '/',
      home,
      '/Users',
      '/Applications',
      '/Library',
      '/System',
      '/usr',
      '/opt',
      '$home/Library',
    ].contains(path)) {
      return '范围过大，仅检查元数据；请登记具体的工具子目录。';
    }
    if (storageContains('/Volumes', path) ||
        storageContains('/Network', path) ||
        storageContains('/Library/Developer/CoreSimulator/Volumes', path)) {
      return '挂载目录不递归测量，未计入空间汇总。';
    }
    return null;
  }

  Future<(String?, StorageLinkState, List<StorageLinkHop>)> _resolve(
    String path,
  ) async {
    final hops = <StorageLinkHop>[];
    final seen = <String>{};
    var pending = path.split('/').where((s) => s.isNotEmpty).toList();
    var current = '/';
    var finalLink = false;
    var brokenTarget = false;
    try {
      while (pending.isNotEmpty) {
        final part = pending.removeAt(0);
        if (part == '.') continue;
        if (part == '..') {
          current = Directory(current).parent.path;
          continue;
        }
        final next = current == '/' ? '/$part' : '$current/$part';
        final type = await FileSystemEntity.type(next, followLinks: false);
        if (type == FileSystemEntityType.link) {
          finalLink |= pending.isEmpty;
          final key = '$next|${pending.join('/')}';
          if (!seen.add(key) || hops.length >= 40) {
            return (null, StorageLinkState.cycle, hops);
          }
          final target = await Link(next).target();
          final absolute = target.startsWith('/') ? target : '$current/$target';
          hops.add(StorageLinkHop(next, absolute));
          brokenTarget |=
              await FileSystemEntity.type(absolute) ==
              FileSystemEntityType.notFound;
          pending = [
            ...absolute.split('/').where((s) => s.isNotEmpty),
            ...pending,
          ];
          current = '/';
        } else if (type == FileSystemEntityType.notFound) {
          // realpath preserves permission errors that a type probe can mask.
          try {
            await File(next).resolveSymbolicLinks();
          } on FileSystemException catch (e) {
            if (e.osError?.errorCode == 13 || e.osError?.errorCode == 1) {
              return (null, StorageLinkState.unavailable, hops);
            }
          }
          return (
            null,
            brokenTarget ? StorageLinkState.broken : StorageLinkState.missing,
            hops,
          );
        } else {
          current = next;
        }
      }
      return (
        current,
        hops.isEmpty
            ? StorageLinkState.direct
            : finalLink
            ? StorageLinkState.linked
            : StorageLinkState.inherited,
        hops,
      );
    } catch (_) {
      return (null, StorageLinkState.unavailable, hops);
    }
  }

  Future<String> _canonical(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } catch (_) {
      return normalizeStoragePath(path);
    }
  }

  List<(String, String, String, String, ToolLocationKind)> _aliases() {
    final h = layout.home, r = layout.root;
    final e = layout.environment;
    return [
      ('$h/.m2', '$r/.m2', 'maven', 'Maven', ToolLocationKind.other),
      (
        '$h/.gradle',
        e['GRADLE_USER_HOME'] ?? '$r/gradle/user-home',
        'gradle',
        'Gradle',
        ToolLocationKind.other,
      ),
      (
        '$h/.android',
        e['ANDROID_USER_HOME'] ?? '$r/android/user',
        'android-sdk',
        'Android SDK',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Android/sdk',
        e['ANDROID_HOME'] ?? '$r/android/sdk',
        'android-sdk',
        'Android SDK',
        ToolLocationKind.installation,
      ),
      ('$h/.cargo', layout.cargoHome, 'cargo', 'Cargo', ToolLocationKind.other),
      (
        '$h/.rustup',
        layout.rustupHome,
        'rustup',
        'rustup',
        ToolLocationKind.installation,
      ),
      (
        '$h/.cocoapods',
        '$r/cocoapods/home',
        'cocoapods',
        'CocoaPods',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Caches/CocoaPods',
        '$r/cocoapods/cache',
        'cocoapods',
        'CocoaPods',
        ToolLocationKind.cache,
      ),
      (
        '$h/.dlv',
        '$r/go/delve/config',
        'dlv',
        'Delve',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Application Support/go',
        '$r/go/config',
        'go',
        'Go',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Caches/gopls',
        '$r/go/gopls/cache',
        'gopls',
        'gopls',
        ToolLocationKind.cache,
      ),
      (
        '$h/.pub-cache',
        e['PUB_CACHE'] ?? '$r/dart/pub-cache',
        'dart',
        'Dart',
        ToolLocationKind.cache,
      ),
      (
        '$h/.dart-tool',
        '$r/dart/config/dart-tool',
        'dart',
        'Dart',
        ToolLocationKind.configuration,
      ),
      (
        '$h/.dartServer',
        '$r/dart/analysis',
        'dart',
        'Dart',
        ToolLocationKind.cache,
      ),
      (
        '$h/.mitmproxy',
        '$r/mitmproxy/config',
        'mitmproxy',
        'mitmproxy',
        ToolLocationKind.configuration,
      ),
      (
        '$h/.npmrc',
        '$r/npm/npmrc',
        'npm',
        'npm',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Application Support/pip/pip.conf',
        '$r/pip/pip.conf',
        'pip',
        'pip',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Application Support/bruno',
        '$r/bruno/data',
        'bruno',
        'Bruno',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Caches/bruno',
        '$r/bruno/cache/application',
        'bruno',
        'Bruno',
        ToolLocationKind.cache,
      ),
      (
        '$h/Library/Caches/com.usebruno.app',
        '$r/bruno/cache/system',
        'bruno',
        'Bruno',
        ToolLocationKind.cache,
      ),
      (
        '$h/Library/Logs/bruno',
        '$r/bruno/logs',
        'bruno',
        'Bruno',
        ToolLocationKind.logs,
      ),
      (
        '$h/Library/Application Support/com.reqable.macosx',
        '$r/reqable/data',
        'reqable',
        'Reqable',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Application Support/HBuilder X',
        '$r/hbuilderx/data',
        'hbuilderx',
        'HBuilderX',
        ToolLocationKind.configuration,
      ),
      (
        '$h/Library/Caches/HBuilder X',
        '$r/hbuilderx/cache',
        'hbuilderx',
        'HBuilderX',
        ToolLocationKind.cache,
      ),
    ];
  }

  static final classifiedFolders = [
    for (final entry in ToolchainLayout.categories.entries)
      (
        entry.value,
        entry.key,
        const {
          'java': 'Java',
          'node': 'Node.js',
          'python': 'Python',
          'go': 'Go',
          'rust': 'Rust',
          'flutter': 'Flutter',
        }[entry.key]!,
      ),
    ('dart', 'dart', 'Dart'),
    ('mise', 'mise', 'mise'),
    ('mise-gui', 'devworkbench', 'DevWorkbench'),
    ('npm', 'npm', 'npm'),
    ('pnpm', 'pnpm', 'pnpm'),
    ('pip', 'pip', 'pip'),
    ('uv', 'uv', 'uv'),
    ('maven', 'maven', 'Maven'),
    ('.m2', 'maven', 'Maven'),
    ('gradle', 'gradle', 'Gradle'),
    ('android', 'android-sdk', 'Android SDK'),
    ('xcode', 'xcode', 'Xcode'),
    ('cocoapods', 'cocoapods', 'CocoaPods'),
    ('bruno', 'bruno', 'Bruno'),
    ('reqable', 'reqable', 'Reqable'),
    ('mitmproxy', 'mitmproxy', 'mitmproxy'),
    ('hbuilderx', 'hbuilderx', 'HBuilderX'),
    ('mcp-toolbox', 'toolbox', 'MCP Toolbox'),
    ('homebrew', 'homebrew', 'Homebrew'),
    ('typescript', 'typescript', 'TypeScript'),
  ];
  static final allowedFolders = <String, List<String>>{
    for (final entry in ToolchainLayout.categories.entries)
      entry.key: [
        entry.value,
        'mise',
        if (entry.key == 'node') 'npm',
        if (entry.key == 'python') 'pip',
        if (entry.key == 'flutter') 'dart',
      ],
    'gopls': ['go'],
    'dlv': ['go'],
    'cargo': ['rust'],
    'rustup': ['rust'],
    'rustfmt': ['rust'],
    'clippy': ['rust'],
    'rust-analyzer': ['rust'],
    'dart': ['dart', 'flutter', 'mise'],
    'maven': ['maven', '.m2'],
    'gradle': ['gradle'],
    'android-sdk': ['android'],
    'android-ndk': ['android'],
    'android-studio': ['android'],
    'cmake': ['android'],
    'adb': ['android'],
    'devicehub': ['xcode'],
    'simulator': ['xcode'],
    'xcode': ['xcode'],
    'npm': ['npm', ToolchainLayout.categories['node']!],
    'pnpm': ['pnpm'],
    'pip': ['pip', ToolchainLayout.categories['python']!],
    'uv': ['uv', 'python'],
    'cocoapods': ['cocoapods'],
    'bruno': ['bruno'],
    'reqable': ['reqable'],
    'mitmproxy': ['mitmproxy'],
    'hbuilderx': ['hbuilderx'],
    'toolbox': ['mcp-toolbox'],
    'homebrew': ['homebrew'],
    'mise': ['mise'],
    'devworkbench': ['mise-gui'],
    'idea': ['idea', 'jetbrains'],
    'datagrip': ['datagrip', 'jetbrains'],
    'vscode': ['vscode'],
    'cursor': ['cursor'],
    'navicat': ['navicat'],
    'jetbrains-toolbox': ['jetbrains-toolbox', 'jetbrains'],
    'typescript': ['typescript'],
  };
}

String normalizeStoragePath(String path) {
  final result = File(path).absolute.uri.normalizePath().toFilePath();
  return result.length > 1 ? result.replaceFirst(RegExp(r'/$'), '') : result;
}

Iterable<List<T>> _batches<T>(List<T> values, int width) sync* {
  for (var i = 0; i < values.length; i += width) {
    yield values.sublist(
      i,
      i + width > values.length ? values.length : i + width,
    );
  }
}
