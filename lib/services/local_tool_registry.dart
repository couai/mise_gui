import 'dart:convert';
import 'dart:io';

import 'package:mise_gui/models/local_tool.dart';
import 'package:mise_gui/services/local_tool_process.dart';

/// Imports only existing app bundles or executable files. Imported CLIs are
/// never executed during discovery, even to obtain a version.
class ImportedTool {
  const ImportedTool({
    required this.id,
    required this.name,
    required this.category,
    required this.path,
    required this.application,
    this.description = '',
    this.version = '',
    this.configPath = '',
    this.cachePath = '',
    this.logsPath = '',
  });
  final String id,
      name,
      path,
      description,
      version,
      configPath,
      cachePath,
      logsPath;
  final LocalToolCategory category;
  final bool application;

  Map<String, Object> toJson() => {
    'id': id,
    'name': name,
    'category': category.name,
    'path': path,
    'application': application,
    'description': description,
    'version': version,
    'configPath': configPath,
    'cachePath': cachePath,
    'logsPath': logsPath,
  };
  factory ImportedTool.fromJson(Map<String, dynamic> json) => ImportedTool(
    id: json['id'] as String,
    name: json['name'] as String,
    category: LocalToolCategory.values.byName(json['category'] as String),
    path: json['path'] as String,
    application: json['application'] as bool,
    description: json['description'] as String? ?? '',
    version: json['version'] as String? ?? '',
    configPath: json['configPath'] as String? ?? '',
    cachePath: json['cachePath'] as String? ?? '',
    logsPath: json['logsPath'] as String? ?? '',
  );
}

class LocalToolRegistry {
  LocalToolRegistry({required this.file, required this.process});
  final File file;
  final LocalToolProcess process;
  bool _writing = false;

  Future<List<ImportedTool>> load() async {
    if (!await file.exists()) return [];
    if (await file.length() > 1024 * 1024) {
      throw const FormatException('导入清单过大');
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map || json['schema'] != 1 || json['tools'] is! List) {
      throw const FormatException('导入清单格式不受支持');
    }
    final rows = json['tools'] as List;
    if (rows.length > 200) throw const FormatException('最多登记 200 个工具');
    final result = rows
        .map((row) => ImportedTool.fromJson(row as Map<String, dynamic>))
        .toList();
    final ids = <String>{};
    for (final t in result) {
      if (!RegExp(r'^imported-[0-9]+$').hasMatch(t.id) || !ids.add(t.id)) {
        throw const FormatException('导入清单包含无效或重复标识');
      }
      _validate(t);
    }
    return result;
  }

  Future<ImportedTool> importTool(
    ImportedTool draft, {
    required List<LocalTool> knownTools,
  }) async {
    if (_writing) throw StateError('已有登记操作正在保存，请稍后重试。');
    _writing = true;
    try {
      _validate(draft);
      final path = _normalize(draft.path);
      if (!await _validProgram(path, draft.application)) {
        throw StateError(
          draft.application
              ? '请选择包含有效启动程序的 .app 应用包。'
              : '请选择具有执行权限的 CLI 文件，不能选择文件夹或 mise shim。',
        );
      }
      final actual = await _resolve(path);
      final records = await load();
      if (records.length >= 200) throw StateError('最多登记 200 个工具。');
      final existingPaths = [
        for (final t in knownTools) ...[
          if (t.executable != null) t.executable!,
          ...t.locations.where((p) => p.application).map((p) => p.path),
        ],
        ...records.map((t) => t.path),
      ];
      for (final existing in existingPaths) {
        if (await _resolve(existing) == actual) {
          throw StateError('此程序已在工具清单中，无需重复导入。');
        }
      }
      final record = ImportedTool(
        id: 'imported-${DateTime.now().microsecondsSinceEpoch}',
        name: draft.name.trim(),
        category: draft.category,
        path: path,
        application: draft.application,
        description: draft.description.trim(),
        version: draft.version.trim(),
        configPath: draft.configPath.isEmpty
            ? ''
            : _normalize(draft.configPath),
        cachePath: draft.cachePath.isEmpty ? '' : _normalize(draft.cachePath),
        logsPath: draft.logsPath.isEmpty ? '' : _normalize(draft.logsPath),
      );
      await _write([...records, record]);
      return record;
    } finally {
      _writing = false;
    }
  }

  /// Removes this app's registration only; never deletes the tool or its data.
  Future<void> forget(String id) async {
    if (_writing) throw StateError('已有登记操作正在保存，请稍后重试。');
    _writing = true;
    try {
      final records = await load();
      await _write(records.where((t) => t.id != id).toList());
    } finally {
      _writing = false;
    }
  }

