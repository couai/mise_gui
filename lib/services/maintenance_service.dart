import 'dart:convert';
import 'dart:io';
import 'package:mise_gui/models/maintenance.dart';
import 'package:mise_gui/models/workbench_task.dart';
import 'package:mise_gui/models/storage_models.dart';
import 'package:mise_gui/services/classified_toolchain_service.dart';
import 'package:mise_gui/services/directory_usage_reader.dart';
import 'package:mise_gui/services/managed_package_catalog.dart';
import 'package:mise_gui/services/task_center.dart';

class MaintenanceService {
  const MaintenanceService(
    this.catalog,
    this.runtimes,
    this.tasks, {
    this.usage = const PosixDirectoryUsageReader(),
  });
  final ManagedPackageCatalog catalog;
  final ClassifiedToolchainService runtimes;
  final TaskCenter tasks;
  final DirectoryUsageReader usage;
  static const cacheIds = ['npm', 'pip', 'uv', 'go'];
  Future<MaintenancePlan> prepare(MaintenanceRequest request) async {
    if (request.manager == MaintenanceManager.cache) return _cachePlan(request);
    if (request.action == MaintenanceAction.clean) {
      throw ArgumentError('请选择缓存维护范围');
    }
    if (request.manager == MaintenanceManager.android) {
      return _androidPlan(request);
    }
    return _brewPlan(request);
  }

  Future<MaintenancePlan> _brewPlan(MaintenanceRequest request) async {
    final id = request.target;
    if (!RegExp(
      r'^[a-z0-9][a-z0-9+_.@-]*(?:/[a-z0-9][a-z0-9+_.@-]*){0,2}$',
    ).hasMatch(id)) {
      throw ArgumentError('请输入完整 Homebrew 包名称，不能附加参数');
    }
    final name = id.split('/').last;
    final restriction = maintenanceRestriction(
      request.manager,
      request.action,
      id,
    );
    if (restriction != null) throw StateError(restriction);
    final prefix = (await catalog.query(catalog.settings.brewExecutable, [
      '--prefix',
    ])).trim();
    if (prefix != catalog.settings.homebrewPrefix) {
      throw StateError('brew 实际安装前缀与管理器设置不一致，请先修正设置');
    }
    final pkg = await catalog.brewInfo(request.manager, id);
    if (request.action == MaintenanceAction.install && pkg.version.isNotEmpty) {
      throw StateError('该包已有 Homebrew 安装记录，请选择更新');
    }
    if (request.action != MaintenanceAction.install && pkg.version.isEmpty) {
      throw StateError('没有对应 Homebrew 安装记录，不能更新或卸载手动安装的程序');
    }
    if (pkg.pinned) throw StateError('包已被 pin 固定，请在原管理器中处理');
    if (request.action == MaintenanceAction.update &&
        (pkg.latest == null ||
            pkg.latest == 'latest' ||
            pkg.version.split(' / ').contains(pkg.latest))) {
      throw StateError('未发现明确的新版本；请保留当前版本或在原管理器核对');
    }
    if (request.action == MaintenanceAction.uninstall &&
        pkg.version.contains(' / ')) {
      throw StateError('此包保留了多个安装版本，请在原管理器逐项处理');
    }
    final kind = request.manager == MaintenanceManager.formula
        ? '--formula'
        : '--cask';
    final op = request.action == MaintenanceAction.update
        ? 'upgrade'
        : request.action.name;
    final args = [
      op,
      kind,
      if (request.manager == MaintenanceManager.cask &&
          request.action != MaintenanceAction.uninstall)
        '--appdir=/Applications',
      id,
    ];
    var dryRun = '';
    if (request.action == MaintenanceAction.uninstall &&
        request.manager == MaintenanceManager.formula) {
      final dependents = (await catalog.query(catalog.settings.brewExecutable, [
        'uses',
        '--installed',
        '--recursive',
        id,
      ])).trim();
      if (dependents.isNotEmpty) {
        throw StateError('以下已安装工具依赖此包，保留原安装：\n$dependents');
      }
    }
    if (request.action != MaintenanceAction.uninstall) {
      dryRun = await catalog.query(catalog.settings.brewExecutable, [
        op,
        '--dry-run',
        kind,
        if (request.manager == MaintenanceManager.cask)
          '--appdir=/Applications',
        id,
      ]);
    }
    final scope = request.manager == MaintenanceManager.formula
        ? '$prefix/Cellar/$name'
        : '/Applications';
    return _plan(
      request,
      [MaintenanceCommand(catalog.settings.brewExecutable, args)],
      [scope],
      identity: [pkg.id, pkg.version, pkg.latest, pkg.pinned, prefix, dryRun],
      before: pkg.version,
      target: pkg.latest,
      preview: dryRun,
      notes: [
        '由 Homebrew 处理所选包及必要依赖；CLI 安装保留在 Homebrew 前缀，GUI 应用固定在 /Applications。',
        '关闭自动清理、自动移除和其他依赖方的自动升级。卸载保留用户配置与数据，不使用 --zap、--force 或忽略依赖。',
        if (request.manager == MaintenanceManager.cask)
          '原生安装器可能需要用户在系统界面确认许可或管理员认证；任务不会代为同意或输入密码。',
      ],
    );
  }

