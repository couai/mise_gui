import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/models/manager_settings.dart';
import 'package:mise_gui/services/maintenance_process.dart';
import 'package:mise_gui/services/toolchain_layout.dart';

class ManagedPackageCatalog {
  const ManagedPackageCatalog(this.process, this.layout, this.settings);
  final MaintenanceProcess process;
  final ToolchainLayout layout;
  final ManagerSettings settings;
  Map<String, String> get environment => {
    ...layout.environment,
    ...settings.environment,
    'HOME': layout.home,
    'HOMEBREW_NO_INSTALL_CLEANUP': '1',
    'HOMEBREW_NO_AUTOREMOVE': '1',
    'HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK': '1',
    'HOMEBREW_NO_INSTALL_UPGRADE': '1',
    'HOMEBREW_CACHE':
        layout.environment['HOMEBREW_CACHE'] ?? '${layout.root}/homebrew/cache',
    'HOMEBREW_LOGS':
        layout.environment['HOMEBREW_LOGS'] ?? '${layout.root}/homebrew/logs',
    'MISE_AUTO_INSTALL': '0',
    'MISE_NOT_FOUND_AUTO_INSTALL': '0',
    'RUSTUP_AUTO_INSTALL': '0',
    'CI': '1',
    'LC_ALL': 'C',
  };
  Future<String> query(String executable, List<String> args) async {
    final result = await process.run(
      MaintenanceCommand(executable, args),
      environment: environment,
      workingDirectory: layout.home,
    );
    if (result.exitCode != 0) {
      throw StateError('管理器查询失败（exit ${result.exitCode}）：${result.stderr}');
    }
    return result.stdout;
  }

  Future<MaintenanceSnapshot> installed() async {
    final warnings = <String>[], packages = <ManagedPackage>[];
    try {
      packages.addAll(await brewInstalled());
    } catch (e) {
      warnings.add('Homebrew 清单暂不可用：$e');
    }
    try {
      packages.addAll(await androidInstalled());
    } catch (e) {
      warnings.add('Android 清单暂不可用：$e');
    }
    return MaintenanceSnapshot(packages, warnings: warnings);
  }

  Future<List<ManagedPackage>> brewInstalled() async {
    final prefix = (await query(settings.brewExecutable, ['--prefix'])).trim();
    if (prefix != settings.homebrewPrefix) {
      throw StateError('Homebrew 实际安装前缀与设置不一致，请先核对管理器设置');
    }
    return parseBrewPackages(
      await query(settings.brewExecutable, [
        'info',
        '--json=v2',
        '--installed',
      ]),
      prefix,
    );
  }

  Future<ManagedPackage> brewInfo(MaintenanceManager manager, String id) async {
    final rows = parseBrewPackages(
      await query(settings.brewExecutable, [
        'info',
        '--json=v2',
        manager == MaintenanceManager.formula ? '--formula' : '--cask',
        id,
      ]),
      settings.homebrewPrefix,
      includeMissing: true,
    );
    final match = rows
        .where(
          (p) =>
              p.manager == manager &&
              (p.id == id || p.id.split('/').last == id),
        )
        .firstOrNull;
    if (match == null) throw StateError('管理器未返回所选包的元数据');
    return match;
  }

  Future<List<ManagedPackage>> androidInstalled() async {
    final root = Directory(settings.androidSdk);
    if (!await root.exists()) throw StateError('SDK 目录不存在');
    final files = <File>[];
    void add(String sub) => files.add(File('${root.path}/$sub/package.xml'));
    for (final path in ['platform-tools', 'emulator']) {
      add(path);
    }
    for (final category in [
      'build-tools',
      'platforms',
      'sources',
      'ndk',
      'cmake',
      'cmdline-tools',
    ]) {
      final dir = Directory('${root.path}/$category');
      if (!await dir.exists()) continue;
      await for (final child in dir.list(followLinks: false)) {
        if (child is Directory && files.length < 5000) {
          files.add(File('${child.path}/package.xml'));
        }
      }
    }
    final images = Directory('${root.path}/system-images');
    if (await images.exists()) {
      await for (final api in images.list(followLinks: false)) {
        if (api is! Directory) continue;
        await for (final flavor in api.list(followLinks: false)) {
          if (flavor is! Directory) continue;
          await for (final abi in flavor.list(followLinks: false)) {
            if (abi is Directory && files.length < 5000) {
              files.add(File('${abi.path}/package.xml'));
            }
          }
        }
      }
    }
    final result = <ManagedPackage>[];
    for (final file in files) {
      if (!await file.exists()) continue;
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw StateError('SDK 包元数据必须是普通文件');
      }
      if (await file.length() > 1024 * 1024) throw StateError('SDK 包元数据过大');
      final text = await file.readAsString();
      final id = RegExp(
        r'<localPackage\b[^>]*\bpath="([^"]+)"',
      ).firstMatch(text)?.group(1);
      final revision = RegExp(
        r'<revision>([\s\S]*?)</revision>',
      ).firstMatch(text)?.group(1);
      if (id == null || revision == null) {
        throw StateError('SDK 包元数据格式异常：${file.path}');
      }
      validateAndroidId(id);
      final parts = [
        for (final name in ['major', 'minor', 'micro'])
          RegExp('<$name>([0-9]+)</$name>').firstMatch(revision)?.group(1) ??
              '0',
      ];
      if ('${root.path}/${id.replaceAll(';', '/')}' != file.parent.path) {
        throw StateError('SDK 包路径和元数据不一致');
      }
      result.add(
        ManagedPackage(
          manager: MaintenanceManager.android,
          id: id,
          version: parts.join('.'),
          location: file.parent.path,
        ),
      );
    }
    return result;
  }

  Future<ManagedPackage> androidAvailable(String id) async {
    final rows = parseAndroidAvailable(
      await query(
        '${settings.androidSdk}/cmdline-tools/latest/bin/sdkmanager',
        ['--list', '--channel=0', '--sdk_root=${settings.androidSdk}'],
      ),
    );
    return rows.where((p) => p.id == id).firstOrNull ??
        (throw StateError('稳定频道没有返回这个 Android 包，请核对完整包 ID'));
  }
}