  Future<List<LocalTool>> scan() async {
    final records = await load();
    final result = List<LocalTool?>.filled(records.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < records.length) {
        final index = next++;
        final t = records[index];
        try {
          result[index] = await _inspect(t);
        } catch (_) {
          result[index] = LocalTool(
            id: t.id,
            name: t.name,
            category: t.category,
            description: t.description,
            status: LocalToolStatus.unavailable,
            manager: '手动登记',
            source: '本地检查失败',
            imported: true,
            notes: ['无法检查登记程序，请核对本地路径和权限。'],
          );
        }
      }
    }

    await Future.wait(List.generate(4, (_) => worker()));
    return result.whereType<LocalTool>().toList();
  }

  Future<LocalTool> _inspect(ImportedTool t) async {
    final exists =
        await FileSystemEntity.type(t.path) != FileSystemEntityType.notFound;
    final info = t.application && exists
        ? await _appInfo(t.path)
        : <String, dynamic>{};
    final valid =
        exists && await _validProgram(t.path, t.application, info: info);
    String? version;
    if (valid && t.application) {
      final value = info['CFBundleShortVersionString'];
      if (value is String && value.isNotEmpty) version = value;
    }
    final locations = <ToolLocation>[
      ToolLocation(
        label: t.application ? '应用' : '命令',
        path: t.path,
        exists: valid,
        application: t.application,
        kind: ToolLocationKind.installation,
      ),
    ];
    for (final (kind, label, path) in [
      (ToolLocationKind.configuration, '配置 / 数据', t.configPath),
      (ToolLocationKind.cache, '缓存', t.cachePath),
      (ToolLocationKind.logs, '日志', t.logsPath),
    ]) {
      if (path.isEmpty) continue;
      locations.add(
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
    return LocalTool(
      id: t.id,
      name: t.name,
      category: t.category,
      description: t.description.isEmpty
          ? '手动导入的本地${t.application ? '应用' : 'CLI'}。'
          : t.description,
      status: valid
          ? LocalToolStatus.ready
          : exists
          ? LocalToolStatus.attention
          : LocalToolStatus.missing,
      manager: '手动登记',
      source: t.application ? '本地应用包元数据' : '本地可执行文件（未执行探测）',
      version: version ?? (t.version.isEmpty ? null : '${t.version} · 手动登记'),
      executable: t.application ? null : t.path,
      locations: locations,
      imported: true,
      notes: [
        if (!valid) '原程序已移除或无法确认有效安装，请检查登记路径。',
        if (!t.application) '扫描只检查文件及执行权限，不自动运行导入的 CLI。',
      ],
    );
  }

  Future<bool> _validProgram(
    String path,
    bool application, {
    Map<String, dynamic>? info,
  }) async {
    if (application) {
      if (!path.endsWith('.app') || !await Directory(path).exists()) {
        return false;
      }
      final metadata = info ?? await _appInfo(path);
      final name = metadata['CFBundleExecutable'];
      if (name is! String ||
          name.isEmpty ||
          name.contains('/') ||
          name.contains('\\') ||
          name == '..') {
        return false;
      }
      final executable = File('$path/Contents/MacOS/$name');
      return await executable.exists() &&
          ((await executable.stat()).mode & 0x49) != 0;
    }
    final f = File(path);
    if (await FileSystemEntity.type(path) != FileSystemEntityType.file ||
        ((await f.stat()).mode & 0x49) == 0) {
      return false;
    }
    final actual = await _resolve(path);
    return !actual.contains('/shims/') &&
        !path.contains('/shims/') &&
        !actual.endsWith('/mise');
  }

  Future<Map<String, dynamic>> _appInfo(String path) async {
    final plist = File('$path/Contents/Info.plist');
    if (!await plist.exists() || await plist.length() > 1024 * 1024) return {};
    try {
      final r = await process.run('/usr/bin/plutil', [
        '-convert',
        'json',
        '-o',
        '-',
        plist.path,
      ]);
      if (r.exitCode != 0) return {};
      return jsonDecode(r.stdout) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void _validate(ImportedTool t) {
    if (t.name.trim().isEmpty ||
        t.name.length > 100 ||
        t.description.length > 500 ||
        t.version.length > 100) {
      throw const FormatException('请填写工具名称（最多 100 字），说明最多 500 字。');
    }
    for (final path in [t.path, t.configPath, t.cachePath, t.logsPath]) {
      if (path.isEmpty && path != t.path) continue;
      if (path.isEmpty ||
          !File(path).isAbsolute ||
          path.length > 4096 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(path)) {
        throw const FormatException('程序和目录请使用完整的本地绝对路径。');
      }
    }
  }

  String _normalize(String path) =>
      File(path.trim()).absolute.uri.normalizePath().toFilePath();
  Future<String> _resolve(String path) async {
    try {
      return await File(path).resolveSymbolicLinks();
    } on FileSystemException {
      return _normalize(path);
    }
  }

  Future<void> _write(List<ImportedTool> records) async {
    await file.parent.create(recursive: true);
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'schema': 1,
          'tools': records.map((t) => t.toJson()).toList(),
        }),
        flush: true,
      );
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}