  Future<MaintenancePlan> _androidPlan(MaintenanceRequest request) async {
    validateAndroidId(request.target);
    final sdk = catalog.settings.androidSdk;
    await _guard(sdk, '${catalog.layout.root}/android/sdk');
    final target = '$sdk/${request.target.replaceAll(';', '/')}';
    await _guard(
      target,
      '${catalog.layout.root}/android/sdk/${request.target.replaceAll(';', '/')}',
      allowMissing: request.action == MaintenanceAction.install,
    );
    final installed = await catalog.androidInstalled();
    final current = installed.where((p) => p.id == request.target).firstOrNull;
    if (request.action == MaintenanceAction.install && current != null) {
      throw StateError('此组件已安装，请选择更新');
    }
    if (request.action != MaintenanceAction.install && current == null) {
      throw StateError('SDK 元数据中没有此组件，拒绝修改');
    }
    if (request.action == MaintenanceAction.install &&
        await FileSystemEntity.type(target, followLinks: false) !=
            FileSystemEntityType.notFound) {
      throw StateError('目标目录已存在但无完整安装记录，保留原内容');
    }
    ManagedPackage? available;
    if (request.action == MaintenanceAction.uninstall) {
      if (request.target == 'platform-tools' ||
          request.target == 'emulator' ||
          request.target.startsWith('cmdline-tools;')) {
        throw StateError('保留 SDK 管理与设备启动的基础组件，请在 Android Studio 中处理');
      }
      if (request.target.startsWith('system-images;')) {
        await _checkAvdReferences(target);
      }
    } else {
      available = await catalog.androidAvailable(request.target);
      if (request.action == MaintenanceAction.update &&
          _sameVersion(current!.version, available.latest!)) {
        throw StateError('稳定频道未发现此组件的新版本');
      }
    }
    final args = [
      if (request.action == MaintenanceAction.uninstall) '--uninstall',
      '--sdk_root=$sdk',
      '--channel=0',
      request.target,
    ];
    return _plan(
      request,
      [MaintenanceCommand('$sdk/cmdline-tools/latest/bin/sdkmanager', args)],
      [target],
      identity: [current?.version, available?.latest, sdk, target],
      before: current?.version,
      target: available?.latest,
      notes: [
        '仅处理所选稳定频道组件；不会执行全量 --update，也不自动接受 Android 许可。',
        '其他项目可能要求此版本。卸载前请确认项目和构建进程已停止；已知 AVD 引用的系统镜像受到保护。',
        '平台、NDK 与 CMake 按完整包 ID 并存；安装新版本不会修改项目的版本选择。',
      ],
    );
  }

  Future<void> _checkAvdReferences(String target) async {
    final avds = Directory(
      catalog.layout.environment['ANDROID_AVD_HOME'] ??
          '${catalog.layout.root}/android/avd',
    );
    if (!await avds.exists()) return;
    await for (final entry in avds.list(followLinks: false)) {
      if (entry is Link) {
        throw StateError('存在链接式 AVD，镜像引用无法完整核对，请在 Android Studio 中管理');
      }
      if (entry is File && entry.path.endsWith('.ini')) {
        if (await entry.length() > 1024 * 1024) {
          throw StateError('AVD 元数据过大，保留系统镜像');
        }
        final metadata = await entry.readAsString();
        final path = RegExp(
          r'^path\s*=\s*(.+)$',
          multiLine: true,
        ).firstMatch(metadata)?.group(1)?.trim();
        if (path != null &&
            (!path.startsWith('${avds.path}/') ||
                !await Directory(path).exists())) {
          throw StateError('存在外部或失效的 AVD 引用，请在 Android Studio 中核对');
        }
      }
      if (entry is! Directory || !entry.path.endsWith('.avd')) continue;
      final file = File('${entry.path}/config.ini');
      if (!await file.exists()) throw StateError('AVD 配置无法核对，保留系统镜像');
      final text = await file.readAsString();
      final image = RegExp(r'^image\.sysdir\.1\s*=\s*(.+)$', multiLine: true)
          .firstMatch(text)
          ?.group(1)
          ?.trim()
          .replaceAll('\\', '/')
          .replaceAll(RegExp(r'/+$'), '');
      if (image == null) throw StateError('AVD 镜像引用无法核对，保留系统镜像');
      if (image == target ||
          '${catalog.settings.androidSdk}/$image' == target) {
        throw StateError('此镜像正被 AVD 使用：${entry.path.split('/').last}');
      }
    }
  }