List<ManagedPackage> parseBrewPackages(
  String text,
  String prefix, {
  bool includeMissing = false,
}) {
  final data = jsonDecode(text) as Map;
  final result = <ManagedPackage>[];
  for (final row in data['formulae'] as List? ?? []) {
    final installs = row['installed'] as List? ?? [];
    if (installs.isEmpty && !includeMissing) continue;
    final stable = (row['versions'] as Map?)?['stable'] as String?;
    final rev = row['revision'] as int? ?? 0;
    result.add(
      ManagedPackage(
        manager: MaintenanceManager.formula,
        id: row['full_name'] as String? ?? row['name'] as String,
        version: installs.map((r) => r['version']).join(' / '),
        latest: stable == null ? null : '$stable${rev > 0 ? '_$rev' : ''}',
        pinned: row['pinned'] == true,
        location: '$prefix/Cellar/${row['name']}',
        dependencies: (row['dependencies'] as List? ?? []).cast<String>(),
      ),
    );
  }
  for (final row in data['casks'] as List? ?? []) {
    final installed = row['installed'];
    final version = installed is List
        ? installed.join(' / ')
        : installed?.toString() ?? '';
    if (version.isEmpty && !includeMissing) continue;
    result.add(
      ManagedPackage(
        manager: MaintenanceManager.cask,
        id: row['full_token'] as String? ?? row['token'] as String,
        version: version,
        latest: row['version'] as String?,
        location: '/Applications',
      ),
    );
  }
  return result;
}

void validateAndroidId(String id) {
  final pattern = RegExp(
    r'^(?:platform-tools|emulator|(?:platforms|sources);android-[0-9]+(?:\.[0-9]+)?|(?:build-tools|ndk|cmake);[0-9]+(?:\.[0-9]+){1,3}|cmdline-tools;(?:latest|[0-9]+(?:\.[0-9]+)*)|system-images;android-[0-9]+(?:\.[0-9]+)?;[a-z0-9_]+;[a-z0-9_-]+)$',
  );
  if (!pattern.hasMatch(id)) {
    throw ArgumentError('请输入完整且受支持的 Android 包 ID，例如 platforms;android-33');
  }
}

List<ManagedPackage> parseAndroidAvailable(String text) {
  var available = false;
  final rows = <ManagedPackage>[];
  for (final line in const LineSplitter().convert(text)) {
    final s = line.trim();
    if (s.startsWith('Available Packages:') ||
        s.startsWith('Available packages:')) {
      available = true;
      continue;
    }
    if (s.startsWith('Available Updates:') ||
        s.startsWith('Available updates:')) {
      available = false;
      continue;
    }
    if (!available) continue;
    final parts = s.contains('|')
        ? s.split('|').map((p) => p.trim()).toList()
        : s.split(RegExp(r'\s+'));
    if (parts.length < 2 || !RegExp(r'^\d').hasMatch(parts[1])) continue;
    final id = parts[0].replaceAll('/', ';');
    try {
      validateAndroidId(id);
    } on ArgumentError {
      continue;
    }
    rows.add(
      ManagedPackage(
        manager: MaintenanceManager.android,
        id: id,
        version: '',
        latest: parts[1],
      ),
    );
  }
  return rows;
}