  Future<MaintenancePlan> _cachePlan(MaintenanceRequest request) async {
    if (request.action != MaintenanceAction.clean ||
        !cacheIds.contains(request.target)) {
      throw ArgumentError('仅支持 npm、pip、uv 和 Go 编译缓存');
    }
    final id = request.target;
    final expected = '${catalog.layout.root}/$id/cache';
    final key = {
      'npm': 'npm_config_cache',
      'pip': 'PIP_CACHE_DIR',
      'uv': 'UV_CACHE_DIR',
      'go': 'GOCACHE',
    }[id]!;
    final path = catalog.layout.environment[key] ?? expected;
    await _guard(path, expected);
    final versions = await runtimes.inventory();
    String sdk(String tool) =>
        versions
            .where((v) => v.tool == tool && v.active && v.classified)
            .firstOrNull
            ?.actualPath ??
        (throw StateError('没有可用的分类 $tool 全局版本'));
    MaintenanceCommand command;
    switch (id) {
      case 'npm':
        final home = sdk('node');
        command = MaintenanceCommand('$home/bin/node', [
          '$home/lib/node_modules/npm/bin/npm-cli.js',
          'cache',
          'clean',
          '--force',
          '--cache',
          path,
        ]);
      case 'pip':
        command = MaintenanceCommand('${sdk('python')}/bin/python3', [
          '-m',
          'pip',
          'cache',
          'purge',
          '--cache-dir',
          path,
          '--disable-pip-version-check',
        ]);
      case 'uv':
        command = MaintenanceCommand('${catalog.layout.root}/uv/bin/uv', [
          'cache',
          'clean',
          '--cache-dir',
          path,
        ]);
      case 'go':
        command = MaintenanceCommand('${sdk('go')}/bin/go', [
          'clean',
          '-cache',
        ]);
      default:
        throw StateError('未知缓存');
    }
    if (!await File(command.executable).exists()) {
      throw StateError('原生清理程序不可用，请先核对工具档案');
    }
    if (id == 'npm' && !await File(command.arguments.first).exists()) {
      throw StateError('当前 Node.js 中没有完整 npm CLI');
    }
    return _plan(
      request,
      [command],
      [path],
      identity: [
        path,
        await Directory(path).resolveSymbolicLinks(),
        command.display,
      ],
      notes: [
        '只调用原生管理器清理这个分类缓存；保留程序、全局包、项目依赖、配置和凭据。',
        '请先停止其他终端中的安装与构建。清理后下次使用可能重新下载或编译；占用变化不等于 APFS 实际释放空间。',
        'Maven 仓库、Gradle 用户目录、Flutter SDK、抓包数据和 IDE 配置不提供整体清理。',
      ],
    );
  }

  MaintenancePlan _plan(
    MaintenanceRequest r,
    List<MaintenanceCommand> commands,
    List<String> paths, {
    required List<Object?> identity,
    required List<String> notes,
    String? before,
    String? target,
    String preview = '',
  }) => MaintenancePlan(
    request: r,
    commands: commands,
    paths: paths,
    notes: notes,
    beforeVersion: before,
    targetVersion: target,
    previewOutput: preview,
    identity: jsonEncode([
      catalog.settings.toJson(),
      r.manager.name,
      r.action.name,
      r.target,
      identity,
      commands.map((c) => c.display).toList(),
      paths,
    ]),
  );
  Future<void> _guard(
    String path,
    String expected, {
    bool allowMissing = false,
  }) async {
    final root = await Directory(catalog.layout.root).resolveSymbolicLinks();
    if (!path.startsWith('/') ||
        !path.startsWith('${catalog.layout.root}/') ||
        path.split('/').contains('..') ||
        !expected.startsWith('${catalog.layout.root}/')) {
      throw StateError('路径不符合分类目录规则');
    }
    final wanted = root + expected.substring(catalog.layout.root.length);
    var ancestor = Directory(path);
    while (!await ancestor.exists()) {
      if (!allowMissing) throw StateError('分类目录不存在：$path');
      if (await FileSystemEntity.type(ancestor.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError('路径存在失效链接或非目录项');
      }
      ancestor = ancestor.parent;
    }
    final actual = await ancestor.resolveSymbolicLinks();
    final finalPath = actual + path.substring(ancestor.path.length);
    if (finalPath != wanted) throw StateError('路径或软链接指向预期分类以外，拒绝操作');
  }

  Future<TaskVerification> execute(MaintenancePlan plan) async {
    final task = tasks.startMutation(
      plan.title,
      plan.request.manager.taskManager,
      ['复查预览与当前状态', ...plan.commands.map((c) => c.display), '验证操作结果'],
    );
    task.step(0, TaskStepStatus.running);
    try {
      final fresh = await prepare(plan.request);
      if (fresh.identity != plan.identity) {
        throw StateError('安装信息、依赖计划或路径已变化，请重新预览');
      }
      task.step(0, TaskStepStatus.succeeded);
      StorageUsage? before;
      if (fresh.request.manager == MaintenanceManager.cache) {
        before = await usage.measure(
          fresh.paths.single,
          DirectoryScanCancellation(),
        );
      }
      for (final (index, command) in fresh.commands.indexed) {
        if (fresh.request.manager == MaintenanceManager.cache) {
          await _guard(
            fresh.paths.single,
            '${catalog.layout.root}/${fresh.request.target}/cache',
          );
        }
        task.step(index + 1, TaskStepStatus.running);
        task.output('\n\$ ${command.display}\n');
        final result = await catalog.process.run(
          command,
          environment: {
            ...catalog.environment,
            if (fresh.request.manager == MaintenanceManager.cache &&
                fresh.request.target == 'go')
              'GOCACHE': fresh.paths.single,
          },
          workingDirectory: catalog.layout.home,
          timeout: Duration(minutes: catalog.settings.actionTimeoutMinutes),
          onOutput: task.output,
        );
        task.output('\nexit ${result.exitCode}\n');
        task.step(
          index + 1,
          result.exitCode == 0
              ? TaskStepStatus.succeeded
              : TaskStepStatus.failed,
          exitCode: result.exitCode,
        );
        if (result.exitCode != 0) {
          throw StateError('原生命令失败；如需许可或管理员认证，请在原管理器处理后重新预览');
        }
      }
      task.step(fresh.commands.length + 1, TaskStepStatus.running);
      final verification = await _verify(fresh, before);
      task.step(
        fresh.commands.length + 1,
        verification.passed ? TaskStepStatus.succeeded : TaskStepStatus.failed,
      );
      task.output('\n[验证] ${verification.detail}\n');
      task.finish(verification);
      return verification;
    } catch (error) {
      final verification = TaskVerification(false, '$error');
      task.output('\n$error\n');
      task.finish(verification);
      return verification;
    }
  }

  Future<TaskVerification> _verify(
    MaintenancePlan plan,
    StorageUsage? before,
  ) async {
    final r = plan.request;
    if (r.manager == MaintenanceManager.cache) {
      await _guard(
        plan.paths.single,
        '${catalog.layout.root}/${r.target}/cache',
        allowMissing: true,
      );
      final after = await usage.measure(
        plan.paths.single,
        DirectoryScanCancellation(),
      );
      return TaskVerification(
        true,
        '原生清理命令成功，目标分类路径复查通过。\n已测占用：${before?.bytes == null ? '未知' : formatStorageBytes(before!.bytes!)} → ${after.bytes == null ? '未知' : formatStorageBytes(after.bytes!)}。缓存元数据可能保留。',
        warning: after.bytes == null,
      );
    }
    final packages = r.manager == MaintenanceManager.android
        ? await catalog.androidInstalled()
        : await catalog.brewInstalled();
    final row = packages
        .where(
          (p) =>
              p.manager == r.manager &&
              (p.id == r.target || p.id.split('/').last == r.target),
        )
        .firstOrNull;
    if (r.action == MaintenanceAction.uninstall) {
      final retained =
          r.manager == MaintenanceManager.android &&
          await Directory(plan.paths.single).exists();
      return TaskVerification(
        row == null && !retained,
        row == null && !retained
            ? '管理器安装记录已移除，用户数据与配置保留。'
            : '卸载后仍有安装记录或组件目录，请核对原生输出。',
      );
    }
    final pass =
        row != null &&
        (plan.targetVersion == null ||
            plan.targetVersion == 'latest' ||
            row.version
                .split(' / ')
                .any((v) => _sameVersion(v, plan.targetVersion!)));
    return TaskVerification(
      pass,
      pass ? '${r.target} 安装记录与目标版本已验证：${row.version}' : '命令完成，但安装记录与目标版本不一致。',
    );
  }

  bool _sameVersion(String a, String b) {
    String normalize(String value) =>
        value.replaceFirst(RegExp(r'(?:\.0)+$'), '');
    return a == b || normalize(a) == normalize(b);
  }
}
